# 클러스터 생성 전에 만들어야 보존 기간이 적용된다.
resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${local.cluster_name}/cluster"
  retention_in_days = 30
}

resource "aws_eks_cluster" "this" {
  name     = local.cluster_name
  version  = var.cluster_version
  role_arn = aws_iam_role.cluster.arn

  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  upgrade_policy {
    support_type = "STANDARD"
  }

  vpc_config {
    subnet_ids              = [data.aws_subnet.app.id, data.aws_subnet.dev.id, aws_subnet.cluster_c.id]
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = var.api_public_cidrs
  }

  depends_on = [
    aws_iam_role_policy_attachment.cluster,
    aws_cloudwatch_log_group.cluster,
  ]
}

# 노드 없이 설치 가능한 애드온
resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  # NetworkPolicy 엔진만 켠다. strict 모드는 전환 후 적용한다 (Notion 4.1 1단계 임시 예외).
  configuration_values = jsonencode({ enableNetworkPolicy = "true" })
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_eks_addon" "pod_identity" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "eks-pod-identity-agent"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}
