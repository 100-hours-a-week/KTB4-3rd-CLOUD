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
