# =============================================================================
# 채팅 메시지 브로커 (Redis Pub/Sub fan-out)
#   설계: wiki「V2 WebSocket 메시지 버스와 Redis 도입 설계」
#     - MySQL 커밋 후 REST·WebSocket이 공통 채널에 chat.message.created 이벤트를 발행
#     - 모든 WebSocket 태스크가 채널을 구독 → roomId → 로컬 Simple Broker(/sub/chat/{roomId})
#     - Redis는 실시간 전달용(at-most-once). 원본·누락 복구는 MySQL 이력 API
#     - 채널 이름은 환경 prefix 포함: moyeota:<stage>:chat:fanout:v1
#
#   스테이지별 Redis
#     dev  : dev EC2 compose Redis (dev rest·websocket 태스크 → dev EC2 SG 인바운드)
#     stg  : ElastiCache 단일 노드 (QA·스케줄링 테스트 때만 elasticache_redis_stages에 넣는다)
#     prod : ElastiCache primary + replica 1, 자동 장애 조치
#            Redis 장애 = 모든 WebSocket 태스크의 실시간 fan-out 중단이므로 단일 장애점을 두지 않는다
#            (Pub/Sub 이벤트는 저장되지 않아 장애 조치 중 발행분은 유실 → 이력 API로 복구)
#
#   앱 연결 값 (Terraform이 값까지 관리하는 SSM, /<config_path_prefix>/<stage>/broker/*)
#     REDIS_HOST, REDIS_PORT, CHAT_FANOUT_CHANNEL → rest·websocket 태스크 secrets로 주입
#     BE: spring.data.redis.host=${REDIS_HOST}, spring.data.redis.port=${REDIS_PORT}
#     인프라가 만드는 값이라 ssm.tf(CHANGE_ME + 콘솔 입력)와 달리 ignore_changes를 두지 않는다.
#     값이 바뀌면(엔드포인트 교체 등) 서비스를 재배포해야 반영된다.
# =============================================================================

locals {
  # 스테이지별 ElastiCache 구성 (elasticache_redis_stages에 넣은 스테이지만 생성)
  redis_stage_settings = {
    stg = {
      replicas  = 0
      node_type = var.redis_node_type
    }
    prod = {
      replicas  = 1
      node_type = var.redis_prod_node_type
    }
  }

  redis_stages = toset([for s in var.elasticache_redis_stages : s if contains(keys(local.ecs_stages), s)])

  # 노드 ID (<replication_group_id>-001, -002 …) — 알람 dimension용
  redis_nodes = merge({}, [
    for s in local.redis_stages : {
      for i in range(local.redis_stage_settings[s].replicas + 1) :
      "${s}-${format("%03d", i + 1)}" => {
        stage   = s
        node_id = "${var.project_name}-${s}-redis-${format("%03d", i + 1)}"
      }
    }
  ]...)

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

  # 스테이지 → 브로커 엔드포인트 (dev는 dev EC2 compose Redis)
  broker_endpoints = merge(
    { for s in local.redis_stages : s => {
      host = aws_elasticache_replication_group.redis[s].primary_endpoint_address
      port = var.redis_port
    } },
    { for s in(contains(keys(local.ecs_stages), "dev") ? ["dev"] : []) : s => {
      host = aws_instance.host["dev"].private_ip
      port = var.dev_redis_port
    } },
  )

  broker_param_keys = ["REDIS_HOST", "REDIS_PORT", "CHAT_FANOUT_CHANNEL"]

  # "stg/broker/REDIS_HOST" → 값
  broker_params = merge({}, [
    for s in keys(local.broker_endpoints) : {
      "${s}/broker/REDIS_HOST"          = local.broker_endpoints[s].host
      "${s}/broker/REDIS_PORT"          = tostring(local.broker_endpoints[s].port)
      "${s}/broker/CHAT_FANOUT_CHANNEL" = "moyeota:${s}:chat:fanout:v${var.chat_fanout_schema_version}"
    }
  ]...)

  # 스테이지 → { 환경 변수 → SSM ARN } (ecs.tf에서 rest·websocket secrets에 합친다)
  broker_secrets = {
    for s in keys(local.broker_endpoints) : s => {
      for key in local.broker_param_keys : key => aws_ssm_parameter.broker["${s}/broker/${key}"].arn
    }
  }
}

# -----------------------------------------------------------------------------
# ElastiCache for Redis (stg·prod)
#   - 전송 구간 암호화는 기본 off: BE에 spring.data.redis.ssl 설정이 아직 없다
#     (켜려면 redis_transit_encryption_enabled = true + BE SSL 설정, 변경 시 클러스터 교체)
#   - Pub/Sub만 쓰므로 스냅샷을 두지 않는다 (데이터 원본은 MySQL)
#   - 구독자가 느리면 client-output-buffer-limit(pubsub, 기본 32MB hard / 8MB·60s soft)에 걸려
#     Redis가 해당 구독 연결을 끊는다 → WebSocket 태스크 listener 재연결 동작을 앱에서 확인
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
  description          = "${each.key} chat fan-out broker (Redis Pub/Sub)"

  engine               = "redis"
  engine_version       = var.redis_engine_version
  node_type            = local.redis_stage_settings[each.key].node_type
  parameter_group_name = var.redis_parameter_group_name
  port                 = var.redis_port

  # primary는 ECS 태스크(단일 AZ)와 같은 AZ, replica는 다른 AZ
  num_cache_clusters          = local.redis_stage_settings[each.key].replicas + 1
  automatic_failover_enabled  = local.redis_stage_settings[each.key].replicas > 0
  multi_az_enabled            = local.redis_stage_settings[each.key].replicas > 0
  preferred_cache_cluster_azs = slice([local.az_a, local.az_b], 0, local.redis_stage_settings[each.key].replicas + 1)

  subnet_group_name  = aws_elasticache_subnet_group.redis[0].name
  security_group_ids = [aws_security_group.redis[each.key].id]

  at_rest_encryption_enabled = true
  transit_encryption_enabled = var.redis_transit_encryption_enabled

  snapshot_retention_limit   = 0
  auto_minor_version_upgrade = true
  apply_immediately          = each.key != "prod"
  maintenance_window         = "sun:19:00-sun:20:00" # KST 월 04:00–05:00 (출퇴근 피크 밖)

  tags = {
    Name        = "${var.project_name}-${each.key}-redis"
    Environment = each.key
  }
}

# -----------------------------------------------------------------------------
# 앱 연결 값 (SSM, Terraform 관리)
#   실행 Role이 /<config_path_prefix>/<stage>/* 를 읽으므로 추가 권한은 필요 없다.
# -----------------------------------------------------------------------------

resource "aws_ssm_parameter" "broker" {
  for_each = local.broker_params

  name        = "/${var.config_path_prefix}/${each.key}"
  description = "Chat broker ${each.key} (Terraform 관리 — 콘솔에서 수정하지 않는다)"
  type        = "String"
  tier        = "Standard"
  value       = each.value

  tags = {
    Stage = split("/", each.key)[0]
    Group = "broker"
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

# -----------------------------------------------------------------------------
# 알람 (노드별). 알림 대상은 alerting.tf의 local.alarm_actions
#   (alarm_sns_topic_arn → 없으면 alerting_enabled로 만든 <project>-alerts 토픽 → 둘 다 없으면 상태만 남는다)
#   - EngineCPUUtilization : Redis는 단일 스레드 → 엔진 CPU가 fan-out 처리 한계
#   - DatabaseMemoryUsagePercentage : Pub/Sub 출력 버퍼가 쌓이면 메모리가 오른다
#   - NetworkBandwidthOutAllowanceExceeded : fan-out 송신량 = 발행량 × 구독 태스크 수.
#     WebSocket 태스크를 늘릴수록 노드 송신 대역폭이 먼저 한계에 닿는다 (t4g 버스트 대역폭)
# -----------------------------------------------------------------------------

locals {
  redis_alarm_specs = {
    engine-cpu = {
      metric    = "EngineCPUUtilization"
      statistic = "Average"
      threshold = 70
      periods   = 3
    }
    memory = {
      metric    = "DatabaseMemoryUsagePercentage"
      statistic = "Maximum"
      threshold = 80
      periods   = 3
    }
    bandwidth-out-exceeded = {
      metric    = "NetworkBandwidthOutAllowanceExceeded"
      statistic = "Sum"
      threshold = 0
      periods   = 1
    }
  }

  redis_alarms = merge({}, [
    for nk, n in local.redis_nodes : {
      for ak, a in local.redis_alarm_specs : "${nk}-${ak}" => merge(a, n, { alarm = ak })
    }
  ]...)
}

resource "aws_cloudwatch_metric_alarm" "redis" {
  for_each = local.redis_alarms

  alarm_name          = "${each.value.node_id}-${each.value.alarm}"
  alarm_description   = "${each.value.stage} chat broker ${each.value.metric} on ${each.value.node_id}"
  namespace           = "AWS/ElastiCache"
  metric_name         = each.value.metric
  statistic           = each.value.statistic
  period              = 60
  evaluation_periods  = each.value.periods
  threshold           = each.value.threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    CacheClusterId = each.value.node_id
  }

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions

  tags = {
    Stage = each.value.stage
  }

  depends_on = [aws_elasticache_replication_group.redis]
}
