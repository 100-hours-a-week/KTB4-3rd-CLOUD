# =============================================================================
# 로그 수집 — Grafana Alloy (ECS DAEMON 서비스, 스테이지 클러스터마다 1개)
#   설계 근거: wiki「V2 중앙 집중식 모니터링 시스템 설계」4.2~4.3
#
#   컨테이너 인스턴스 → Alloy(host 네트워크) → Docker API로 같은 호스트의 태스크 로그 읽기 → Loki :3100 push
#   - 앱·태스크 정의는 바꾸지 않는다. 태스크는 계속 awslogs로 CloudWatch에 보내고,
#     Docker dual logging 캐시(docker logs)를 Alloy가 읽어 Loki에도 보낸다
#   - host 네트워크라 ENI를 쓰지 않는다 (awsvpc 태스크의 호스트당 ENI 한도와 무관)
#   - Loki 인바운드는 monitoring.tf의 monitoring_loki_from_ecs_instances(인스턴스 SG → 3100)가 연다
#   - 설정은 템플릿을 렌더링해 환경 변수로 넣는다. 모니터링 호스트가 교체돼 IP가 바뀌면 새 revision으로 재배포된다
# =============================================================================

locals {
  alloy_loki_push_url = local.monitoring_enabled ? "http://${module.monitoring[0].private_ip}:${local.monitoring_loki_port}/loki/api/v1/push" : null

  alloy_configs = {
    for stage in local.monitoring_log_stages : stage => templatefile("${path.module}/templates/alloy.alloy.tftpl", {
      stage         = stage
      family_prefix = "${var.project_name}-${stage}-"
      loki_push_url = local.alloy_loki_push_url
    })
  }
}

resource "aws_cloudwatch_log_group" "alloy" {
  for_each = local.monitoring_log_stages

  name              = "/ecs/${var.project_name}-${each.key}/alloy"
  retention_in_days = local.ecs_stages[each.key].log_retention_days

  tags = {
    Stage     = each.key
    Service   = "alloy"
    Component = "monitoring"
  }
}

resource "aws_ecs_task_definition" "alloy" {
  for_each = local.monitoring_log_stages

  family                   = "${var.project_name}-${each.key}-alloy"
  requires_compatibilities = ["EC2"]
  network_mode             = "host"
  execution_role_arn       = module.ecs_cluster[each.key].task_execution_role_arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  # Docker API (컨테이너 목록·로그 읽기)
  volume {
    name      = "docker-sock"
    host_path = "/var/run/docker.sock"
  }

  # 컨테이너별 읽은 위치(positions). 재시작해도 이어서 읽어 중복·누락을 줄인다
  volume {
    name      = "alloy-data"
    host_path = "/var/lib/moyeota-alloy"
  }

  container_definitions = jsonencode([
    {
      name      = "alloy"
      image     = var.monitoring_alloy_image
      essential = true
      # docker.sock(root:docker 0660)을 읽기 위해 root로 실행
      user              = "0"
      memoryReservation = var.monitoring_alloy_memory.reservation
      memory            = var.monitoring_alloy_memory.limit

      # 설정 파일을 이미지에 굽지 않고 환경 변수로 받아 파일로 쓴 뒤 실행한다
      #   UI·메트릭 포트(12345)는 호스트 루프백에만 연다 (host 네트워크라 0.0.0.0이면 VPC에 노출된다)
      entryPoint = ["/bin/sh", "-c"]
      command = [
        "printf '%s' \"$ALLOY_CONFIG\" > /tmp/config.alloy && exec /bin/alloy run /tmp/config.alloy --server.http.listen-addr=127.0.0.1:12345 --storage.path=/var/lib/alloy/data --disable-reporting",
      ]

      environment = [
        { name = "ALLOY_CONFIG", value = local.alloy_configs[each.key] },
      ]

      mountPoints = [
        { sourceVolume = "docker-sock", containerPath = "/var/run/docker.sock", readOnly = true },
        { sourceVolume = "alloy-data", containerPath = "/var/lib/alloy", readOnly = false },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.alloy[each.key].name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "alloy"
        }
      }
    },
  ])

  tags = {
    Stage     = each.key
    Service   = "alloy"
    Component = "monitoring"
  }
}

# DAEMON: 클러스터의 모든 컨테이너 인스턴스에 1개씩. 새 인스턴스가 붙으면 자동으로 뜬다
#   DAEMON은 Capacity Provider 전략을 쓸 수 없어 launch_type = EC2로 둔다
#   호스트에 메모리 예약 여유가 없으면 그 호스트에는 뜨지 않는다 → alerting.tf의 tasks-below-desired 알람
resource "aws_ecs_service" "alloy" {
  for_each = local.monitoring_log_stages

  name                = "alloy"
  cluster             = module.ecs_cluster[each.key].cluster_arn
  task_definition     = aws_ecs_task_definition.alloy[each.key].arn
  scheduling_strategy = "DAEMON"
  launch_type         = "EC2"

  enable_ecs_managed_tags = true
  propagate_tags          = "SERVICE"

  tags = {
    Stage     = each.key
    Service   = "alloy"
    Component = "monitoring"
  }
}

# Loki 전송 유실 감지: loki.write가 재시도를 모두 실패하면 "final error sending batch, no retries left, dropping data"를 남긴다
#   Alloy 자신의 로그(awslogs)에서 이 문구를 세어 CloudWatch 지표로 만든다 → alerting.tf의 <stage>-alloy-log-dropped 알람
#   (프로세스 중단은 tasks-below-desired 알람, Loki 중단은 모니터링 하트비트 알람이 잡는다)
resource "aws_cloudwatch_log_metric_filter" "alloy_dropped" {
  for_each = local.monitoring_log_stages

  name           = "${var.project_name}-${each.key}-alloy-dropped"
  log_group_name = aws_cloudwatch_log_group.alloy[each.key].name
  pattern        = "\"final error sending batch\""

  metric_transformation {
    name      = "AlloyDroppedBatches-${each.key}"
    namespace = module.monitoring[0].heartbeat_namespace
    value     = "1"
    unit      = "Count"
  }
}
