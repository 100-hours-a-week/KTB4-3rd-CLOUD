# SG는 security.tf, IAM Role은 iam.tf에 access 값별로 분리되어 있다.
# 노드 그룹은 프로비저닝 단위이고 AZ별로 하나씩 둔다. 장애가 난 역할과 AZ를 노드 그룹 이름으로 바로 알 수 있다.
# 2a와 2c는 같은 구성이다. system과 stg는 기존 그룹을 교체하지 않으려고 2a 그룹 이름을 그대로 쓴다.
locals {
  spot_instance_types = ["t3.medium", "t3a.medium", "m5.large", "m5a.large", "m6i.large", "c5.large", "c6i.large"]

  app_subnets = {
    a = data.aws_subnet.app.id
    c = aws_subnet.cluster_c.id
  }

  # 역할별 AZ당 구성. realtime: 연결 유지, core: API와 단일 실행 워커, burst: 재시도로 복구되는 무상태 서비스.
  prod_workloads = {
    realtime = { capacity_type = "ON_DEMAND", instance_types = ["t3.medium"], desired = 1, min = 1, max = 2 }
    core     = { capacity_type = "ON_DEMAND", instance_types = ["t3.medium"], desired = 2, min = 2, max = 3 }
    burst    = { capacity_type = "SPOT", instance_types = local.spot_instance_types, desired = 1, min = 1, max = 2 }
  }

  prod_node_groups = merge([
    for workload, spec in local.prod_workloads : {
      for az, subnet_id in local.app_subnets : "${workload}-${az}" => merge(spec, {
        access    = workload
        subnet_id = subnet_id
        labels    = { stage = "prod", workload = workload }
        taints = [
          { key = "stage", value = "prod", effect = "NO_SCHEDULE" },
          { key = "workload", value = workload, effect = "NO_SCHEDULE" },
        ]
      })
    }
  ]...)

  system_group = {
    access         = "system"
    capacity_type  = "ON_DEMAND"
    instance_types = ["t3.medium"]
    desired        = 1
    min            = 1
    max            = 3
    labels         = { role = "system" }
    taints         = [{ key = "CriticalAddonsOnly", value = "true", effect = "NO_SCHEDULE" }]
  }

  # stage=stg 노드는 non-prod 공용이다. dev 파드도 nodeStage 값으로 여기에 올라간다.
  nonprod_group = {
    access         = "stg"
    capacity_type  = "SPOT"
    instance_types = local.spot_instance_types
    desired        = 3
    min            = 0
    max            = 4
    labels         = { stage = "stg" }
    taints         = [{ key = "stage", value = "stg", effect = "NO_SCHEDULE" }]
  }

  node_groups = merge(local.prod_node_groups, {
    system   = merge(local.system_group, { subnet_id = local.app_subnets.a })
    system-c = merge(local.system_group, { subnet_id = local.app_subnets.c })
    stg      = merge(local.nonprod_group, { subnet_id = data.aws_subnet.dev.id })
    stg-c    = merge(local.nonprod_group, { subnet_id = aws_subnet.dev_c.id })
  })
}

resource "aws_launch_template" "node" {
  for_each = local.node_groups

  name_prefix            = "${local.cluster_name}-${each.key}-"
  update_default_version = true

  # 커스텀 SG를 지정하면 클러스터 SG가 자동으로 붙지 않으므로 함께 넣는다.
  vpc_security_group_ids = [
    aws_eks_cluster.this.vpc_config[0].cluster_security_group_id,
    aws_security_group.node[each.value.access].id,
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
  node_role_arn   = aws_iam_role.node[each.value.access].arn
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
