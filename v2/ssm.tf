# =============================================================================
# 앱 환경 변수 (SSM Parameter Store)
#   경로 : /<config_path_prefix>/<stage>/<group>/<KEY>   예) /moyeota/v2/prod/backend/DB_PASSWORD
#          config_path_prefix 기본값 moyeota/v2 (variables.tf) — V3는 moyeota/v3로 분리
#   권한 : modules/ecs/ecs-cluster/iam.tf — execution role이 자기 스테이지 경로(/<config_path_prefix>/<stage>/*)만 읽는다
#
#   Terraform은 파라미터의 "존재·경로·타입"만 관리한다.
#     - 생성 시 값은 CHANGE_ME, 이후 값은 ignore_changes → 실제 값은 콘솔(Parameter Store)에서 수정한다 (state에 값이 남지 않음)
#     - 누락 확인 : aws ssm get-parameters-by-path --path /moyeota/v2/<stage>/ --recursive --with-decryption \
#                     --query "Parameters[?Value=='CHANGE_ME'].Name" --output text
#     - 값은 태스크 시작 시점에 주입되므로, 값 변경 후에는 서비스를 재배포해야 반영된다 (콘솔 "새 배포 강제")
#     - 변경 이력 : CloudTrail(PutParameter) + 파라미터 버전 이력
#
#   키 추가 절차 : ssm_param_keys에 키 추가 → terraform apply → 콘솔에서 값 입력 → 서비스 재배포
#   주의 : 여기서 키를 빼면 apply 시 SSM의 실제 값도 함께 삭제된다
# =============================================================================

locals {
  # 그룹 → 환경 변수 키. 그룹 이름이 SSM 경로의 한 단계가 된다.
  ssm_param_keys = {
    # BE(rest·websocket 공용 이미지) — V1 env/backend.env 를 그대로 옮기고, compose가 넣던 값을 더한다.
    #   SSM은 빈 값을 저장할 수 없다. "선택" 키를 비워 둘 거라면 이 목록에서 지운다
    #   (남겨 두면 CHANGE_ME 문자열이 그대로 주입된다. 예: CORS origin에 CHANGE_ME).
    #   JVM 힙 옵션은 태스크 메모리와 함께 정해야 하므로 SSM이 아니라
    #   locals.tf ecs_service_specs.environment.JAVA_TOOL_OPTIONS 에서 관리한다 (V1 JAVA_OPTS 대체).
    backend = [
      # Spring — V1은 compose.yaml environment 에서 고정 주입하던 값
      "SPRING_PROFILES_ACTIVE",
      "SERVER_FORWARD_HEADERS_STRATEGY",

      # DB — V1은 DB_HOST=mysql, DB_PORT=3306 을 compose.yaml 에서 고정 주입했다
      "DB_HOST",
      "DB_PORT",
      "DB_NAME",
      "DB_USERNAME",
      "DB_PASSWORD",

      # 인증·암호화 (V1 값이 노출된 것으로 보고 새 값으로 교체한다)
      "JWT_SECRET",
      "ACCOUNT_ENC_KEY",
      "MOYEOTA_AUTH_COOKIE_SECURE",
      "MOYEOTA_AUTH_COOKIE_SAMESITE",

      # 카카오
      "KAKAO_CLIENT_ID",
      "KAKAO_CLIENT_SECRET",
      "KAKAO_REDIRECT_URI",
      "KAKAO_ADMIN_KEY", # 선택 (application-prod.yaml 기본값 빈 값)

      # 프론트 연동 (CORS·OAuth 콜백)
      "FRONT_URL",
      "FRONT_CALLBACK_URI",
      "EXTRA_FRONT_ORIGINS", # 선택 (기본값 빈 값)

      # 이미지 업로드
      "S3_BUCKET",
      "IMAGE_PUBLIC_BASE_URL", # 선택 (기본값 빈 값)

      # Actuator
      "MANAGEMENT_ENDPOINTS_WEB_EXPOSURE_INCLUDE",
      "MANAGEMENT_ENDPOINT_PROMETHEUS_ENABLED",
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

# =============================================================================
# CI 빌드 값 (FE NEXT_PUBLIC_*)
#   경로 : /<config_path_prefix>/build/<group>/<KEY>   예) /moyeota/v2/build/frontend/NEXT_PUBLIC_API_BASE_URL
#   스테이지가 없는 이유 : 브랜치당 1회 빌드한 digest를 Stg → Prod로 그대로 승격하므로,
#                          빌드 시 번들에 박히는 값은 스테이지마다 다를 수 없다 (issues/ecs-ssm-env-management.md 3.1)
#   읽는 주체 : FE CI의 CI Role(이미지를 push하는 develop·release/* 빌드만). ECS Execution Role은 읽지 못한다.
#   값 입력   : 콘솔(Parameter Store)에서 수정 → FE CI를 다시 실행해야 이미지에 반영된다
# =============================================================================

locals {
  ssm_build_param_keys = {
    frontend = [
      "NEXT_PUBLIC_API_BASE_URL",
      "NEXT_PUBLIC_KAKAO_MAP_APP_KEY",
      "NEXT_PUBLIC_GA_ID",              # 선택값: GA를 쓰지 않으면 이 줄을 지운다 (CI는 빈 값으로 빌드)
      "NEXT_PUBLIC_CLARITY_PROJECT_ID", # 선택값: Clarity를 쓰지 않으면 이 줄을 지운다 (CI는 빈 값으로 빌드)
      "NEXT_PUBLIC_SENTRY_DSN",
      "NEXT_PUBLIC_SENTRY_ENVIRONMENT",
      "NEXT_PUBLIC_SENTRY_TRACES_SAMPLE_RATE",
    ]
  }

  ssm_build_params = merge([
    for group, param_keys in local.ssm_build_param_keys : {
      for key in param_keys : "${group}/${key}" => { group = group, key = key }
    }
  ]...)
}

resource "aws_ssm_parameter" "build" {
  for_each = local.ssm_build_params

  name        = "/${var.config_path_prefix}/build/${each.key}"
  description = "CI build ${each.value.group} ${each.value.key} — 값은 CLI/콘솔로 관리 (Terraform은 값을 추적하지 않음)"
  type        = "SecureString"
  tier        = "Standard"
  value       = "CHANGE_ME"

  tags = {
    Stage = "build"
    Group = each.value.group
  }

  lifecycle {
    ignore_changes = [value]
  }
}

# V1 루트(infra/)가 관리하는 CI Role에 빌드 값 읽기 권한만 덧붙인다.
#   Role 자체·신뢰 정책·ECR 권한은 V1 그대로. 이 inline policy만 V2 state가 소유한다.
data "aws_iam_role" "github_ci" {
  count = var.github_ci_role_name == null ? 0 : 1
  name  = var.github_ci_role_name
}

data "aws_iam_policy_document" "github_ci_build_params" {
  statement {
    sid       = "ReadBuildParameters"
    actions   = ["ssm:GetParameters"]
    resources = [for p in aws_ssm_parameter.build : p.arn]
  }

  statement {
    sid       = "DecryptViaSsm"
    actions   = ["kms:Decrypt"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.aws_region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "github_ci_build_params" {
  count = var.github_ci_role_name == null ? 0 : 1

  name   = "${var.project_name}-read-build-params"
  role   = data.aws_iam_role.github_ci[0].id
  policy = data.aws_iam_policy_document.github_ci_build_params.json
}
