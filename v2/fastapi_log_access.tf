# =============================================================================
# FastAPI(AI) 모니터링 기능용 CloudWatch Logs 읽기 권한
#   이슈: issues/v2-fastapi-log-read-access.md
#
#   요청: AI 파트 — FastAPI가 자기 로그를 조회하는 모니터링 기능 (Logs Insights + 이벤트 조회)
#
#   1) 서버 (스테이지별 FastAPI Task Role)
#      - 액세스 키 없음. boto3가 컨테이너 자격 증명(Task Role)을 자동으로 쓴다
#      - Execution Role이 아니라 Task Role에 붙인다 (Execution Role은 이미지 pull·로그 전송·SSM 주입용)
#      - 같은 스테이지의 fastapi 로그 그룹(/ecs/<project>-<stage>/fastapi)만. 스테이지마다 정책을 따로 둬서
#        dev 태스크가 prod 로그를 읽을 수 없다
#      - prod는 ecs_stages에 prod가 들어가 prod fastapi 서비스가 생기면 자동으로 붙는다
#
#   2) 로컬 테스트 (AI IAM 사용자)
#      - 액세스 키를 쓰지 않는다. `aws login`(콘솔 자격 증명 → 단기 자격 증명, 15분마다 자동 갱신, 최대 12시간)으로만
#        CLI·SDK를 쓴다 — 오래 사는 키가 PC에 남지 않는다
#      - 액세스 키 생성·활성화는 명시적으로 거부한다 (나중에 다른 그룹에 들어가도 키를 만들 수 없게)
#      - dev fastapi 로그 그룹만. prod 로그는 실사용자 데이터가 섞여 로컬에서 보지 않는다
#      - IAM Identity Center(SSO)는 쓰지 않는다 — 프리티어 계정이라서. 크레딧 계정으로 옮기면 SSO 프로필로 대체한다
#
#   허용 동작
#     - 로그 그룹 제한 : StartQuery, FilterLogEvents, GetLogEvents
#     - 리소스 제한 불가 : GetQueryResults, StopQuery (쿼리 ID를 알아야 쓸 수 있음)
#   주지 않음: DescribeLogGroups — 리소스 제한이 안 돼 계정 전체 로그 그룹 이름이 보인다. 로그 그룹 이름은 설정값으로 넘긴다
#             (※ ECS Exec 채널 정책(modules/ecs/ecs-cluster/iam.tf)이 Task Role에 DescribeLogGroups(*)를 이미 준다)
#
#   만료: 모든 허용 문장에 aws:CurrentTime 조건 (UTC 기준)
#         기본값 2026-11-15T15:00:00Z = 2026-11-16 00:00 KST. 이후 서버 모니터링 기능도 AccessDenied로 실패한다
#         정책 조건이 만료될 뿐 IAM 사용자·정책 리소스는 남는다 → 만료 뒤 ai_log_reader_users 비우고 apply
# =============================================================================

locals {
  fastapi_log_partition  = data.aws_partition.current.partition
  fastapi_log_account_id = data.aws_caller_identity.current.account_id

  # 실제로 떠 있는 스테이지의 fastapi만 (서비스가 없으면 정책도 만들지 않는다)
  fastapi_log_read_targets = {
    for stage in var.fastapi_log_read_stages : stage => {
      task_role_name = module.ecs_cluster[stage].task_role_names["fastapi"]
      log_group_name = module.ecs_service["${stage}-fastapi"].log_group_name
      log_group_arn  = "arn:${local.fastapi_log_partition}:logs:${var.aws_region}:${local.fastapi_log_account_id}:log-group:${module.ecs_service["${stage}-fastapi"].log_group_name}"
    }
    if contains(keys(local.ecs_service_instances), "${stage}-fastapi")
  }

  # 로컬 테스트는 dev 로그만 — dev fastapi가 없으면 사용자·그룹도 만들지 않는다
  ai_log_reader_enabled = length(var.ai_log_reader_users) > 0 && contains(keys(local.fastapi_log_read_targets), "dev")
}

# -----------------------------------------------------------------------------
# 1) 서버 — 스테이지별 FastAPI Task Role
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "fastapi_log_read" {
  for_each = local.fastapi_log_read_targets

  statement {
    sid = "ReadOwnStageFastApiLogs"
    actions = [
      "logs:StartQuery",
      "logs:FilterLogEvents",
      "logs:GetLogEvents",
    ]
    # 로그 그룹 ARN(StartQuery·FilterLogEvents) + 로그 스트림까지 덮는 :* (GetLogEvents)
    resources = [each.value.log_group_arn, "${each.value.log_group_arn}:*"]

    condition {
      test     = "DateLessThan"
      variable = "aws:CurrentTime"
      values   = [var.fastapi_log_read_expires_at]
    }
  }

  # 리소스 제한이 안 되는 Logs Insights 결과 API — 로그 내용 접근은 위 StartQuery 범위로 제한된다
  statement {
    sid = "LogsInsightsQueryResults"
    actions = [
      "logs:GetQueryResults",
      "logs:StopQuery",
    ]
    resources = ["*"]

    condition {
      test     = "DateLessThan"
      variable = "aws:CurrentTime"
      values   = [var.fastapi_log_read_expires_at]
    }
  }
}

resource "aws_iam_role_policy" "fastapi_log_read" {
  for_each = local.fastapi_log_read_targets

  name   = "read-${each.key}-fastapi-logs"
  role   = each.value.task_role_name
  policy = data.aws_iam_policy_document.fastapi_log_read[each.key].json
}

# -----------------------------------------------------------------------------
# 2) 로컬 테스트 — AI IAM 사용자 (aws login 전용, 액세스 키 없음)
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "ai_log_reader" {
  count = local.ai_log_reader_enabled ? 1 : 0

  # --- dev fastapi 로그 읽기 -----------------------------------------------------
  statement {
    sid = "ReadDevFastApiLogs"
    actions = [
      "logs:StartQuery",
      "logs:FilterLogEvents",
      "logs:GetLogEvents",
    ]
    resources = [
      local.fastapi_log_read_targets["dev"].log_group_arn,
      "${local.fastapi_log_read_targets["dev"].log_group_arn}:*",
    ]

    condition {
      test     = "DateLessThan"
      variable = "aws:CurrentTime"
      values   = [var.fastapi_log_read_expires_at]
    }
  }

  statement {
    sid = "LogsInsightsQueryResults"
    actions = [
      "logs:GetQueryResults",
      "logs:StopQuery",
    ]
    resources = ["*"]

    condition {
      test     = "DateLessThan"
      variable = "aws:CurrentTime"
      values   = [var.fastapi_log_read_expires_at]
    }
  }

  # --- aws login (콘솔 자격 증명 → CLI·SDK 단기 자격 증명) ------------------------
  # AWS 관리형 정책 SignInLocalDevelopmentAccess와 같은 동작을, 같은 기기 로그인(localhost)으로만 좁히고 만료를 건다
  # 다른 기기 로그인(aws login --remote, public-client/remote)은 주지 않는다
  statement {
    sid = "LocalDevelopmentSignIn"
    actions = [
      "signin:AuthorizeOAuth2Access",
      "signin:CreateOAuth2Token",
    ]
    resources = ["arn:${local.fastapi_log_partition}:signin:*:${local.fastapi_log_account_id}:oauth2/public-client/localhost"]

    condition {
      test     = "DateLessThan"
      variable = "aws:CurrentTime"
      values   = [var.fastapi_log_read_expires_at]
    }
  }

  # --- 본인 비밀번호 변경 (첫 로그인 때 변경 강제) ---------------------------------
  statement {
    sid = "ManageOwnPassword"
    actions = [
      "iam:GetUser",
      "iam:ChangePassword",
      "iam:GetLoginProfile",
    ]
    resources = ["arn:${local.fastapi_log_partition}:iam::${local.fastapi_log_account_id}:user/$${aws:username}"]
  }

  statement {
    sid       = "ReadPasswordPolicy"
    actions   = ["iam:GetAccountPasswordPolicy"]
    resources = ["*"]
  }

  # --- 액세스 키 차단 (aws login만 쓴다) ------------------------------------------
  statement {
    sid    = "DenyLongLivedAccessKeys"
    effect = "Deny"
    actions = [
      "iam:CreateAccessKey",
      "iam:UpdateAccessKey",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "ai_log_reader" {
  count = local.ai_log_reader_enabled ? 1 : 0

  name        = "${var.project_name}-ai-dev-fastapi-log-read"
  description = "AI part local test: read dev FastAPI logs via aws login only (no access keys), expires ${var.fastapi_log_read_expires_at}"
  policy      = data.aws_iam_policy_document.ai_log_reader[0].json
}

resource "aws_iam_group" "ai_log_reader" {
  count = local.ai_log_reader_enabled ? 1 : 0

  name = var.ai_log_reader_group_name
}

resource "aws_iam_group_policy_attachment" "ai_log_reader" {
  count = local.ai_log_reader_enabled ? 1 : 0

  group      = aws_iam_group.ai_log_reader[0].name
  policy_arn = aws_iam_policy.ai_log_reader[0].arn
}

resource "aws_iam_user" "ai_log_reader" {
  for_each = local.ai_log_reader_enabled ? toset(var.ai_log_reader_users) : toset([])

  name          = each.value
  force_destroy = true # 로그인 프로필이 있어도 삭제되게
}

resource "aws_iam_user_group_membership" "ai_log_reader" {
  for_each = aws_iam_user.ai_log_reader

  user   = each.value.name
  groups = [aws_iam_group.ai_log_reader[0].name]
}

# aws login은 콘솔 로그인 자격 증명을 쓰므로 로그인 프로필이 필요하다 — 초기 비밀번호는 첫 로그인 때 변경 강제
resource "aws_iam_user_login_profile" "ai_log_reader" {
  for_each = aws_iam_user.ai_log_reader

  user                    = each.value.name
  password_reset_required = true

  lifecycle {
    ignore_changes = [password_length, password_reset_required]
  }
}

output "fastapi_log_group_names" {
  description = "스테이지 → FastAPI 로그 그룹 이름 (AI 파트에 전달, 앱 설정값으로 사용)"
  value       = { for stage, t in local.fastapi_log_read_targets : stage => t.log_group_name }
}

output "ai_log_reader_login_sessions" {
  description = "AI 사용자 ~/.aws/config의 login_session 값 (사용자 ARN)"
  value       = { for k, u in aws_iam_user.ai_log_reader : k => u.arn }
}

output "ai_log_reader_initial_passwords" {
  description = "AI 사용자 콘솔 초기 비밀번호 (첫 로그인 때 변경 강제). terraform output -json ai_log_reader_initial_passwords"
  value       = { for k, v in aws_iam_user_login_profile.ai_log_reader : k => v.password }
  sensitive   = true
}
