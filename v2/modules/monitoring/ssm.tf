# =============================================================================
# 모니터링 비밀값 (SSM Parameter Store, SecureString)
#   경로 : /<config_path_prefix>/monitoring/<KEY>   예) /moyeota/v2/monitoring/GRAFANA_ADMIN_PASSWORD
#   ssm.tf(앱 설정)와 같은 방식: Terraform은 존재·경로·타입만 관리하고 값은 콘솔·CLI로 넣는다 (state에 값이 남지 않음)
#   ECS Execution Role은 /<prefix>/<stage>/*만 읽으므로 monitoring 경로는 앱 태스크가 읽을 수 없다.
# =============================================================================

locals {
  ssm_path = "/${var.config_path_prefix}/monitoring"

  secret_keys = {
    GRAFANA_ADMIN_PASSWORD   = "Grafana admin 계정 비밀번호"
    DISCORD_WEBHOOK_INCIDENT = "P1(page) 알림 Discord 채널 웹훅 URL (#incident)"
    DISCORD_WEBHOOK_ALERTS   = "P2(ticket)·dev·stg 알림 Discord 채널 웹훅 URL (#alerts)"
  }
}

resource "aws_ssm_parameter" "secret" {
  for_each = local.secret_keys

  name        = "${local.ssm_path}/${each.key}"
  description = each.value
  type        = "SecureString"
  value       = "CHANGE_ME"

  tags = merge(var.tags, {
    Stage = "monitoring"
  })

  lifecycle {
    ignore_changes = [value]
  }
}
