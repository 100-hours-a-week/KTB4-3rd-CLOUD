# =============================================================================
# 데이터 계층 경로 (Redis Pub/Sub · MySQL)
#   stg : ElastiCache for Redis (data 서브넷, 단일 노드). QA·스케줄링 테스트 때만 띄우고 내린다
#         → elasticache_redis_stages = ["stg"] 일 때만 생성
#   dev : dev EC2의 compose MySQL·Redis 컨테이너를 그대로 쓴다
#         → dev EC2 SG에 dev rest·websocket 태스크 SG 인바운드(dev_data_ports)만 연다
#   공통 : 데이터 계층 SG는 rest·websocket 태스크 SG만 허용한다 (frontend·fastapi는 경로 없음)
#
#   앱 연결 값 : Spring Boot 기본 바인딩 SPRING_DATA_REDIS_HOST / SPRING_DATA_REDIS_PORT
#               (SSM 키 추가는 ssm.tf backend 그룹에서 별도로 한다)
#               stg → output redis_endpoints.stg / dev → output private_ips.dev
# =============================================================================

locals {
  redis_stages = toset([for s in var.elasticache_redis_stages : s if contains(keys(local.ecs_stages), s)])

  # 데이터 계층에 붙는 서비스
  data_client_services = ["rest", "websocket"]

  # "stg-rest" → { stage, sg_id }. 이미지가 없어 만들어지지 않은 서비스는 빠진다.
  data_client_task_sgs = {
    for k, s in local.ecs_service_instances : k => {
      stage = s.stage
      sg_id = module.ecs_service[k].task_security_group_id
    }
    if contains(local.data_client_services, s.service)
  }
}

# -----------------------------------------------------------------------------
# stg ElastiCache for Redis
#   - 단일 노드·자동 장애 조치 없음: Pub/Sub 경로와 ECS 스케줄링 검증이 목적이고 데이터 보존이 필요 없다
#   - 전송 구간 암호화는 기본 off: BE에 spring.data.redis.ssl 설정이 아직 없다
#     (켜려면 redis_transit_encryption_enabled = true + SPRING_DATA_REDIS_SSL_ENABLED=true)
# -----------------------------------------------------------------------------

resource "aws_elasticache_subnet_group" "redis" {
  count = length(local.redis_stages) > 0 ? 1 : 0

  name        = "${var.project_name}-data"
  description = "V2 data subnets for ElastiCache"
  subnet_ids  = [aws_subnet.v2["data_a"].id, aws_subnet.v2["data_b"].id]
}

resource "aws_security_group" "redis" {
  for_each = local.redis_stages

  name                   = "${var.project_name}-${each.key}-redis"
  description            = "ElastiCache Redis for ${each.key}; rest/websocket task SGs only"
  vpc_id                 = data.aws_vpc.shared.id
  revoke_rules_on_delete = true

  tags = {
    Name        = "${var.project_name}-${each.key}-redis-sg"
    Environment = each.key
  }
}

resource "aws_vpc_security_group_ingress_rule" "redis_from_tasks" {
  for_each = { for k, v in local.data_client_task_sgs : k => v if contains(local.redis_stages, v.stage) }

  security_group_id            = aws_security_group.redis[each.value.stage].id
  description                  = "Redis from ${each.key} tasks"
  referenced_security_group_id = each.value.sg_id
  ip_protocol                  = "tcp"
  from_port                    = var.redis_port
  to_port                      = var.redis_port
}

resource "aws_elasticache_replication_group" "redis" {
  for_each = local.redis_stages

  replication_group_id = "${var.project_name}-${each.key}-redis"
  description          = "${each.key} chat fan-out (Redis Pub/Sub)"

  engine               = "redis"
  engine_version       = var.redis_engine_version
  node_type            = var.redis_node_type
  parameter_group_name = var.redis_parameter_group_name
  port                 = var.redis_port

  num_cache_clusters          = 1
  automatic_failover_enabled  = false
  multi_az_enabled            = false
  preferred_cache_cluster_azs = [local.az_a] # ECS 태스크(dev 서브넷)와 같은 AZ

  subnet_group_name  = aws_elasticache_subnet_group.redis[0].name
  security_group_ids = [aws_security_group.redis[each.key].id]

  at_rest_encryption_enabled = true
  transit_encryption_enabled = var.redis_transit_encryption_enabled

  snapshot_retention_limit   = 0
  auto_minor_version_upgrade = true
  apply_immediately          = true

  tags = {
    Name        = "${var.project_name}-${each.key}-redis"
    Environment = each.key
  }
}

# -----------------------------------------------------------------------------
# dev : dev EC2(compose MySQL·Redis) ← dev rest·websocket 태스크
#   compose에서 해당 포트가 호스트 인터페이스로 publish되어 있어야 한다 (예: "3306:3306", "6379:6379")
# -----------------------------------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "dev_data_from_tasks" {
  for_each = merge({}, [
    for k, v in local.data_client_task_sgs : {
      for port in var.dev_data_ports : "${k}-${port}" => merge(v, { port = port })
    }
    if v.stage == "dev"
  ]...)

  security_group_id            = aws_security_group.dev_instance.id
  description                  = "Port ${each.value.port} from ${trimsuffix(each.key, "-${each.value.port}")} tasks"
  referenced_security_group_id = each.value.sg_id
  ip_protocol                  = "tcp"
  from_port                    = each.value.port
  to_port                      = each.value.port
}
