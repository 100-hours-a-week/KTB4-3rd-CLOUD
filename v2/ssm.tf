# =============================================================================
# 앱 환경 변수 (SSM Parameter Store)
#   경로 : /<config_path_prefix>/<stage>/<group>/<KEY>   예) /moyeota/v2/prod/backend/DB_PASSWORD
#          config_path_prefix 기본값 moyeota/v2 (variables.tf) — V3는 moyeota/v3로 분리
#   권한 : modules/ecs/ecs-cluster/iam.tf — execution role이 자기 스테이지 경로(/<config_path_prefix>/<stage>/*)만 읽는다
#
#   Terraform은 파라미터의 "존재·경로·타입"만 관리한다.
#     - 생성 시 값은 CHANGE_ME, 이후 값은 ignore_changes → 실제 값은 CLI/콘솔로 넣는다 (state에 값이 남지 않음)
#     - 값 입력/누락 확인 : v2/scripts/ssm-params.sh
#     - 값은 태스크 시작 시점에 주입되므로, 값 변경 후에는 서비스를 재배포해야 반영된다
#
#   키 추가 절차 : ssm_param_keys에 키 추가 → terraform apply → ssm-params.sh set → 서비스 재배포
#   주의 : 여기서 키를 빼면 apply 시 SSM의 실제 값도 함께 삭제된다
# =============================================================================

locals {
  # 그룹 → 환경 변수 키. 그룹 이름이 SSM 경로의 한 단계가 된다.
  ssm_param_keys = {
    backend = [
      "SPRING_PROFILES_ACTIVE",
      "DB_HOST",
      "DB_PORT",
      "DB_NAME",
      "DB_USERNAME",
      "DB_PASSWORD",
      "SERVER_FORWARD_HEADERS_STRATEGY",
    ]
    frontend = [
      # NEXT_PUBLIC_* 는 빌드 시점 값이므로 여기 두지 않는다 (FE CI build-arg)
      "SENTRY_DSN",
      "SENTRY_ENVIRONMENT",
      "SENTRY_TRACES_SAMPLE_RATE",
    ]
    ai = []
  }

  # ECS 서비스 → 주입받을 그룹. rest·websocket은 같은 backend 값을 공유한다.
  ecs_service_param_groups = {
    rest      = ["backend"]
    websocket = ["backend"]
    frontend  = ["frontend"]
    fastapi   = ["ai"]
  }

  # "dev/backend/DB_PASSWORD" → { stage, group, key }
  ssm_params = merge(flatten([
    for stage in keys(local.ecs_stages) : [
      for group, param_keys in local.ssm_param_keys : {
        for key in param_keys : "${stage}/${group}/${key}" => {
          stage = stage
          group = group
          key   = key
        }
      }
    ]
  ])...)
}

resource "aws_ssm_parameter" "app" {
  for_each = local.ssm_params

  name        = "/${var.config_path_prefix}/${each.key}"
  description = "${each.value.stage} ${each.value.group} ${each.value.key} — 값은 CLI/콘솔로 관리 (Terraform은 값을 추적하지 않음)"
  type        = "SecureString"
  tier        = "Standard"
  value       = "CHANGE_ME"

  tags = {
    Stage = each.value.stage
    Group = each.value.group
  }

  lifecycle {
    ignore_changes = [value]
  }
}
