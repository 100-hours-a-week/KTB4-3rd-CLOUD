# v4 보안 그룹과, V2 SG에 추가하는 인바운드 규칙.
#   - 컨테이너 인스턴스 SG : 인바운드 없음. 앱 트래픽은 태스크 ENI(awsvpc)의 태스크 SG로 받는다. Alloy(host 모드, 로그 수집)는 이 SG로 나간다.
#   - 지표는 앱(rest, websocket, fastapi)이 OTLP로 모니터링 EC2에 직접 보낸다 (V2 dev·stg와 같은 방식).
#   - 태스크 SG            : 서비스별 1개. ALB와 같은 v4 내부 서비스에서만 받는다.
#   - 데이터 호스트 SG     : Kafka·MongoDB·Redis. 필요한 서비스의 태스크 SG에서만 받는다.
# V2 SG에는 규칙을 "추가"만 한다. 기존 ECS·EKS 규칙은 그대로 두어 전환 중 양쪽이 함께 접속한다.

locals {
  egress_all = {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # ALB → 태스크 (트래픽 포트와 관리 포트)
  alb_to_task_rules = merge([
    for svc, spec in local.services : {
      for port in compact([tostring(spec.port), spec.management_port == null ? "" : tostring(spec.management_port)]) :
      "${svc}-${port}" => { service = svc, port = tonumber(port) }
    } if spec.alb
  ]...)

  # OTLP 지표를 보내는 서비스 (frontend는 지표를 내보내지 않는다)
  otlp_services = toset(["rest", "websocket", "fastapi"])

  # 데이터 호스트 포트 → 접속하는 서비스
  # websocket은 Kafka를 쓰지 않는다. MONGODB_URI는 BE 공통 값이라 websocket도 받으며, actuator health에 Mongo가 포함되므로 허용한다.
  data_host_ports = {
    kafka = { port = 9092, services = ["rest", "fastapi"] }
    mongo = { port = 27017, services = ["rest", "websocket"] }
    redis = { port = 6379, services = ["rest", "websocket"] }
  }

  data_host_rules = merge([
    for name, spec in local.data_host_ports : {
      for svc in spec.services : "${name}-${svc}" => { port = spec.port, service = svc }
    }
  ]...)
}

resource "aws_security_group" "instance" {
  name                   = "${local.name_prefix}-ecs-instance"
  description            = "v4 ECS container instances (no inbound)"
  vpc_id                 = data.aws_vpc.shared.id
  revoke_rules_on_delete = true

  egress {
    description = "ECR, AWS APIs, monitoring"
    from_port   = local.egress_all.from_port
    to_port     = local.egress_all.to_port
    protocol    = local.egress_all.protocol
    cidr_blocks = local.egress_all.cidr_blocks
  }

  tags = {
    Name = "${local.name_prefix}-ecs-instance-sg"
  }
}

resource "aws_security_group" "task" {
  for_each = local.services

  name                   = "${local.name_prefix}-${each.key}-task"
  description            = "v4 ${each.key} tasks"
  vpc_id                 = data.aws_vpc.shared.id
  revoke_rules_on_delete = true

  egress {
    description = "Data stores, AWS APIs, external APIs"
    from_port   = local.egress_all.from_port
    to_port     = local.egress_all.to_port
    protocol    = local.egress_all.protocol
    cidr_blocks = local.egress_all.cidr_blocks
  }

  tags = {
    Name    = "${local.name_prefix}-${each.key}-task-sg"
    Service = each.key
  }
}

resource "aws_vpc_security_group_ingress_rule" "task_from_alb" {
  for_each = local.alb_to_task_rules

  security_group_id            = aws_security_group.task[each.value.service].id
  description                  = "ALB to ${each.value.service} on ${each.value.port}"
  referenced_security_group_id = data.aws_security_group.v2["alb"].id
  ip_protocol                  = "tcp"
  from_port                    = each.value.port
  to_port                      = each.value.port
}

# rest → fastapi (Service Connect, http://fastapi:8000)
resource "aws_vpc_security_group_ingress_rule" "fastapi_from_rest" {
  security_group_id            = aws_security_group.task["fastapi"].id
  description                  = "rest to fastapi"
  referenced_security_group_id = aws_security_group.task["rest"].id
  ip_protocol                  = "tcp"
  from_port                    = local.services.fastapi.port
  to_port                      = local.services.fastapi.port
}

resource "aws_security_group" "data_host" {
  name                   = "${local.name_prefix}-data-host"
  description            = "v4 data host (Kafka, MongoDB, Redis)"
  vpc_id                 = data.aws_vpc.shared.id
  revoke_rules_on_delete = true

  egress {
    description = "ECR, SSM, package repositories"
    from_port   = local.egress_all.from_port
    to_port     = local.egress_all.to_port
    protocol    = local.egress_all.protocol
    cidr_blocks = local.egress_all.cidr_blocks
  }

  tags = {
    Name = "${local.name_prefix}-data-host-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "data_host_from_tasks" {
  for_each = local.data_host_rules

  security_group_id            = aws_security_group.data_host.id
  description                  = "${each.value.service} to data host ${each.key}"
  referenced_security_group_id = aws_security_group.task[each.value.service].id
  ip_protocol                  = "tcp"
  from_port                    = each.value.port
  to_port                      = each.value.port
}

# ---------------------------------------------------------------------------
# V2 SG에 추가하는 규칙
# ---------------------------------------------------------------------------

# rest·websocket → V2 prod RDS
resource "aws_vpc_security_group_ingress_rule" "v2_rds_from_tasks" {
  for_each = toset(["rest", "websocket"])

  security_group_id            = data.aws_security_group.v2["rds"].id
  description                  = "v4 ${each.key} tasks"
  referenced_security_group_id = aws_security_group.task[each.key].id
  ip_protocol                  = "tcp"
  from_port                    = data.aws_db_instance.prod.port
  to_port                      = data.aws_db_instance.prod.port
}

# Alloy(인스턴스 SG) → V2 모니터링 EC2 Loki 3100
resource "aws_vpc_security_group_ingress_rule" "v2_monitoring_loki_from_instances" {
  security_group_id            = data.aws_security_group.v2["monitoring"].id
  description                  = "v4 ECS instances (Alloy logs)"
  referenced_security_group_id = aws_security_group.instance.id
  ip_protocol                  = "tcp"
  from_port                    = local.monitoring_loki_port
  to_port                      = local.monitoring_loki_port
}

# 앱 태스크 → V2 모니터링 EC2 OTLP 9090 (Prometheus OTLP receiver)
resource "aws_vpc_security_group_ingress_rule" "v2_monitoring_otlp_from_tasks" {
  for_each = local.otlp_services

  security_group_id            = data.aws_security_group.v2["monitoring"].id
  description                  = "v4 ${each.key} tasks (OTLP metrics)"
  referenced_security_group_id = aws_security_group.task[each.key].id
  ip_protocol                  = "tcp"
  from_port                    = local.monitoring_otlp_port
  to_port                      = local.monitoring_otlp_port
}
