# =============================================================================
# Amazon MSK (이벤트 브로커) — issues/kafka-msk-setup.md
#
#   구성 : MSK Provisioned Standard, Kafka 4.1.x, 3AZ 브로커 3대. var.msk_stages에 든 스테이지마다 클러스터 1개.
#          Express는 Kafka Streams 지원이 불완전하다고 AWS가 안내해 쓰지 않는다(매칭이 Streams + exactly_once_v2).
#   네트워크 : 기존 V2 서브넷은 2AZ라 세 번째 AZ 전용 서브넷을 var.msk_third_subnet으로 추가한다.
#   접근 : 9092(VPC 내부 평문, 무인증)만, msk_client_services 태스크 SG와 kafka-init SG에서만. 퍼블릭 접근 없음.
#          IAM은 앱 클라이언트 변경이 필요하고 AI 서버(aiokafka)도 함께 바꿔야 해서 전환 후 SCRAM으로 별도 진행한다.
#   토픽 : auto.create 끄고 kafka-init(1회성 ECS 태스크)이 만든다. moyeota-matching-* Streams 내부 토픽은 넣지 않는다.
#   주입 : KAFKA_BOOTSTRAP_SERVERS (Terraform 관리 SSM). ecs_service는 task_definition 변경을 무시하므로
#          apply만으로 실행 중인 태스크가 바뀌지는 않는다. kafka-init 뒤에 클라이언트 서비스를 재배포한다.
#
#   적용 순서 : msk_stages·msk_third_subnet 지정 → terraform apply → output msk_kafka_init_run_commands 실행
#               → 토픽 확인 → rest·fastapi 재배포 (AI 서버는 이 값이 있으면 소비를 시작한다)
# =============================================================================

locals {
  # ecs_stages에 없는 스테이지는 제외한다 (클라이언트 서비스·클러스터가 함께 있어야 쓸 수 있다)
  msk_active_stages = toset([for s in var.msk_stages : s if contains(keys(local.ecs_stages), s)])
  msk_enabled       = length(local.msk_active_stages) > 0

  msk_broker_count   = 3
  msk_replication    = 3
  msk_client_port    = 9092
  msk_jmx_port       = 11001
  msk_node_port      = 11002
  msk_retention_1day = 86400000
  msk_retention_7day = 604800000

  # 브로커에 붙는 ECS 서비스. worker·matching은 ecs_services에 추가되면 SG·환경 변수가 자동으로 따라온다.
  # websocket은 Kafka에 붙지 않는다 (BE #137 A2).
  msk_client_services = ["rest", "fastapi", "worker", "matching"]

  msk_subnet_ids = concat(
    [aws_subnet.v2["data_a"].id, aws_subnet.v2["data_b"].id],
    aws_subnet.msk_third[*].id,
  )

  msk_client_task_sgs = {
    for k, s in local.ecs_service_instances : k => {
      stage = s.stage
      sg_id = module.ecs_service[k].task_security_group_id
    }
    if contains(local.msk_client_services, s.service) && contains(local.msk_active_stages, s.stage)
  }

  # ecs.tf secrets에 합친다. 스테이지 → { 환경 변수 → SSM ARN }
  msk_secrets = {
    for s in local.msk_active_stages : s => {
      KAFKA_BOOTSTRAP_SERVERS = aws_ssm_parameter.kafka_bootstrap_servers[s].arn
    }
  }

  # BE #137 A6 기준. request-dlt는 원본(4MB)이 그대로 넘어오므로 같은 크기를 허용한다.
  msk_topics = [
    { name = "matching.request", partitions = 6, config = "retention.ms=${local.msk_retention_1day}" },
    { name = "matching.decision", partitions = 6, config = "retention.ms=${local.msk_retention_1day}" },
    { name = "community.post.changed", partitions = 6, config = "retention.ms=${local.msk_retention_7day}" },
    { name = "congestion.analysis.request", partitions = 6, config = "retention.ms=${local.msk_retention_1day},max.message.bytes=4194304" },
    { name = "congestion.analysis.result", partitions = 6, config = "retention.ms=${local.msk_retention_1day}" },
    { name = "notification.push.request", partitions = 6, config = "retention.ms=${local.msk_retention_1day}" },
    { name = "notification.bulk-push.request", partitions = 6, config = "retention.ms=${local.msk_retention_1day}" },
    { name = "settlement.image-analysis.request", partitions = 6, config = "retention.ms=${local.msk_retention_1day}" },
    { name = "settlement.image-analysis.result", partitions = 6, config = "retention.ms=${local.msk_retention_1day}" },
    { name = "matching.decision-dlt", partitions = 1, config = "retention.ms=${local.msk_retention_7day}" },
    { name = "community.post.changed-dlt", partitions = 1, config = "retention.ms=${local.msk_retention_7day}" },
    { name = "congestion.analysis.request-dlt", partitions = 1, config = "retention.ms=${local.msk_retention_7day},max.message.bytes=4194304" },
    { name = "congestion.analysis.result-dlt", partitions = 1, config = "retention.ms=${local.msk_retention_7day}" },
    { name = "notification.push.request-dlt", partitions = 1, config = "retention.ms=${local.msk_retention_7day}" },
    { name = "notification.bulk-push.request-dlt", partitions = 1, config = "retention.ms=${local.msk_retention_7day}" },
    { name = "settlement.image-analysis.request-dlt", partitions = 1, config = "retention.ms=${local.msk_retention_7day}" },
    { name = "settlement.image-analysis.result-dlt", partitions = 1, config = "retention.ms=${local.msk_retention_7day}" },
  ]

  # 중앙 Prometheus 수집 대상 (monitoring.tf). AWS 권장에 따라 수집 주기는 60초 이상으로 둔다.
  msk_scrape_targets = flatten([
    for s in local.msk_active_stages : [
      for exporter, port in { jmx = local.msk_jmx_port, node = local.msk_node_port } : {
        job                       = "${s}-msk-${exporter}"
        stage                     = s
        service                   = "msk-${exporter}"
        targets                   = [for b in split(",", aws_msk_cluster.kafka[s].bootstrap_brokers) : "${split(":", b)[0]}:${port}"]
        metrics_path              = "/metrics"
        scrape_interval           = "60s"
      }
    ]
  ])

  msk_disk_alarms = {
    for pair in setproduct(local.msk_active_stages, range(1, local.msk_broker_count + 1)) :
    "${pair[0]}-${pair[1]}" => { stage = pair[0], broker = pair[1] }
    if local.alerting_enabled && contains(var.alert_stages, pair[0])
  }
  msk_alarm_stages = toset([
    for s in local.msk_active_stages : s if local.alerting_enabled && contains(var.alert_stages, s)
  ])
}

# -----------------------------------------------------------------------------
# 세 번째 AZ 서브넷 : 데이터 계층 라우트 테이블(인터넷 경로 없음)을 그대로 쓴다
# -----------------------------------------------------------------------------

resource "aws_subnet" "msk_third" {
  count = local.msk_enabled && var.msk_third_subnet != null ? 1 : 0

  vpc_id                  = data.aws_vpc.shared.id
  cidr_block              = var.msk_third_subnet.cidr
  availability_zone       = var.msk_third_subnet.az
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.project_name}-data-msk-c"
    Tier = "private-data"
  }
}

resource "aws_route_table_association" "msk_third" {
  count = length(aws_subnet.msk_third)

  subnet_id      = aws_subnet.msk_third[0].id
  route_table_id = aws_route_table.private_data.id
}

# -----------------------------------------------------------------------------
# 보안그룹
# -----------------------------------------------------------------------------

resource "aws_security_group" "msk" {
  for_each = local.msk_active_stages

  name                   = "${var.project_name}-${each.key}-msk"
  description            = "MSK brokers (${each.key}); 9092 from client task SGs only"
  vpc_id                 = data.aws_vpc.shared.id
  revoke_rules_on_delete = true

  tags = {
    Name  = "${var.project_name}-${each.key}-msk-sg"
    Tier  = "private-data"
    Stage = each.key
  }
}

resource "aws_vpc_security_group_ingress_rule" "msk_from_clients" {
  for_each = local.msk_client_task_sgs

  security_group_id            = aws_security_group.msk[each.value.stage].id
  description                  = "Kafka 9092 from ${each.key} tasks"
  referenced_security_group_id = each.value.sg_id
  ip_protocol                  = "tcp"
  from_port                    = local.msk_client_port
  to_port                      = local.msk_client_port

  tags = {
    Stage = each.value.stage
  }
}

resource "aws_vpc_security_group_ingress_rule" "msk_from_monitoring" {
  for_each = local.monitoring_enabled ? local.msk_active_stages : toset([])

  security_group_id            = aws_security_group.msk[each.key].id
  description                  = "Open Monitoring JMX and Node exporters from Prometheus"
  referenced_security_group_id = aws_security_group.monitoring[0].id
  ip_protocol                  = "tcp"
  from_port                    = local.msk_jmx_port
  to_port                      = local.msk_node_port

  tags = {
    Stage = each.key
  }
}

# -----------------------------------------------------------------------------
# 브로커 설정 : 3대 기준 (RF 3, 최소 ISR 2). unclean은 MSK Standard 기본값이 true라 명시적으로 끈다.
#   내부 토픽 복제 수는 처음 생성될 때 정해지므로 첫 클라이언트가 붙기 전에 이 설정으로 시작해야 한다.
# -----------------------------------------------------------------------------

resource "aws_msk_configuration" "kafka" {
  count = local.msk_enabled ? 1 : 0

  name           = "${var.project_name}-kafka"
  description    = "RF 3, min ISR 2, no auto topic creation, no unclean leader election"
  kafka_versions = [var.msk_kafka_version]

  server_properties = <<-EOT
    auto.create.topics.enable=false
    default.replication.factor=${local.msk_replication}
    min.insync.replicas=2
    offsets.topic.replication.factor=${local.msk_replication}
    transaction.state.log.replication.factor=${local.msk_replication}
    transaction.state.log.min.isr=2
    unclean.leader.election.enable=false
  EOT

  lifecycle {
    create_before_destroy = true
  }
}

# -----------------------------------------------------------------------------
# 클러스터
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "msk" {
  for_each = local.msk_active_stages

  name              = "/msk/${var.project_name}-${each.key}"
  retention_in_days = var.msk_log_retention_days

  tags = {
    Stage = each.key
  }
}

resource "aws_msk_cluster" "kafka" {
  for_each = local.msk_active_stages

  cluster_name           = "${var.project_name}-${each.key}"
  kafka_version          = var.msk_kafka_version
  number_of_broker_nodes = local.msk_broker_count
  enhanced_monitoring    = var.msk_enhanced_monitoring

  broker_node_group_info {
    instance_type   = lookup(var.msk_instance_types, each.key, null)
    client_subnets  = local.msk_subnet_ids
    security_groups = [aws_security_group.msk[each.key].id]

    storage_info {
      ebs_storage_info {
        volume_size = var.msk_volume_gib
      }
    }
  }

  configuration_info {
    arn      = aws_msk_configuration.kafka[0].arn
    revision = aws_msk_configuration.kafka[0].latest_revision
  }

  client_authentication {
    unauthenticated = true
  }

  encryption_info {
    encryption_in_transit {
      client_broker = "PLAINTEXT"
      in_cluster    = true
    }
  }

  open_monitoring {
    prometheus {
      jmx_exporter {
        enabled_in_broker = true
      }
      node_exporter {
        enabled_in_broker = true
      }
    }
  }

  logging_info {
    broker_logs {
      cloudwatch_logs {
        enabled   = true
        log_group = aws_cloudwatch_log_group.msk[each.key].name
      }
    }
  }

  lifecycle {
    # 스토리지 오토스케일링이 늘린 값을 되돌리지 않는다
    ignore_changes = [broker_node_group_info[0].storage_info[0].ebs_storage_info[0].volume_size]

    precondition {
      condition     = var.msk_third_subnet != null
      error_message = "msk_stages를 쓰려면 3AZ 구성을 위한 msk_third_subnet을 지정해야 한다."
    }

    precondition {
      condition     = contains(keys(var.msk_instance_types), each.key)
      error_message = "msk_instance_types에 이 스테이지의 인스턴스 타입을 지정해야 한다."
    }
  }

  tags = {
    Name  = "${var.project_name}-${each.key}-msk"
    Stage = each.key
  }
}

# 스토리지는 줄일 수 없고 확장은 6시간에 한 번만 가능하다. 최대값은 비용 상한으로 정한다.
resource "aws_appautoscaling_target" "msk_storage" {
  for_each = local.msk_active_stages

  service_namespace  = "kafka"
  scalable_dimension = "kafka:broker-storage:VolumeSize"
  resource_id        = aws_msk_cluster.kafka[each.key].arn
  min_capacity       = 1
  max_capacity       = var.msk_storage_max_gib
}

resource "aws_appautoscaling_policy" "msk_storage" {
  for_each = local.msk_active_stages

  name               = "${var.project_name}-${each.key}-msk-storage"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.msk_storage[each.key].service_namespace
  scalable_dimension = aws_appautoscaling_target.msk_storage[each.key].scalable_dimension
  resource_id        = aws_appautoscaling_target.msk_storage[each.key].resource_id

  target_tracking_scaling_policy_configuration {
    target_value = 60

    predefined_metric_specification {
      predefined_metric_type = "KafkaBrokerStorageUtilization"
    }
  }
}

# -----------------------------------------------------------------------------
# 클라이언트 주소 (Terraform 관리 SSM, broker.tf의 Redis 주소와 같은 방식)
# -----------------------------------------------------------------------------

resource "aws_ssm_parameter" "kafka_bootstrap_servers" {
  for_each = local.msk_active_stages

  name        = "/${var.config_path_prefix}/${each.key}/broker/KAFKA_BOOTSTRAP_SERVERS"
  description = "MSK bootstrap ${each.key} (Terraform 관리 — 콘솔에서 수정하지 않는다)"
  type        = "String"
  tier        = "Standard"
  value       = aws_msk_cluster.kafka[each.key].bootstrap_brokers

  tags = {
    Stage = each.key
    Group = "broker"
  }
}

# -----------------------------------------------------------------------------
# kafka-init : 토픽 일괄 생성 (1회성 ECS 태스크, 다시 실행해도 안전). 서비스로 띄우지 않는다.
#   파티션 수가 선언과 다르면 실패한다. matching.request는 나중에 늘리면 상태가 어긋나므로 자동으로 늘리지 않는다.
# -----------------------------------------------------------------------------

resource "aws_security_group" "kafka_init" {
  for_each = local.msk_active_stages

  name                   = "${var.project_name}-${each.key}-kafka-init"
  description            = "kafka-init task (${each.key}); brokers only"
  vpc_id                 = data.aws_vpc.shared.id
  revoke_rules_on_delete = true

  tags = {
    Name  = "${var.project_name}-${each.key}-kafka-init-sg"
    Stage = each.key
  }
}

resource "aws_vpc_security_group_egress_rule" "kafka_init_to_msk" {
  for_each = local.msk_active_stages

  security_group_id            = aws_security_group.kafka_init[each.key].id
  description                  = "Kafka 9092 to MSK brokers"
  referenced_security_group_id = aws_security_group.msk[each.key].id
  ip_protocol                  = "tcp"
  from_port                    = local.msk_client_port
  to_port                      = local.msk_client_port
}

resource "aws_vpc_security_group_ingress_rule" "msk_from_kafka_init" {
  for_each = local.msk_active_stages

  security_group_id            = aws_security_group.msk[each.key].id
  description                  = "Kafka 9092 from kafka-init task"
  referenced_security_group_id = aws_security_group.kafka_init[each.key].id
  ip_protocol                  = "tcp"
  from_port                    = local.msk_client_port
  to_port                      = local.msk_client_port
}

resource "aws_cloudwatch_log_group" "kafka_init" {
  for_each = local.msk_active_stages

  name              = "/ecs/${var.project_name}-${each.key}/kafka-init"
  retention_in_days = var.msk_log_retention_days

  tags = {
    Stage = each.key
  }
}

resource "aws_ecs_task_definition" "kafka_init" {
  for_each = local.msk_active_stages

  family                   = "${var.project_name}-${each.key}-kafka-init"
  requires_compatibilities = ["EC2"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = module.ecs_cluster[each.key].task_execution_role_arn

  container_definitions = jsonencode([{
    name       = "kafka-init"
    image      = var.msk_admin_image
    essential  = true
    entryPoint = ["/bin/sh", "-c"]
    command = [templatefile("${path.module}/templates/kafka/topics.sh.tftpl", {
      topics             = local.msk_topics
      replication_factor = local.msk_replication
    })]
    secrets = [{
      name      = "KAFKA_BOOTSTRAP_SERVERS"
      valueFrom = aws_ssm_parameter.kafka_bootstrap_servers[each.key].arn
    }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.kafka_init[each.key].name
        awslogs-region        = var.aws_region
        awslogs-stream-prefix = "kafka-init"
      }
    }
  }])

  tags = {
    Stage = each.key
  }
}

# -----------------------------------------------------------------------------
# 알람 : 디스크 85%, 오프라인 파티션, 활성 컨트롤러 없음. 대상 스테이지는 alert_stages.
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "msk_disk" {
  for_each = local.msk_disk_alarms

  alarm_name          = "${var.project_name}-${each.value.stage}-msk-disk-broker-${each.value.broker}"
  alarm_description   = "MSK broker ${each.value.broker} data disk usage above 85%"
  namespace           = "AWS/Kafka"
  metric_name         = "KafkaDataLogsDiskUsed"
  dimensions          = { "Cluster Name" = aws_msk_cluster.kafka[each.value.stage].cluster_name, "Broker ID" = tostring(each.value.broker) }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 85
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions

  tags = {
    Stage = each.value.stage
  }
}

resource "aws_cloudwatch_metric_alarm" "msk_offline_partitions" {
  for_each = local.msk_alarm_stages

  alarm_name          = "${var.project_name}-${each.key}-msk-offline-partitions"
  alarm_description   = "MSK has offline partitions"
  namespace           = "AWS/Kafka"
  metric_name         = "OfflinePartitionsCount"
  dimensions          = { "Cluster Name" = aws_msk_cluster.kafka[each.key].cluster_name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions

  tags = {
    Stage = each.key
  }
}

resource "aws_cloudwatch_metric_alarm" "msk_active_controller" {
  for_each = local.msk_alarm_stages

  alarm_name          = "${var.project_name}-${each.key}-msk-no-active-controller"
  alarm_description   = "MSK has no active controller"
  namespace           = "AWS/Kafka"
  metric_name         = "ActiveControllerCount"
  dimensions          = { "Cluster Name" = aws_msk_cluster.kafka[each.key].cluster_name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions

  tags = {
    Stage = each.key
  }
}

# -----------------------------------------------------------------------------
# 출력
# -----------------------------------------------------------------------------

output "msk_bootstrap_brokers" {
  description = "스테이지별 MSK 평문 부트스트랩 주소 (SSM /<config_path_prefix>/<stage>/broker/KAFKA_BOOTSTRAP_SERVERS와 같은 값)"
  value       = { for s, c in aws_msk_cluster.kafka : s => c.bootstrap_brokers }
}

output "msk_kafka_init_run_commands" {
  description = "스테이지별 토픽 생성 명령. 로그: /ecs/<project>-<stage>/kafka-init"
  value = {
    for s in local.msk_active_stages : s => join(" ", [
      "aws ecs run-task --region ${var.aws_region}",
      "--cluster ${module.ecs_cluster[s].cluster_name}",
      "--task-definition ${aws_ecs_task_definition.kafka_init[s].family}",
      "--network-configuration",
      "'awsvpcConfiguration={subnets=[${join(",", [for key in local.ecs_stages[s].subnet_keys : aws_subnet.v2[key].id])}],securityGroups=[${aws_security_group.kafka_init[s].id}],assignPublicIp=DISABLED}'",
    ])
  }
}
