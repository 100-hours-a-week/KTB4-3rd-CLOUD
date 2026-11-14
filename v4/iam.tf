# v4 ECS IAM. V2 modules/ecs/ecs-cluster의 역할 분리를 따르되, prod 스테이지 하나만 둔다.
#   1) Task Execution Role : V2 prod 앱 시크릿 경로와 v4 broker·backend 경로의 SSM만 읽는다
#   2) Task Role           : 서비스별. rest만 이미지 버킷 권한을 갖는다
#   3) 컨테이너 인스턴스 Role : 에이전트 액션을 v4 클러스터로만 제한한다
#   4) Deploy Role         : GitHub Actions OIDC. v4 클러스터 서비스만 UpdateService, v4 Role만 PassRole
# 이미지 빌드·ECR push는 기존 CI Role이 맡는다. 여기 Deploy Role은 검증된 digest를 반영만 한다.

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

# ---------------------------------------------------------------------------
# 1) Task Execution Role
# ---------------------------------------------------------------------------

resource "aws_iam_role" "task_execution" {
  name               = "${local.name_prefix}-ecs-task-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

# ECR pull + CloudWatch Logs 전송
resource "aws_iam_role_policy_attachment" "task_execution_managed" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "task_execution_config" {
  statement {
    sid       = "ReadAppParameters"
    actions   = ["ssm:GetParameters"]
    resources = concat([local.v2_ssm_arn_pattern], local.v4_ssm_arn_patterns)
  }

  # SecureString 복호화. SSM을 통한 호출일 때만 허용
  statement {
    sid       = "DecryptViaSsm"
    actions   = ["kms:Decrypt"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${local.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "task_execution_config" {
  name   = "read-app-config"
  role   = aws_iam_role.task_execution.id
  policy = data.aws_iam_policy_document.task_execution_config.json
}

# ---------------------------------------------------------------------------
# 2) Task Role (서비스별)
# ---------------------------------------------------------------------------

resource "aws_iam_role" "task" {
  for_each = local.services

  name               = "${local.name_prefix}-${each.key}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json

  tags = {
    Service = each.key
  }
}

# ECS Exec: 태스크 안의 SSM 에이전트가 세션 채널을 열고 Exec 로그를 남긴다
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
    resources = ["arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:${local.exec_log_group_name}:*"]
  }
}

resource "aws_iam_role_policy" "task_exec_channel" {
  for_each = local.services

  name   = "ecs-exec-channel"
  role   = aws_iam_role.task[each.key].id
  policy = data.aws_iam_policy_document.task_exec_channel.json
}

# rest: 이미지 presigned URL 발급·확인·복사 (V2 images.tf와 같은 범위)
data "aws_iam_policy_document" "rest_images" {
  statement {
    sid     = "ImageObjects"
    actions = ["s3:GetObject", "s3:PutObject"]
    resources = [
      for prefix in var.image_object_prefixes : "${data.aws_s3_bucket.images.arn}/${prefix}/*"
    ]
  }

  statement {
    sid       = "ImageBucketList"
    actions   = ["s3:ListBucket"]
    resources = [data.aws_s3_bucket.images.arn]
  }
}

resource "aws_iam_role_policy" "rest_images" {
  name   = "rw-prod-images"
  role   = aws_iam_role.task["rest"].id
  policy = data.aws_iam_policy_document.rest_images.json
}

# ---------------------------------------------------------------------------
# 3) 컨테이너 인스턴스 Role
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "container_instance" {
  name               = "${local.name_prefix}-ecs-instance"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

data "aws_iam_policy_document" "container_instance_agent" {
  # 클러스터 ARN으로 제한할 수 있는 액션은 v4 클러스터로만
  statement {
    sid = "AgentActionsOnOwnCluster"
    actions = [
      "ecs:RegisterContainerInstance",
      "ecs:DeregisterContainerInstance",
      "ecs:SubmitContainerStateChange",
      "ecs:SubmitTaskStateChange",
      "ecs:SubmitAttachmentStateChanges",
    ]
    resources = [local.cluster_arn]
  }

  statement {
    sid = "AgentActionsWithoutResourceScope"
    actions = [
      "ecs:DiscoverPollEndpoint",
      "ecs:Poll",
      "ecs:StartTelemetrySession",
      "ecs:UpdateContainerInstancesState",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "TagOwnContainerInstancesOnRegister"
    actions   = ["ecs:TagResource"]
    resources = [local.container_instance_arn_pattern]

    condition {
      test     = "StringEquals"
      variable = "ecs:CreateAction"
      values   = ["RegisterContainerInstance"]
    }
  }
}

resource "aws_iam_role_policy" "container_instance_agent" {
  name   = "ecs-agent-v4-cluster-only"
  role   = aws_iam_role.container_instance.id
  policy = data.aws_iam_policy_document.container_instance_agent.json
}

# 운영 접근은 SSH 대신 SSM Session Manager
resource "aws_iam_role_policy_attachment" "container_instance_ssm" {
  role       = aws_iam_role.container_instance.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "container_instance" {
  name = "${local.name_prefix}-ecs-instance"
  role = aws_iam_role.container_instance.name
}

# ---------------------------------------------------------------------------
# 4) Deploy Role (GitHub Actions OIDC)
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "deploy_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # 불변 sub 형식: repo:<org>@<org_id>/<repo>@<repo_id>:environment:<env>
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        for repo, id in var.github_repository_ids :
        "repo:${var.github_org}@${var.github_org_id}/${repo}@${id}:environment:${var.github_deploy_environment}"
      ]
    }
  }
}

resource "aws_iam_role" "deploy" {
  name                 = "${local.name_prefix}-deploy"
  assume_role_policy   = data.aws_iam_policy_document.deploy_assume.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "deploy" {
  # RegisterTaskDefinition은 클러스터 단위로 제한되지 않는다. 실제 반영(UpdateService)과 PassRole을 아래에서 막는다.
  statement {
    sid = "TaskDefinition"
    actions = [
      "ecs:RegisterTaskDefinition",
      "ecs:DescribeTaskDefinition",
    ]
    resources = ["*"]
  }

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
      values   = [local.cluster_arn]
    }
  }

  statement {
    sid     = "PassOnlyOwnRoles"
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
  name   = "deploy-v4-cluster"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy.json
}
