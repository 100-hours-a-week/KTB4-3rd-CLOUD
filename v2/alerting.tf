# =============================================================================
# 장애 알림 — 모니터링 스택과 독립된 경로
#   설계 근거: wiki「V2 중앙 집중식 모니터링 시스템 설계」6절 (독립 알림)
#
#   CloudWatch Alarm ──▶ SNS <project>-alerts ──▶ 이메일
#                    └─▶ EventBridge(알람 상태 변경) ──▶ API destination ──▶ Discord (#incident)
#
#   Grafana(모니터링 호스트)가 죽어도 알아야 하는 것만 여기서 본다.
#     - 모니터링 호스트 하트비트 (Prometheus · Loki · Grafana 상태, 데이터 디스크, StatusCheck)
#     - Prod ALB 자체 5xx, 대상 그룹 UnHealthyHostCount
#     - ECS 서비스 Running < Desired (Container Insights를 켠 스테이지)
#   SLO burn rate·애플리케이션 증상은 Grafana Alerting이 맡는다.
# =============================================================================

locals {
  alerting_enabled = var.alerting_enabled

  # 기존 변수(alarm_sns_topic_arn)를 지정했으면 그 토픽을 우선한다
  alarm_topic_arn = var.alarm_sns_topic_arn != null ? var.alarm_sns_topic_arn : try(aws_sns_topic.alerts[0].arn, null)
  alarm_actions   = local.alarm_topic_arn == null ? [] : [local.alarm_topic_arn]
}

resource "aws_sns_topic" "alerts" {
  count = local.alerting_enabled ? 1 : 0

  name = "${var.project_name}-alerts"

  tags = {
    Name = "${var.project_name}-alerts"
  }
}

resource "aws_sns_topic_subscription" "alert_email" {
  for_each = local.alerting_enabled ? toset(var.alert_emails) : toset([])

  topic_arn = aws_sns_topic.alerts[0].arn
  protocol  = "email"
  endpoint  = each.value
}

# -----------------------------------------------------------------------------
# 인프라 알람 (모니터링 스택과 독립)
#   이름은 모두 "<project>-" 로 시작한다 → EventBridge 규칙이 이 접두어로 Discord에 보낸다
# -----------------------------------------------------------------------------

locals {
  # Prod ALB / Non-Prod ALB의 CloudWatch LoadBalancer 차원 값
  alb_arn_suffixes = {
    prod    = aws_lb.public.arn_suffix
    nonprod = aws_lb.nonprod.arn_suffix
  }

  alarm_stage_services = {
    for k, s in local.ecs_service_instances : k => s
    if local.alerting_enabled && contains(var.alert_stages, s.stage)
  }

  simple_alarms = merge(
    # 모니터링 호스트 하트비트 (moyeota-monitoring-sync가 1분마다 보낸다)
    #   지표가 끊기면(호스트 다운·동기화 중단) treat_missing_data = breaching으로 알람이 울린다
    local.alerting_enabled && local.monitoring_enabled ? {
      for c in ["prometheus", "loki", "grafana"] : "monitoring-${c}-down" => {
        description = "모니터링 ${c}가 3분 연속 응답하지 않거나 하트비트가 끊김"
        namespace   = module.monitoring[0].heartbeat_namespace
        metric      = "ComponentHealthy"
        dimensions  = { Component = c }
        statistic   = "Minimum"
        period      = 60
        evaluations = 3
        threshold   = 1
        comparison  = "LessThanThreshold"
        missing     = "breaching"
        stage       = "monitoring"
      }
    } : {},

    local.alerting_enabled && local.monitoring_enabled ? {
      "monitoring-data-disk-high" = {
        description = "모니터링 호스트 데이터 디스크 사용률 80% 초과 (Prometheus TSDB·Loki WAL)"
        namespace   = module.monitoring[0].heartbeat_namespace
        metric      = "DataDiskUsedPercent"
        dimensions  = { Component = "host" }
        statistic   = "Maximum"
        period      = 300
        evaluations = 1
        threshold   = 80
        comparison  = "GreaterThanThreshold"
        missing     = "notBreaching"
        stage       = "monitoring"
      }
      "monitoring-host-status-check" = {
        description = "모니터링 호스트 EC2 상태 검사 실패"
        namespace   = "AWS/EC2"
        metric      = "StatusCheckFailed"
        dimensions  = { InstanceId = module.monitoring[0].instance_id }
        statistic   = "Maximum"
        period      = 60
        evaluations = 2
        threshold   = 1
        comparison  = "GreaterThanOrEqualToThreshold"
        missing     = "notBreaching"
        stage       = "monitoring"
      }
    } : {},

    # Prod ALB 자체 5xx (대상이 없거나 응답하지 않을 때 ALB가 만드는 502·503·504)
    local.alerting_enabled && contains(var.alert_stages, "prod") ? {
      "prod-alb-elb-5xx" = {
        description = "Prod ALB 자체 5xx가 5분 동안 ${var.alert_alb_5xx_threshold}건 초과"
        namespace   = "AWS/ApplicationELB"
        metric      = "HTTPCode_ELB_5XX_Count"
        dimensions  = { LoadBalancer = local.alb_arn_suffixes.prod }
        statistic   = "Sum"
        period      = 300
        evaluations = 1
        threshold   = var.alert_alb_5xx_threshold
        comparison  = "GreaterThanThreshold"
        missing     = "notBreaching"
        stage       = "prod"
      }
    } : {},

    # ECS 서비스 대상 그룹에 비정상 대상이 3분 연속 존재
    {
      for k, s in local.alarm_stage_services : "${k}-unhealthy-targets" => {
        description = "${k} 대상 그룹에 비정상(UnHealthy) 대상이 3분 연속 존재"
        namespace   = "AWS/ApplicationELB"
        metric      = "UnHealthyHostCount"
        dimensions = {
          TargetGroup  = module.ecs_service[k].target_group_arn_suffix
          LoadBalancer = local.alb_arn_suffixes[s.alb.alb_key]
        }
        statistic   = "Maximum"
        period      = 60
        evaluations = 3
        threshold   = 0
        comparison  = "GreaterThanThreshold"
        missing     = "notBreaching"
        stage       = s.stage
      } if s.alb != null
    },
  )

  # ECS 태스크 수: Running < Desired 가 5분 연속 (배포·교체 중 짧은 차이는 넘긴다)
  #   ECS/ContainerInsights 지표라 Container Insights를 켠 스테이지(stg·prod)만 만든다
  #   Alloy DAEMON은 desired = 컨테이너 인스턴스 수라, 메모리 여유가 없어 못 뜬 호스트가 있으면 울린다
  task_count_alarms = merge(
    {
      for k, s in local.alarm_stage_services : k => {
        stage        = s.stage
        service      = s.service
        service_name = module.ecs_service[k].service_name
      } if local.ecs_stage_settings[s.stage].container_insights != "disabled"
    },
    {
      for stage in local.monitoring_log_stages : "${stage}-alloy" => {
        stage        = stage
        service      = "alloy"
        service_name = aws_ecs_service.alloy[stage].name
      } if local.alerting_enabled && contains(var.alert_stages, stage) && local.ecs_stage_settings[stage].container_insights != "disabled"
    },
  )
}

resource "aws_cloudwatch_metric_alarm" "infra" {
  for_each = local.simple_alarms

  alarm_name          = "${var.project_name}-${each.key}"
  alarm_description   = each.value.description
  namespace           = each.value.namespace
  metric_name         = each.value.metric
  dimensions          = each.value.dimensions
  statistic           = each.value.statistic
  period              = each.value.period
  evaluation_periods  = each.value.evaluations
  datapoints_to_alarm = each.value.evaluations
  threshold           = each.value.threshold
  comparison_operator = each.value.comparison
  treat_missing_data  = each.value.missing

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions

  tags = {
    Stage = each.value.stage
  }
}

resource "aws_cloudwatch_metric_alarm" "ecs_tasks_below_desired" {
  for_each = local.task_count_alarms

  alarm_name          = "${var.project_name}-${each.key}-tasks-below-desired"
  alarm_description   = "${each.value.stage} ${each.value.service} 실행 태스크 수가 5분 연속 desired보다 적음"
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "missing"
    expression  = "desired - running"
    label       = "Desired - Running"
    return_data = true
  }

  metric_query {
    id = "desired"

    metric {
      namespace   = "ECS/ContainerInsights"
      metric_name = "DesiredTaskCount"
      period      = 60
      stat        = "Average"
      dimensions = {
        ClusterName = module.ecs_cluster[each.value.stage].cluster_name
        ServiceName = each.value.service_name
      }
    }
  }

  metric_query {
    id = "running"

    metric {
      namespace   = "ECS/ContainerInsights"
      metric_name = "RunningTaskCount"
      period      = 60
      stat        = "Average"
      dimensions = {
        ClusterName = module.ecs_cluster[each.value.stage].cluster_name
        ServiceName = each.value.service_name
      }
    }
  }

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions

  tags = {
    Stage = each.value.stage
  }
}

# -----------------------------------------------------------------------------
# CloudWatch 알람 → Discord (EventBridge API destination)
#   SNS는 Discord 웹훅 형식으로 직접 보내지 못한다. Lambda 대신 EventBridge가 알람 상태 변경 이벤트를
#   입력 변환기로 {"content": "..."} 형태로 바꿔 웹훅에 POST한다 (실행 코드·패키징 없음).
#   - API destination은 연결(connection) 인증이 필수라 의미 없는 API 키 헤더를 붙인다 (Discord는 무시)
#   - 5초 안에 응답하지 않거나 429·5xx면 EventBridge가 재시도한다
# -----------------------------------------------------------------------------

locals {
  alert_discord_enabled = var.alert_discord_enabled
}

data "aws_ssm_parameter" "discord_incident_webhook" {
  count = local.alert_discord_enabled ? 1 : 0

  name            = module.monitoring[0].ssm_parameter_names["DISCORD_WEBHOOK_INCIDENT"]
  with_decryption = true
}

resource "aws_cloudwatch_event_connection" "discord" {
  count = local.alert_discord_enabled ? 1 : 0

  name               = "${var.project_name}-discord"
  description        = "Discord webhook (CloudWatch alarm notifications)"
  authorization_type = "API_KEY"

  auth_parameters {
    api_key {
      key   = "X-Moyeota-Source"
      value = "cloudwatch-alarm"
    }
  }
}

resource "aws_cloudwatch_event_api_destination" "discord" {
  count = local.alert_discord_enabled ? 1 : 0

  name                             = "${var.project_name}-discord-incident"
  description                      = "Discord #incident webhook"
  connection_arn                   = aws_cloudwatch_event_connection.discord[0].arn
  invocation_endpoint              = data.aws_ssm_parameter.discord_incident_webhook[0].value
  http_method                      = "POST"
  invocation_rate_limit_per_second = 1
}

resource "aws_cloudwatch_event_rule" "alarm_state_change" {
  count = local.alert_discord_enabled ? 1 : 0

  name        = "${var.project_name}-alarm-state-change"
  description = "CloudWatch alarms named ${var.project_name}-* changing to ALARM or OK"

  event_pattern = jsonencode({
    source        = ["aws.cloudwatch"]
    "detail-type" = ["CloudWatch Alarm State Change"]
    detail = {
      alarmName = [{ prefix = "${var.project_name}-" }]
      state = {
        value = ["ALARM", "OK"]
      }
    }
  })
}

data "aws_iam_policy_document" "events_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "events_discord" {
  count = local.alert_discord_enabled ? 1 : 0

  name               = "${var.project_name}-events-discord"
  assume_role_policy = data.aws_iam_policy_document.events_assume.json
}

resource "aws_iam_role_policy" "events_discord" {
  count = local.alert_discord_enabled ? 1 : 0

  name = "invoke-discord-api-destination"
  role = aws_iam_role.events_discord[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "events:InvokeApiDestination"
      Resource = aws_cloudwatch_event_api_destination.discord[0].arn
    }]
  })
}

resource "aws_cloudwatch_event_target" "alarm_to_discord" {
  count = local.alert_discord_enabled ? 1 : 0

  rule     = aws_cloudwatch_event_rule.alarm_state_change[0].name
  arn      = aws_cloudwatch_event_api_destination.discord[0].arn
  role_arn = aws_iam_role.events_discord[0].arn

  input_transformer {
    input_paths = {
      alarm    = "$.detail.alarmName"
      state    = "$.detail.state.value"
      previous = "$.detail.previousState.value"
      time     = "$.time"
      region   = "$.region"
    }
    # Discord 메시지. 사유(reason) 문자열은 따옴표가 섞여 JSON이 깨질 수 있어 넣지 않고 콘솔 링크로 대신한다.
    input_template = <<-EOT
      {"content": "**[<state>]** `<alarm>` (이전 <previous>)\n<time>\nhttps://<region>.console.aws.amazon.com/cloudwatch/home?region=<region>#alarmsV2:alarm/<alarm>"}
    EOT
  }

  retry_policy {
    maximum_event_age_in_seconds = 3600
    maximum_retry_attempts       = 10
  }
}
