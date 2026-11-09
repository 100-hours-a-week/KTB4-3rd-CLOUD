# 클러스터 Role
data "aws_iam_policy_document" "cluster_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${local.cluster_name}-cluster"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume.json
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# 노드 Role. 노드 그룹마다 분리한다 (Notion 4.1 T5, prod/non-prod 분리).
locals {
  node_managed_policies = [
    "AmazonEKSWorkerNodePolicy",
    "AmazonEC2ContainerRegistryPullOnly",
    "AmazonEKS_CNI_Policy",
    "AmazonSSMManagedInstanceCore",
  ]

  node_policy_attachments = merge([
    for group in local.node_group_names : {
      for policy in local.node_managed_policies : "${group}-${policy}" => { group = group, policy = policy }
    }
  ]...)
}

data "aws_iam_policy_document" "node_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  for_each = local.node_group_names

  name               = "${local.cluster_name}-${each.key}-node"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = local.node_policy_attachments

  role       = aws_iam_role.node[each.value.group].name
  policy_arn = "arn:aws:iam::aws:policy/${each.value.policy}"
}

# EKS Pod Identity Role. V2 태스크 Role의 앱 권한만 옮긴다. 연결은 pod_identity.tf에 있다.
# websocket·frontend·fastapi 태스크 Role에는 ECS Exec 권한(및 기한부 로그 조회)뿐이어서 Role을 만들지 않는다.
data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "pod_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "rest_images" {
  for_each = var.stages

  statement {
    sid     = "ImageObjectsReadWrite"
    actions = ["s3:PutObject", "s3:GetObject"]
    resources = [
      for prefix in ["transfer", "tmp", "profile", "meter"] :
      "arn:aws:s3:::${each.value.images_bucket}/${prefix}/*"
    ]
  }

  statement {
    sid       = "ImageBucketList"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${each.value.images_bucket}"]
  }
}

resource "aws_iam_role" "rest" {
  for_each = var.stages

  name               = "${local.cluster_name}-${each.key}-rest"
  assume_role_policy = data.aws_iam_policy_document.pod_assume.json
}

resource "aws_iam_role_policy" "rest_images" {
  for_each = var.stages

  name   = "rw-${each.key}-images"
  role   = aws_iam_role.rest[each.key].id
  policy = data.aws_iam_policy_document.rest_images[each.key].json
}

# External Secrets: 스테이지 SSM 경로 읽기
data "aws_iam_policy_document" "external_secrets" {
  statement {
    sid     = "ReadStageParameters"
    actions = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = [
      for stage in keys(var.stages) :
      "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/moyeota/v2/${stage}/*"
    ]
  }

  statement {
    sid       = "DescribeParameters"
    actions   = ["ssm:DescribeParameters"]
    resources = ["*"]
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

resource "aws_iam_role" "external_secrets" {
  name               = "${local.cluster_name}-external-secrets"
  assume_role_policy = data.aws_iam_policy_document.pod_assume.json
}

resource "aws_iam_role_policy" "external_secrets" {
  name   = "read-stage-ssm"
  role   = aws_iam_role.external_secrets.id
  policy = data.aws_iam_policy_document.external_secrets.json
}

# AWS Load Balancer Controller: 공식 정책 (v3.6.2 docs/install/iam_policy.json)
resource "aws_iam_policy" "lb_controller" {
  name   = "${local.cluster_name}-lb-controller"
  policy = file("${path.module}/policies/aws-load-balancer-controller.json")
}

resource "aws_iam_role" "lb_controller" {
  name               = "${local.cluster_name}-lb-controller"
  assume_role_policy = data.aws_iam_policy_document.pod_assume.json
}

resource "aws_iam_role_policy_attachment" "lb_controller" {
  role       = aws_iam_role.lb_controller.name
  policy_arn = aws_iam_policy.lb_controller.arn
}
