# v4 전용 SSM 파라미터 (/moyeota/v4/prod/*). V2 경로의 broker 값(MSK, ElastiCache)과 겹치지 않게 분리한다.
#   broker/*  : 데이터 호스트 IP가 고정이라 Terraform이 값을 직접 쓴다
#   backend/MONGODB_URI, mongo/* : 비밀번호가 들어가므로 데이터 호스트(data-host-apply)가 부팅 시 채운다

resource "aws_ssm_parameter" "broker" {
  for_each = {
    KAFKA_BOOTSTRAP_SERVERS = "${local.data_host_private_ip}:${local.kafka_port}"
    REDIS_HOST              = local.data_host_private_ip
    REDIS_PORT              = tostring(local.redis_port)
  }

  name        = "/${var.v4_config_path}/broker/${each.key}"
  description = "v4 data host (Terraform 관리, 콘솔에서 수정하지 않는다)"
  type        = "String"
  tier        = "Standard"
  value       = each.value

  tags = {
    Group = "broker"
  }
}

# 값은 data-host-apply가 채운다. 이후 값 변경을 Terraform이 되돌리지 않는다.
resource "aws_ssm_parameter" "mongo" {
  for_each = {
    uri           = "/${var.v4_config_path}/backend/MONGODB_URI"
    root_password = "/${var.v4_config_path}/mongo/ROOT_PASSWORD"
    app_password  = "/${var.v4_config_path}/mongo/APP_PASSWORD"
  }

  name  = each.value
  type  = "SecureString"
  tier  = "Standard"
  value = "CHANGE_ME"

  lifecycle {
    ignore_changes = [value]
  }

  tags = {
    Group = "mongodb"
  }
}
