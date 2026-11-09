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
