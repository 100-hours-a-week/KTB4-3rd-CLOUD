# 노드 그룹은 권한 경계다. SG는 security.tf, IAM Role은 iam.tf에 그룹별로 분리되어 있다.
locals {
  node_groups = {
    system = {
      subnet_id      = data.aws_subnet.app.id
      capacity_type  = "ON_DEMAND"
      instance_types = ["t3.medium"]
      desired        = 2
      min            = 2
      max            = 3
      labels         = { role = "system" }
      taints         = [{ key = "CriticalAddonsOnly", value = "true", effect = "NO_SCHEDULE" }]
    }
    prod = {
      subnet_id      = data.aws_subnet.app.id
      capacity_type  = "ON_DEMAND"
      instance_types = ["t3.medium"]
      desired        = var.prod_node_desired
      min            = var.prod_node_desired
      max            = 5
      labels         = { stage = "prod" }
      taints         = [{ key = "stage", value = "prod", effect = "NO_SCHEDULE" }]
    }
    # Spot 쿼터는 On-Demand와 별도다. 필요 메모리 5,632MiB라 2대로는 롤링 여유가 없어 3대로 시작한다.
    stg = {
      subnet_id      = data.aws_subnet.dev.id
      capacity_type  = "SPOT"
      instance_types = ["t3.medium", "t3a.medium", "m5.large", "m5a.large", "m6i.large", "c5.large", "c6i.large"]
      desired        = 3
      min            = 0
      max            = 4
      labels         = { stage = "stg" }
      taints         = [{ key = "stage", value = "stg", effect = "NO_SCHEDULE" }]
    }
  }
}

resource "aws_launch_template" "node" {
  for_each = local.node_groups

  name_prefix            = "${local.cluster_name}-${each.key}-"
  update_default_version = true

  # 커스텀 SG를 지정하면 클러스터 SG가 자동으로 붙지 않으므로 함께 넣는다.
  vpc_security_group_ids = [
    aws_eks_cluster.this.vpc_config[0].cluster_security_group_id,
    aws_security_group.node[each.key].id,
  ]

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 30
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  # V2와 같다. hop limit 1이라 일반 파드는 IMDS에 닿지 못한다.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${local.cluster_name}-${each.key}"
    }
  }
}

resource "aws_eks_node_group" "this" {
  for_each = local.node_groups

  cluster_name    = aws_eks_cluster.this.name
  node_group_name = each.key
  node_role_arn   = aws_iam_role.node[each.key].arn
  subnet_ids      = [each.value.subnet_id]
  capacity_type   = each.value.capacity_type
  instance_types  = each.value.instance_types
  ami_type        = "AL2023_x86_64_STANDARD"
  labels          = each.value.labels

  scaling_config {
    desired_size = each.value.desired
    min_size     = each.value.min
    max_size     = each.value.max
  }

  update_config {
    max_unavailable = 1
  }

  launch_template {
    id      = aws_launch_template.node[each.key].id
    version = aws_launch_template.node[each.key].latest_version
  }

  dynamic "taint" {
    for_each = each.value.taints
    content {
      key    = taint.value.key
      value  = taint.value.value
      effect = taint.value.effect
    }
  }

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }

  depends_on = [
    aws_iam_role_policy_attachment.node,
    aws_eks_addon.vpc_cni,
    aws_eks_addon.kube_proxy,
    aws_eks_addon.pod_identity,
  ]
}

# CoreDNS는 스케줄될 노드가 있어야 ACTIVE가 된다.
resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.this]
}
