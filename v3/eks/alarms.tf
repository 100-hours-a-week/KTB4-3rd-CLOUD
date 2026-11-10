# 전환 롤백 기준 알람. 상태가 바뀌면 Discord #incident로 보낸다.
# V2의 Discord 연결은 AWS에 만들어져 있지 않아 이 root에서 따로 만든다.
locals {
  prod_alarm_services = toset(["rest", "websocket", "frontend"])
}

data "aws_lb" "prod" {
  name = "${var.project_name}-alb"
}

resource "aws_cloudwatch_metric_alarm" "prod_5xx_ratio" {
  for_each = local.prod_alarm_services

  alarm_name          = "${local.cluster_name}-prod-${each.key}-5xx-ratio"
  alarm_description   = "EKS prod ${each.key} 5xx 비율 1% 초과 5분"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  threshold           = 1
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "ratio"
    expression  = "IF(requests > 0, 100 * FILL(errors, 0) / requests, 0)"
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
      dimensions = {
        LoadBalancer = data.aws_lb.prod.arn_suffix
        TargetGroup  = aws_lb_target_group.eks["prod-${each.key}"].arn_suffix
      }
    }
  }

  metric_query {
    id = "requests"

    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "RequestCount"
      period      = 60
      stat        = "Sum"
      dimensions = {
        LoadBalancer = data.aws_lb.prod.arn_suffix
        TargetGroup  = aws_lb_target_group.eks["prod-${each.key}"].arn_suffix
      }
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "prod_rest_p95" {
  alarm_name          = "${local.cluster_name}-prod-rest-p95"
  alarm_description   = "EKS prod rest p95 1초 초과"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  extended_statistic  = "p95"
  period              = 60
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 1
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = data.aws_lb.prod.arn_suffix
    TargetGroup  = aws_lb_target_group.eks["prod-rest"].arn_suffix
  }
}

resource "aws_cloudwatch_metric_alarm" "prod_websocket_connection_errors" {
  alarm_name          = "${local.cluster_name}-prod-websocket-connection-errors"
  alarm_description   = "EKS prod websocket 대상 연결 오류 발생"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetConnectionErrorCount"
  statistic           = "Sum"
  period              = 60
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = data.aws_lb.prod.arn_suffix
    TargetGroup  = aws_lb_target_group.eks["prod-websocket"].arn_suffix
  }
}

resource "aws_cloudwatch_metric_alarm" "prod_rds_connections" {
  alarm_name          = "${local.cluster_name}-prod-rds-connections"
  alarm_description   = "prod RDS 연결 120개 초과"
  namespace           = "AWS/RDS"
  metric_name         = "DatabaseConnections"
  statistic           = "Maximum"
  period              = 60
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 120
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = "${var.project_name}-prod"
  }
}

data "aws_ssm_parameter" "discord_incident_webhook" {
  name            = "/moyeota/v2/monitoring/DISCORD_WEBHOOK_INCIDENT"
  with_decryption = true
}

resource "aws_cloudwatch_event_connection" "discord" {
  name               = "${local.cluster_name}-discord"
  description        = "Discord webhook (EKS cutover alarms)"
  authorization_type = "API_KEY"

  auth_parameters {
    api_key {
      key   = "X-Moyeota-Source"
      value = "cloudwatch-alarm"
    }
  }
}

resource "aws_cloudwatch_event_api_destination" "discord" {
  name                             = "${local.cluster_name}-discord-incident"
  description                      = "Discord #incident webhook"
  connection_arn                   = aws_cloudwatch_event_connection.discord.arn
  invocation_endpoint              = data.aws_ssm_parameter.discord_incident_webhook.value
  http_method                      = "POST"
  invocation_rate_limit_per_second = 1
}

resource "aws_cloudwatch_event_rule" "alarm_state_change" {
  name        = "${local.cluster_name}-alarm-state-change"
  description = "CloudWatch alarms named ${local.cluster_name}-* changing to ALARM or OK"

  event_pattern = jsonencode({
    source        = ["aws.cloudwatch"]
    "detail-type" = ["CloudWatch Alarm State Change"]
    detail = {
      alarmName = [{ prefix = "${local.cluster_name}-" }]
      state = {
        value = ["ALARM", "OK"]
      }
    }
  })
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
  name               = "${local.cluster_name}-events-discord"
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

resource "aws_cloudwatch_event_target" "alarm_to_discord" {
  rule     = aws_cloudwatch_event_rule.alarm_state_change.name
  arn      = aws_cloudwatch_event_api_destination.discord.arn
  role_arn = aws_iam_role.events_discord.arn

  input_transformer {
    input_paths = {
      alarm    = "$.detail.alarmName"
      state    = "$.detail.state.value"
      previous = "$.detail.previousState.value"
      time     = "$.time"
      region   = "$.region"
    }
    # 사유(reason)는 따옴표가 섞여 JSON이 깨질 수 있어 넣지 않고 콘솔 링크로 대신한다.
    input_template = <<-EOT
      {"content": "**[<state>]** `<alarm>` (이전 <previous>)\n<time>\nhttps://<region>.console.aws.amazon.com/cloudwatch/home?region=<region>#alarmsV2:alarm/<alarm>"}
    EOT
  }

  retry_policy {
    maximum_event_age_in_seconds = 3600
    maximum_retry_attempts       = 10
  }
}
