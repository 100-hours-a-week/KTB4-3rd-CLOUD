# =============================================================================
# 백엔드 파트 dev 접근 권한 (IAM 그룹·사용자)
#   이슈: issues/v2-dev-backend-iam-access.md
#
#   목적: BE가 인프라를 거치지 않고 dev 앱 로그·ECS 상태를 직접 보고, rest·websocket 컨테이너에 ECS Exec로 들어갈 수 있게 한다.
#
#   허용
#     - 로그       : dev rest·websocket·fastapi 로그 그룹만 조회 (Service Connect 프록시 로그 포함)
#                    exec 로그 그룹(/ecs/<cluster>/exec)은 다른 사람의 Exec 세션 기록이라 제외
#     - ECS 상태   : dev 클러스터 서비스·태스크·컨테이너 인스턴스 조회
#                    DescribeTaskDefinition·ListClusters는 리소스 제한이 안 되는 API라 계정 전체(*) — prod Task Definition도 보인다
#                    cloudwatch:GetMetricData·ListMetrics(콘솔 지표 그래프)도 계정 전체 — prod 지표가 보이는 것을 감수하기로 결정
#     - ECS Exec   : dev 클러스터, ecs:container-name이 rest·websocket일 때만
#     - SSM 값     : dev backend 그룹 파라미터(/<config_path_prefix>/dev/backend/*) 값 조회·수정
#                    수정은 덮어쓰기(ssm:Overwrite=true)만 허용 → 콘솔에서 새 파라미터를 만들 수 없다 (키 추가는 ssm.tf PR)
#                    덮어쓰기 때 타입(SecureString)을 바꾸는 것까지는 막지 못한다 — 바꾸면 다음 plan에 차이가 난다
#                    삭제·태그 변경은 주지 않는다 (존재·경로·타입은 Terraform 소유)
#     - 재배포     : dev rest·websocket 서비스 UpdateService ("새 배포 강제"로 바뀐 SSM 값 반영)
#                    UpdateService는 desired count·태스크 정의 변경도 막지 못한다 — dev 한정이라 감수
#     - 콘솔 로그인 : 초기 비밀번호는 첫 로그인 때 변경 강제, 본인 비밀번호·액세스 키만 관리
#
#   주지 않음: stg·prod 전체, 태스크 정의 등록, SSM 파라미터 생성·삭제, dev frontend·ai 그룹 SSM, ssm:StartSession 직접 호출
#   주의: Exec로 들어가면 컨테이너 환경변수(SSM에서 주입된 dev 비밀값)가 보인다 — dev 한정이라 감수
#
#   액세스 키는 Terraform으로 만들지 않는다 (비밀 키가 state에 남는다). 사용자가 콘솔에서 직접 만든다.
#   콘솔 초기 비밀번호는 state에 남지만, 첫 로그인 때 바뀌므로 그 뒤로는 의미가 없다.
# =============================================================================

locals {
  dev_backend_enabled = length(var.dev_backend_users) > 0 && contains(keys(local.ecs_stages), "dev")

  dev_backend_region     = var.aws_region
  dev_backend_account_id = data.aws_caller_identity.current.account_id
  dev_backend_partition  = data.aws_partition.current.partition

  dev_backend_cluster_name = local.dev_backend_enabled ? module.ecs_cluster["dev"].cluster_name : ""
  dev_backend_cluster_arn  = local.dev_backend_enabled ? module.ecs_cluster["dev"].cluster_arn : ""

  dev_backend_ecs_arn_prefix = "arn:${local.dev_backend_partition}:ecs:${local.dev_backend_region}:${local.dev_backend_account_id}"

  # BE가 값을 조회·수정할 dev SSM 경로 (/<config_path_prefix>/dev/<group>)
  #   파라미터 ARN을 하나씩 나열하면 키가 늘 때마다 정책이 커져 관리형 정책 한도(6,144자)에 걸리므로 경로 와일드카드로 준다
  dev_backend_ssm_path_arns = local.dev_backend_enabled ? [
    for g in var.dev_backend_ssm_groups :
    "arn:${local.dev_backend_partition}:ssm:${local.dev_backend_region}:${local.dev_backend_account_id}:parameter/${var.config_path_prefix}/dev/${g}"
  ] : []

  # BE가 재배포할 dev 서비스 (실제로 떠 있는 것만)
  dev_backend_deploy_service_arns = local.dev_backend_enabled ? [
    for svc in var.dev_backend_deploy_services :
    "${local.dev_backend_ecs_arn_prefix}:service/${local.dev_backend_cluster_name}/${module.ecs_service["dev-${svc}"].service_name}"
    if contains(keys(local.ecs_service_instances), "dev-${svc}")
  ] : []

  # 실제로 떠 있는 dev 서비스의 로그 그룹만 (서비스가 없으면 ARN도 만들지 않는다)
  dev_backend_log_group_arns = local.dev_backend_enabled ? [
    for svc in var.dev_backend_log_services :
    "arn:${local.dev_backend_partition}:logs:${local.dev_backend_region}:${local.dev_backend_account_id}:log-group:${module.ecs_service["dev-${svc}"].log_group_name}"
    if contains(keys(local.ecs_service_instances), "dev-${svc}")
  ] : []
}

data "aws_iam_policy_document" "dev_backend" {
  count = local.dev_backend_enabled ? 1 : 0

  # --- 로그 ------------------------------------------------------------------
  statement {
    sid = "ReadDevAppLogs"
    actions = [
      "logs:FilterLogEvents",
      "logs:GetLogEvents",
      "logs:DescribeLogStreams",
      "logs:StartLiveTail",
      "logs:StartQuery",
      "logs:GetLogGroupFields",
    ]
    resources = flatten([for arn in local.dev_backend_log_group_arns : [arn, "${arn}:*"]])
  }

  # 콘솔 목록·Logs Insights 결과 조회 — 리소스 제한이 안 되는 API (로그 내용은 위 문장에서만 허용)
  statement {
    sid = "LogsConsoleList"
    actions = [
      "logs:DescribeLogGroups",
      "logs:GetQueryResults",
      "logs:StopQuery",
      "logs:DescribeQueries",
      "logs:DescribeQueryDefinitions",
      "logs:StopLiveTail",
    ]
    resources = ["*"]
  }

  # --- ECS 상태 조회 -----------------------------------------------------------
  statement {
    sid = "DescribeDevCluster"
    actions = [
      "ecs:DescribeClusters",
      "ecs:DescribeServices",
      "ecs:DescribeTasks",
      "ecs:DescribeContainerInstances",
    ]
    resources = [
      local.dev_backend_cluster_arn,
      "${local.dev_backend_ecs_arn_prefix}:service/${local.dev_backend_cluster_name}/*",
      "${local.dev_backend_ecs_arn_prefix}:task/${local.dev_backend_cluster_name}/*",
      "${local.dev_backend_ecs_arn_prefix}:container-instance/${local.dev_backend_cluster_name}/*",
    ]
  }

  statement {
    sid = "ListInDevCluster"
    actions = [
      "ecs:ListServices",
      "ecs:ListTasks",
      "ecs:ListContainerInstances",
    ]
    resources = ["*"]

    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [local.dev_backend_cluster_arn]
    }
  }

  # 리소스 제한이 안 되는 조회 API + 콘솔 서비스 지표 그래프
  statement {
    sid = "EcsAccountWideRead"
    actions = [
      "ecs:ListClusters",
      "ecs:DescribeTaskDefinition",
      "ecs:ListTaskDefinitions",
      "ecs:ListTaskDefinitionFamilies",
      "cloudwatch:GetMetricData",
      "cloudwatch:ListMetrics",
    ]
    resources = ["*"]
  }

  # --- ECS Exec (dev rest·websocket 컨테이너만) ---------------------------------
  statement {
    sid     = "ExecIntoDevAppContainers"
    actions = ["ecs:ExecuteCommand"]
    resources = [
      local.dev_backend_cluster_arn,
      "${local.dev_backend_ecs_arn_prefix}:task/${local.dev_backend_cluster_name}/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "ecs:container-name"
      values   = var.dev_backend_exec_containers
    }
  }

  # --- SSM 파라미터 (dev backend 값 조회·수정) ---------------------------------
  statement {
    sid = "ReadDevBackendParameters"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
      "ssm:GetParameterHistory",
      "ssm:ListTagsForResource",
    ]
    resources = flatten([for arn in local.dev_backend_ssm_path_arns : [arn, "${arn}/*"]])
  }

  # 덮어쓰기(Overwrite=true)만 허용 → 콘솔 "파라미터 생성"(새 키)은 거부되고, Terraform이 만든 키의 값 수정만 된다
  statement {
    sid       = "OverwriteDevBackendParameters"
    actions   = ["ssm:PutParameter"]
    resources = [for arn in local.dev_backend_ssm_path_arns : "${arn}/*"]

    condition {
      test     = "StringEquals"
      variable = "ssm:Overwrite"
      values   = ["true"]
    }
  }

  # 콘솔 Parameter Store 목록 — 리소스 제한이 안 되는 API (다른 스테이지 파라미터 이름은 보이지만 값은 못 읽는다)
  statement {
    sid       = "SsmConsoleList"
    actions   = ["ssm:DescribeParameters"]
    resources = ["*"]
  }

  # SecureString 암·복호화 (aws/ssm 키). SSM을 통한 호출일 때만
  statement {
    sid       = "EncryptDecryptViaSsm"
    actions   = ["kms:Decrypt", "kms:Encrypt"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${local.dev_backend_region}.amazonaws.com"]
    }
  }

  # --- 재배포 (바뀐 SSM 값 반영) -------------------------------------------------
  statement {
    sid       = "RedeployDevAppServices"
    actions   = ["ecs:UpdateService"]
    resources = local.dev_backend_deploy_service_arns
  }

  # --- 본인 계정 관리 (비밀번호 변경·액세스 키) ----------------------------------
  statement {
    sid = "ManageOwnCredentials"
    actions = [
      "iam:GetUser",
      "iam:ChangePassword",
      "iam:GetLoginProfile",
      "iam:CreateAccessKey",
      "iam:DeleteAccessKey",
      "iam:UpdateAccessKey",
      "iam:ListAccessKeys",
      "iam:GetAccessKeyLastUsed",
    ]
    resources = ["arn:${local.dev_backend_partition}:iam::${local.dev_backend_account_id}:user/$${aws:username}"]
  }

  statement {
    sid       = "ReadPasswordPolicy"
    actions   = ["iam:GetAccountPasswordPolicy"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "dev_backend" {
  count = local.dev_backend_enabled ? 1 : 0

  # description은 IAM에서 수정할 수 없는 값이라 바꾸면 정책이 교체(destroy → create)된다 — 권한 범위는 위 헤더 주석에 적는다
  name        = "${var.project_name}-dev-backend-access"
  description = "BE part: dev app logs, dev ECS read, ECS Exec into dev rest/websocket"
  policy      = data.aws_iam_policy_document.dev_backend[0].json
}

resource "aws_iam_group" "dev_backend" {
  count = local.dev_backend_enabled ? 1 : 0

  name = var.dev_backend_group_name
}

resource "aws_iam_group_policy_attachment" "dev_backend" {
  count = local.dev_backend_enabled ? 1 : 0

  group      = aws_iam_group.dev_backend[0].name
  policy_arn = aws_iam_policy.dev_backend[0].arn
}

resource "aws_iam_user" "dev_backend" {
  for_each = local.dev_backend_enabled ? toset(var.dev_backend_users) : toset([])

  name          = each.value
  force_destroy = true # 사용자가 만든 액세스 키·로그인 프로필이 있어도 삭제되게
}

resource "aws_iam_user_group_membership" "dev_backend" {
  for_each = aws_iam_user.dev_backend

  user   = each.value.name
  groups = [aws_iam_group.dev_backend[0].name]
}

# 콘솔 로그인 — 초기 비밀번호는 첫 로그인 때 변경 강제
resource "aws_iam_user_login_profile" "dev_backend" {
  for_each = { for k, v in aws_iam_user.dev_backend : k => v if var.dev_backend_console_access }

  user                    = each.value.name
  password_reset_required = true

  lifecycle {
    # 사용자가 비밀번호를 바꾼 뒤에도 Terraform이 다시 만들지 않게
    ignore_changes = [password_length, password_reset_required]
  }
}

output "dev_backend_console_signin_url" {
  description = "BE 콘솔 로그인 주소"
  value       = local.dev_backend_enabled ? "https://${local.dev_backend_account_id}.signin.aws.amazon.com/console" : null
}

output "dev_backend_initial_passwords" {
  description = "BE 콘솔 초기 비밀번호 (첫 로그인 때 변경 강제). terraform output -json dev_backend_initial_passwords"
  value       = { for k, v in aws_iam_user_login_profile.dev_backend : k => v.password }
  sensitive   = true
}
