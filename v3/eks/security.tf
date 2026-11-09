# V2 SG에 EKS 노드 SG 인바운드를 "추가"만 한다. ECS 태스크 규칙은 그대로 두어 전환 중 양쪽이 함께 접속한다.
locals {
  # 키 → 대상 SG 이름, 포트, 허용할 노드 그룹. 목록은 V2 태스크 SG를 참조하는 실제 규칙에서 옮겼다.
  # prod-otlp는 예외다. V2 prod는 Prometheus가 태스크를 스크랩하지만, EKS는 Alloy가 9090으로 push한다.
  target_sg_rules = {
    prod-rds    = { sg = "moyeota-v2-prod-rds", port = 3306, node = "prod" }
    prod-redis  = { sg = "moyeota-v2-prod-redis", port = 6379, node = "prod" }
    prod-loki   = { sg = "moyeota-v2-monitoring", port = 3100, node = "prod" }
    prod-otlp   = { sg = "moyeota-v2-monitoring", port = 9090, node = "prod" }
    stg-rds     = { sg = "moyeota-v2-stg-rds", port = 3306, node = "stg" }
    stg-redis   = { sg = "moyeota-v2-stg-redis", port = 6379, node = "stg" }
    stg-msk     = { sg = "moyeota-v2-stg-msk", port = 9092, node = "stg" }
    stg-qdrant  = { sg = "moyeota-v2-qdrant-nonprod", port = 6333, node = "stg" }
    stg-loki    = { sg = "moyeota-v2-monitoring", port = 3100, node = "stg" }
    stg-otlp    = { sg = "moyeota-v2-monitoring", port = 9090, node = "stg" }
    system-loki = { sg = "moyeota-v2-monitoring", port = 3100, node = "system" }
    # kube-state-metrics를 스크랩한 system 노드 Alloy가 지표를 보내는 경로다.
    system-otlp = { sg = "moyeota-v2-monitoring", port = 9090, node = "system" }
  }

  alb_ingress_ports = [8080, 8090, 3000]

  alb_by_node = {
    prod = "moyeota-v2-alb"
    stg  = "moyeota-v2-nonprod-alb"
  }

  alb_ingress_rules = merge([
    for node, alb_sg in local.alb_by_node : {
      for port in local.alb_ingress_ports : "${node}-${port}" => { node = node, alb_sg = alb_sg, port = port }
    }
  ]...)

  referenced_sg_names = toset(concat(
    [for rule in values(local.target_sg_rules) : rule.sg],
    values(local.alb_by_node),
  ))
}

data "aws_security_group" "v2" {
  for_each = local.referenced_sg_names

  name   = each.key
  vpc_id = data.aws_vpc.shared.id
}

# VPC CNI 기본 모드에서 파드는 노드 기본 ENI의 SG를 쓰므로, 저장소 인바운드는 이 SG로 허용한다.
resource "aws_security_group" "node" {
  for_each = local.node_group_names

  name                   = "${local.cluster_name}-${each.key}-node"
  description            = "EKS ${each.key} nodes and pods"
  vpc_id                 = data.aws_vpc.shared.id
  revoke_rules_on_delete = true

  egress {
    description = "Image registries, AWS APIs and data stores"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.cluster_name}-${each.key}-node-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "v2_from_nodes" {
  for_each = local.target_sg_rules

  security_group_id            = data.aws_security_group.v2[each.value.sg].id
  description                  = "EKS ${each.value.node} nodes (${each.key})"
  referenced_security_group_id = aws_security_group.node[each.value.node].id
  ip_protocol                  = "tcp"
  from_port                    = each.value.port
  to_port                      = each.value.port
}

resource "aws_vpc_security_group_ingress_rule" "nodes_from_alb" {
  for_each = local.alb_ingress_rules

  security_group_id            = aws_security_group.node[each.value.node].id
  description                  = "ALB to pods on ${each.value.port}"
  referenced_security_group_id = data.aws_security_group.v2[each.value.alb_sg].id
  ip_protocol                  = "tcp"
  from_port                    = each.value.port
  to_port                      = each.value.port
}
