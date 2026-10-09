# =============================================================================
# EC2 컨테이너 인스턴스 공통 리소스 (스테이지당 1개, 같은 스테이지 ASG가 공유)
#   설계 근거: issues/ecs-iam-network.md 8.2 · 8.3, issues/ecs-asg-by-cluster-service.md 4.4
#
#   - 인스턴스 Role : 관리형 AmazonEC2ContainerServiceforEC2Role 대신
#                     클러스터 ARN으로 제한 가능한 agent 액션을 "자기 클러스터"로 묶은 커스텀 정책 [D12]
#                     → dev Launch Template에 ECS_CLUSTER=moyeota-v2-prod를 잘못 넣어도 등록이 AccessDenied
#   - 인스턴스 SG   : 인바운드 없음 (awsvpc → 앱 트래픽은 태스크 ENI의 태스크 SG로 받는다, 운영 접근은 SSM)
#   - ECR pull · CloudWatch Logs 권한은 Task Execution Role이 갖는다 (인스턴스 Role에 두지 않음)
# =============================================================================

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
  name               = "${local.name}-ecs-instance"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = local.tags
}

data "aws_iam_policy_document" "container_instance_agent" {
  # 클러스터 ARN으로 제한이 문서화된 액션 → 자기 클러스터로만 [D12]
  statement {
    sid = "AgentActionsOnOwnCluster"
    actions = [
      "ecs:RegisterContainerInstance",
      "ecs:DeregisterContainerInstance",
      "ecs:SubmitContainerStateChange",
      "ecs:SubmitTaskStateChange",
      "ecs:SubmitAttachmentStateChanges", # awsvpc 태스크 ENI attach 상태 보고
    ]
    resources = [aws_ecs_cluster.this.arn]
  }

  # 리소스 타입이 명시되지 않은 액션 → "*" [D13]. 적용 후 Policy Simulator로 확정한다.
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

  # 계정의 tagResourceAuthorization 설정이 켜져 있을 때, 태그를 붙여 등록하는 경우에만 필요
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
  name   = "ecs-agent-${var.stage}-cluster-only"
  role   = aws_iam_role.container_instance.id
  policy = data.aws_iam_policy_document.container_instance_agent.json
}

# 운영 접근은 SSH 대신 SSM Session Manager
resource "aws_iam_role_policy_attachment" "container_instance_ssm" {
  role       = aws_iam_role.container_instance.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "container_instance" {
  name = "${local.name}-ecs-instance"
  role = aws_iam_role.container_instance.name
  tags = local.tags
}

# -----------------------------------------------------------------------------
# 인스턴스 보안 그룹: <stage>-ecs-instance-sg
#   인바운드 없음. ALB → 태스크 트래픽은 ecs-service 모듈의 태스크 SG가 받는다.
# -----------------------------------------------------------------------------

resource "aws_security_group" "container_instance" {
  name                   = "${local.name}-ecs-instance"
  description            = "ECS container instances of ${local.name} (no inbound, SSM only)"
  vpc_id                 = var.vpc_id
  revoke_rules_on_delete = true

  tags = merge(local.tags, {
    Name = "${local.name}-ecs-instance-sg"
  })
}

resource "aws_vpc_security_group_egress_rule" "container_instance_all" {
  security_group_id = aws_security_group.container_instance.id
  description       = "ECS/ECR/SSM endpoints and external APIs through NAT"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
