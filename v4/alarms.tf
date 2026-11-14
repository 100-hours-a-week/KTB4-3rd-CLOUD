# v4 알람과 Discord #incident 알림 (설계 5.8절). 참고: v3/eks/alarms.tf
#   1) CloudWatch 알람  : 이름이 local.name_prefix로 시작하는 알람의 ALARM·OK 전환을 보낸다
#   2) ECS 서비스 이벤트 : 배치 실패·태스크 시작 실패(WARN·ERROR), 배포 실패(circuit breaker 롤백)
#   3) ASG 이벤트       : v4 앱 호스트 종료(Spot 회수 포함)와 실행 실패(Spot 용량 부족)
#
# Container Insights를 꺼서 RunningTaskCount 지표가 없다. 서비스 중단은 TG 정상 대상 수와 ECS 서비스 이벤트로 본다.
# 트래픽이 거의 없어 비율 알람은 요청 수가 적을 때 울리지 않게 한다.

locals {
  alb_alarm_services = toset(["rest", "websocket", "frontend"])

  alb_dimensions = {
    for svc in local.alb_alarm_services : svc => {
      LoadBalancer = data.aws_lb.prod.arn_suffix
      TargetGroup  = aws_lb_target_group.service[svc].arn_suffix
    }
  }

  # RDS db.t4g.micro 최대 연결 약 85개
  rds_connection_threshold = 70
}

# ---------------------------------------------------------------------------
# ALB / 서비스
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "tg_unhealthy" {
  for_each = local.alb_alarm_services

  alarm_name          = "${local.name_prefix}-${each.key}-no-healthy-target"
  alarm_description   = "v4 ${each.key} 정상 대상 0개 3분 (서비스 중단, Spot 회수·배포 실패 확인)"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  dimensions          = local.alb_dimensions[each.key]
}

resource "aws_cloudwatch_metric_alarm" "tg_5xx_ratio" {
  for_each = local.alb_alarm_services

  alarm_name          = "${local.name_prefix}-${each.key}-5xx-ratio"
  alarm_description   = "v4 ${each.key} 5xx 비율 5% 초과 5분 중 3분 (분당 요청 10건 이상일 때만)"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  threshold           = 5
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "ratio"
    expression  = "IF(requests >= 10, 100 * FILL(errors, 0) / requests, 0)"
    label       = "5xx percent"
    return_data = true
  }

  metric_query {
    id = "errors"

    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_Target_5XX_Count"
      period      = 60
      stat        = "Sum"
      dimensions  = local.alb_dimensions[each.key]
    }
  }

  metric_query {
    id = "requests"

    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "RequestCount"
      period      = 60
      stat        = "Sum"
      dimensions  = local.alb_dimensions[each.key]
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "rest_p95" {
  alarm_name          = "${local.name_prefix}-rest-p95"
  alarm_description   = "v4 rest p95 1초 초과 5분 중 3분"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  extended_statistic  = "p95"
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  threshold           = 1
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = local.alb_dimensions["rest"]
}

resource "aws_cloudwatch_metric_alarm" "websocket_connection_errors" {
  alarm_name          = "${local.name_prefix}-websocket-connection-errors"
  alarm_description   = "v4 websocket 대상 연결 오류 발생"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetConnectionErrorCount"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = local.alb_dimensions["websocket"]
}

# ECS 기본 지표(Container Insights 없이 제공)로 메모리 한도에 다가가는지 본다 (OOM 전조)
resource "aws_cloudwatch_metric_alarm" "service_memory" {
  for_each = local.service_specs

  alarm_name          = "${local.name_prefix}-${each.key}-memory"
  alarm_description   = "v4 ${each.key} 메모리 사용률 90% 초과 10분 (태스크 메모리 상향 검토)"
  namespace           = "AWS/ECS"
  metric_name         = "MemoryUtilization"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 90
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = aws_ecs_cluster.this.name
    ServiceName = aws_ecs_service.service[each.key].name
  }
}

# ---------------------------------------------------------------------------
# RDS (V2 소유, 지표만 본다)
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "rds_connections" {
  alarm_name          = "${local.name_prefix}-rds-connections"
  alarm_description   = "prod RDS 연결 ${local.rds_connection_threshold}개 초과 (micro 최대 약 85개)"
  namespace           = "AWS/RDS"
  metric_name         = "DatabaseConnections"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  threshold           = local.rds_connection_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = data.aws_db_instance.prod.db_instance_identifier
  }
}

resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  alarm_name          = "${local.name_prefix}-rds-cpu"
  alarm_description   = "prod RDS CPU 80% 초과 15분"
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = data.aws_db_instance.prod.db_instance_identifier
  }
}

# T4g RDS는 기본 unlimited 모드다. 크레딧 초과분이 과금되기 시작하면 알린다
resource "aws_cloudwatch_metric_alarm" "rds_surplus_credits_charged" {
  alarm_name          = "${local.name_prefix}-rds-surplus-credits-charged"
  alarm_description   = "prod RDS CPU 크레딧 초과 과금 발생 (unlimited 모드)"
  namespace           = "AWS/RDS"
  metric_name         = "CPUSurplusCreditsCharged"
  statistic           = "Sum"
  period              = 3600
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = data.aws_db_instance.prod.db_instance_identifier
  }
}

resource "aws_cloudwatch_metric_alarm" "rds_free_storage" {
  alarm_name          = "${local.name_prefix}-rds-free-storage"
  alarm_description   = "prod RDS 남은 저장 공간 2GiB 미만"
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 2147483648
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = data.aws_db_instance.prod.db_instance_identifier
  }
}

# ---------------------------------------------------------------------------
# 데이터 호스트 (시스템 상태 검사 실패 → 자동 복구 알람은 data_host.tf)
#   메모리·디스크 지표는 CloudWatch 에이전트가 없어 수집하지 않는다. docker stats로 확인한다.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "data_host_instance_check" {
  alarm_name          = "${local.name_prefix}-data-host-instance-check"
  alarm_description   = "v4 데이터 호스트 인스턴스 상태 검사 실패 (OS 응답 없음, 재부팅 검토)"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_Instance"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "breaching"

  dimensions = {
    InstanceId = aws_instance.data_host.id
  }
}

resource "aws_cloudwatch_metric_alarm" "data_host_cpu" {
  alarm_name          = "${local.name_prefix}-data-host-cpu"
  alarm_description   = "v4 데이터 호스트 CPU 80% 초과 15분 (t3 unlimited 초과 과금 가능)"
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    InstanceId = aws_instance.data_host.id
  }
}

# ---------------------------------------------------------------------------
# Discord 연결 (EventBridge API Destination)
# ---------------------------------------------------------------------------

data "aws_ssm_parameter" "discord_incident_webhook" {
  name            = var.discord_webhook_parameter
  with_decryption = true
}

resource "aws_cloudwatch_event_connection" "discord" {
  name               = "${local.name_prefix}-discord"
  description        = "Discord webhook (v4 alarms)"
  authorization_type = "API_KEY"

  # Discord webhook은 인증 헤더가 필요 없다. API Destination이 연결을 요구해 출처 표시용 헤더를 둔다.
  auth_parameters {
    api_key {
      key   = "X-Moyeota-Source"
      value = "cloudwatch-alarm"
    }
  }
}

resource "aws_cloudwatch_event_api_destination" "discord" {
  name                             = "${local.name_prefix}-discord-incident"
  description                      = "Discord #incident webhook"
  connection_arn                   = aws_cloudwatch_event_connection.discord.arn
  invocation_endpoint              = data.aws_ssm_parameter.discord_incident_webhook.value
  http_method                      = "POST"
  invocation_rate_limit_per_second = 1
}

data "aws_iam_policy_document" "events_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "events_discord" {
  name               = "${local.name_prefix}-events-discord"
  assume_role_policy = data.aws_iam_policy_document.events_assume.json
}

resource "aws_iam_role_policy" "events_discord" {
  name = "invoke-discord-api-destination"
  role = aws_iam_role.events_discord.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "events:InvokeApiDestination"
      Resource = aws_cloudwatch_event_api_destination.discord.arn
    }]
  })
}

# ---------------------------------------------------------------------------
# 이벤트 규칙 → Discord
#   메시지에는 따옴표가 섞일 수 있는 사유(reason, cause)를 넣지 않는다. JSON이 깨지기 때문이다. 콘솔 링크로 대신한다.
# ---------------------------------------------------------------------------

locals {
  service_arn_prefix = "arn:${local.partition}:ecs:${local.region}:${local.account_id}:service/${local.cluster_name}/"

  discord_rules = {
    alarm = {
      description = "CloudWatch alarms named ${local.name_prefix}-* changing to ALARM or OK"
      pattern = {
        source        = ["aws.cloudwatch"]
        "detail-type" = ["CloudWatch Alarm State Change"]
        detail = {
          alarmName = [{ prefix = "${local.name_prefix}-" }]
          state     = { value = ["ALARM", "OK"] }
        }
      }
      input_paths = {
        alarm    = "$.detail.alarmName"
        state    = "$.detail.state.value"
        previous = "$.detail.previousState.value"
        time     = "$.time"
        region   = "$.region"
      }
      template = <<-EOT
        {"content": "**[<state>]** `<alarm>` (이전 <previous>)\n<time>\nhttps://<region>.console.aws.amazon.com/cloudwatch/home?region=<region>#alarmsV2:alarm/<alarm>"}
      EOT
    }

    ecs_service = {
      description = "v4 ECS service WARN/ERROR events (placement failure, task start impaired)"
      pattern = {
        source        = ["aws.ecs"]
        "detail-type" = ["ECS Service Action"]
        resources     = [{ prefix = local.service_arn_prefix }]
        detail        = { eventType = ["WARN", "ERROR"] }
      }
      input_paths = {
        event   = "$.detail.eventName"
        level   = "$.detail.eventType"
        service = "$.resources[0]"
        time    = "$.time"
      }
      template = <<-EOT
        {"content": "**[ECS <level>]** `<event>`\n<service>\n<time>\nhttps://${local.region}.console.aws.amazon.com/ecs/v2/clusters/${local.cluster_name}/services?region=${local.region}"}
      EOT
    }

    ecs_deployment = {
      description = "v4 ECS deployment failed (circuit breaker rollback)"
      pattern = {
        source        = ["aws.ecs"]
        "detail-type" = ["ECS Deployment State Change"]
        resources     = [{ prefix = local.service_arn_prefix }]
        detail        = { eventName = ["SERVICE_DEPLOYMENT_FAILED"] }
      }
      input_paths = {
        service = "$.resources[0]"
        time    = "$.time"
      }
      template = <<-EOT
        {"content": "**[ECS 배포 실패]** 롤백됨\n<service>\n<time>\nhttps://${local.region}.console.aws.amazon.com/ecs/v2/clusters/${local.cluster_name}/services?region=${local.region}"}
      EOT
    }

    asg = {
      description = "v4 app host terminated (incl. Spot interruption) or failed to launch (Spot capacity)"
      pattern = {
        source        = ["aws.autoscaling"]
        "detail-type" = ["EC2 Instance Terminate Successful", "EC2 Instance Launch Unsuccessful"]
        detail        = { AutoScalingGroupName = [for asg in aws_autoscaling_group.app : asg.name] }
      }
      input_paths = {
        type     = "$.detail-type"
        asg      = "$.detail.AutoScalingGroupName"
        instance = "$.detail.EC2InstanceId"
        time     = "$.time"
      }
      template = <<-EOT
        {"content": "**[앱 호스트]** <type>\n`<asg>` <instance>\n<time>\n실행 실패가 반복되면 README의 Spot 용량 부족 런북(capacity_mode = od)을 따른다.\nhttps://${local.region}.console.aws.amazon.com/ec2/home?region=${local.region}#AutoScalingGroupDetails:id=<asg>;view=activity"}
      EOT
    }
  }
}

resource "aws_cloudwatch_event_rule" "discord" {
  for_each = local.discord_rules

  name          = "${local.name_prefix}-${replace(each.key, "_", "-")}-to-discord"
  description   = each.value.description
  event_pattern = jsonencode(each.value.pattern)
}

resource "aws_cloudwatch_event_target" "discord" {
  for_each = local.discord_rules

  rule     = aws_cloudwatch_event_rule.discord[each.key].name
  arn      = aws_cloudwatch_event_api_destination.discord.arn
  role_arn = aws_iam_role.events_discord.arn

  input_transformer {
    input_paths    = each.value.input_paths
    input_template = each.value.template
  }

  retry_policy {
    maximum_event_age_in_seconds = 3600
    maximum_retry_attempts       = 10
  }
}
