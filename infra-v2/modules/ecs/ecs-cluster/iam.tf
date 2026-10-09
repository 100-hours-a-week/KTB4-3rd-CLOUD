# =============================================================================
# 스테이지 격리의 실제 수단
#   1) Task Execution Role : 이 스테이지 경로의 SSM/Secrets만 읽을 수 있음
#   2) Task Role            : 서비스(rest/websocket/frontend/fastapi)별로 분리, 앱 권한은 이후 서비스 스택에서 추가
#   3) Deploy Role          : 이 클러스터의 서비스만 UpdateService, 이 스테이지 Role만 PassRole
#   4) Exec Operator Policy : 이 클러스터의 태스크에만 ECS Exec
#
# 이미지 빌드·ECR push는 V1 infra/iam.tf의 CI Role(moyeota-github-ci-ecr-push)이 담당하고,
# 여기 Deploy Role은 ECR push 권한 없이 검증된 이미지 digest를 서비스에 반영만 한다.
# =============================================================================

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }

    # confused deputy 방지
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

# -----------------------------------------------------------------------------
# 1) Task Execution Role (스테이지당 1개)
# -----------------------------------------------------------------------------

resource "aws_iam_role" "task_execution" {
  name               = "${local.name}-ecs-task-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
  tags               = local.tags
}

# ECR pull + CloudWatch Logs 전송
resource "aws_iam_role_policy_attachment" "task_execution_managed" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "task_execution_config" {
  statement {
    sid       = "ReadOwnStageParameters"
    actions   = ["ssm:GetParameters"]
    resources = [local.ssm_parameter_arn]
  }

  statement {
    sid       = "ReadOwnStageSecrets"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [local.secret_arn]
  }

  # SecureString / Secrets 복호화. SSM·Secrets Manager를 통한 호출일 때만 허용
  statement {
    sid       = "DecryptViaConfigServices"
    actions   = ["kms:Decrypt"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values = [
        "ssm.${local.region}.amazonaws.com",
        "secretsmanager.${local.region}.amazonaws.com",
      ]
    }
  }
}

resource "aws_iam_role_policy" "task_execution_config" {
  name   = "read-${var.stage}-config"
  role   = aws_iam_role.task_execution.id
  policy = data.aws_iam_policy_document.task_execution_config.json
}

# -----------------------------------------------------------------------------
# 2) Task Role (서비스별 1개)
# -----------------------------------------------------------------------------

resource "aws_iam_role" "task" {
  for_each = toset(var.services)

  name               = "${local.name}-${each.key}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
  tags               = merge(local.tags, { Service = each.key })
}

# ECS Exec 사용 시 태스크 안의 SSM 에이전트가 세션 채널을 열 수 있어야 함
data "aws_iam_policy_document" "task_exec_channel" {
  statement {
    actions = [
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]
    resources = ["*"]
  }

  statement {
    actions   = ["logs:DescribeLogGroups"]
    resources = ["*"]
  }

  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:DescribeLogStreams",
      "logs:PutLogEvents",
    ]
    resources = var.enable_execute_command ? ["${aws_cloudwatch_log_group.exec[0].arn}:*"] : ["*"]
  }
}

resource "aws_iam_role_policy" "task_exec_channel" {
  for_each = var.enable_execute_command ? toset(var.services) : toset([])

  name   = "ecs-exec-channel"
  role   = aws_iam_role.task[each.key].id
  policy = data.aws_iam_policy_document.task_exec_channel.json
}

# -----------------------------------------------------------------------------
# 3) Deploy Role (GitHub Actions OIDC → 이 스테이지 클러스터만 배포)
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "deploy_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.github_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = var.github_oidc_subjects
    }
  }
}

resource "aws_iam_role" "deploy" {
  name                 = "${local.name}-deploy"
  assume_role_policy   = data.aws_iam_policy_document.deploy_assume.json
  max_session_duration = 3600
  tags                 = local.tags
}

data "aws_iam_policy_document" "deploy" {
  # RegisterTaskDefinition은 클러스터 단위로 제한되지 않는다.
  # 등록만으로는 아무것도 실행되지 않으며, 실제 반영(UpdateService)과 Role 주입(PassRole)을 아래에서 막는다.
  statement {
    sid = "TaskDefinition"
    actions = [
      "ecs:RegisterTaskDefinition",
      "ecs:DescribeTaskDefinition",
    ]
    resources = ["*"]
  }

  # 핵심 경계: 이 스테이지 클러스터 안의 서비스만 갱신 가능
  statement {
    sid = "DeployOnlyToOwnCluster"
    actions = [
      "ecs:UpdateService",
      "ecs:DescribeServices",
    ]
    resources = [local.service_arn_pattern]
  }

  statement {
    sid       = "InspectOwnClusterTasks"
    actions   = ["ecs:DescribeTasks"]
    resources = [local.task_arn_pattern]
  }

  statement {
    sid       = "ListOwnClusterTasks"
    actions   = ["ecs:ListTasks"]
    resources = ["*"]

    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [aws_ecs_cluster.this.arn]
    }
  }

  # 다른 스테이지의 Role을 Task Definition에 끼워 넣는 것을 차단
  statement {
    sid     = "PassOnlyOwnStageRoles"
    actions = ["iam:PassRole"]
    resources = concat(
      [aws_iam_role.task_execution.arn],
      [for r in aws_iam_role.task : r.arn],
    )

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "deploy" {
  name   = "deploy-${var.stage}-cluster"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy.json
}

# -----------------------------------------------------------------------------
# 4) ECS Exec 운영자 정책 (사람/SSO Permission Set에 붙여서 사용)
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "exec_operator" {
  count = var.enable_execute_command ? 1 : 0

  statement {
    sid     = "ExecIntoOwnClusterTasks"
    actions = ["ecs:ExecuteCommand"]
    resources = [
      aws_ecs_cluster.this.arn,
      local.task_arn_pattern,
    ]
  }

  statement {
    sid       = "FindTasks"
    actions   = ["ecs:DescribeTasks"]
    resources = [local.task_arn_pattern]
  }

  statement {
    sid       = "ListTasks"
    actions   = ["ecs:ListTasks"]
    resources = ["*"]

    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [aws_ecs_cluster.this.arn]
    }
  }
}

resource "aws_iam_policy" "exec_operator" {
  count = var.enable_execute_command ? 1 : 0

  name        = "${local.name}-ecs-exec-operator"
  description = "ECS Exec into tasks of ${local.name} only"
  policy      = data.aws_iam_policy_document.exec_operator[0].json
  tags        = local.tags
}
