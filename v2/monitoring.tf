# =============================================================================
# 중앙 모니터링 — PLG(Prometheus · Loki · Grafana) + Grafana Alloy
#   설계 근거: wiki「V2 중앙 집중식 모니터링 시스템 설계」
#
#   - 모니터링 호스트는 ECS 클러스터 밖 전용 EC2 1대 (감시 대상과 다른 장애 도메인)
#   - 메트릭 : Prometheus가 태스크의 /actuator/prometheus(관리 포트)·/metrics를 pull
#   - 로그   : 각 ECS 컨테이너 인스턴스의 Alloy(DAEMON, host 네트워크)가 Loki(3100)로 push
#   - var.monitoring_enabled = false면 아무것도 만들지 않는다
# =============================================================================

locals {
  monitoring_enabled = var.monitoring_enabled

  # 모니터링 호스트 서브넷: ops-a가 있으면 ops, 없으면 app (security group만 분리)
  monitoring_subnet_key = var.subnet_cidrs.ops == null ? "app" : "ops"

  monitoring_loki_port = 3100

  # 서비스 → 메트릭 엔드포인트. frontend(Next.js)는 메트릭을 노출하지 않으므로 수집하지 않는다.
  #   rest·websocket : Spring Actuator 관리 포트 (ALB 헬스체크와 같은 8090)
  #   fastapi        : 앱 포트의 /metrics
  monitoring_metrics_endpoints = {
    rest      = { port = var.spring_management_port, metrics_path = "/actuator/prometheus" }
    websocket = { port = var.spring_management_port, metrics_path = "/actuator/prometheus" }
    fastapi   = { port = var.fastapi_port, metrics_path = "/metrics" }
  }

  # "prod-rest" 같은 ECS 서비스 인스턴스 중 메트릭을 수집할 대상
  monitoring_scrape_instances = local.monitoring_enabled ? {
    for k, s in local.ecs_service_instances : k => merge(local.monitoring_metrics_endpoints[s.service], {
      stage   = s.stage
      service = s.service
    }) if contains(keys(local.monitoring_metrics_endpoints), s.service)
  } : {}

  # 로그를 보낼 ECS 스테이지 (Alloy DAEMON이 뜨는 클러스터).
  # ecs_stages는 스테이지마다 속성 형태가 다른 object라 조건식으로 {}와 묶을 수 없어 이름 집합으로 둔다.
  monitoring_log_stages = toset(local.monitoring_enabled ? keys(local.ecs_stages) : [])
}

# -----------------------------------------------------------------------------
# 모니터링 호스트 SG
#   인바운드는 수집·조회에 필요한 포트만 규칙 리소스로 연다
#     3100 (Loki push) ← 각 스테이지 ECS 컨테이너 인스턴스 SG (Alloy가 host 네트워크라 인스턴스 SG에서 나간다)
#     3000 (Grafana)   ← Non-Prod ALB SG (Grafana 접근 이슈에서 추가)
#   아웃바운드는 태스크 scrape(8090·8000), S3·CloudWatch·SSM API, Discord 웹훅, 이미지 pull
# -----------------------------------------------------------------------------

resource "aws_security_group" "monitoring" {
  count = local.monitoring_enabled ? 1 : 0

  name                   = "${var.project_name}-monitoring"
  description            = "V2 central monitoring host (Prometheus, Loki, Grafana)"
  vpc_id                 = data.aws_vpc.shared.id
  revoke_rules_on_delete = true

  tags = {
    Name = "${var.project_name}-monitoring-sg"
    Tier = "private-ops"
  }
}

resource "aws_vpc_security_group_egress_rule" "monitoring_all" {
  count = local.monitoring_enabled ? 1 : 0

  security_group_id = aws_security_group.monitoring[0].id
  description       = "Scrape tasks, AWS APIs, Discord webhooks and image pulls"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_ingress_rule" "monitoring_loki_from_ecs_instances" {
  for_each = local.monitoring_log_stages

  security_group_id            = aws_security_group.monitoring[0].id
  description                  = "Loki push from ${each.key} ECS container instances (Alloy)"
  referenced_security_group_id = module.ecs_cluster[each.key].instance_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = local.monitoring_loki_port
  to_port                      = local.monitoring_loki_port
}

# 태스크 SG ← 모니터링 SG : 메트릭 포트만 연다 (앱 트래픽 포트와 분리)
resource "aws_vpc_security_group_ingress_rule" "task_metrics_from_monitoring" {
  for_each = local.monitoring_scrape_instances

  security_group_id            = module.ecs_service[each.key].task_security_group_id
  description                  = "Prometheus scrape ${each.value.metrics_path} from monitoring host"
  referenced_security_group_id = aws_security_group.monitoring[0].id
  ip_protocol                  = "tcp"
  from_port                    = each.value.port
  to_port                      = each.value.port
}

# -----------------------------------------------------------------------------
# 모니터링 모듈 (저장소 · IAM · 호스트 · 설정)
# -----------------------------------------------------------------------------

module "monitoring" {
  source = "./modules/monitoring"
  count  = local.monitoring_enabled ? 1 : 0

  project_name       = var.project_name
  config_path_prefix = var.config_path_prefix

  tags = { Component = "monitoring" }
}
