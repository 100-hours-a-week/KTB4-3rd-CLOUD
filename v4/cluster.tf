# v4 ECS 클러스터, Service Connect 네임스페이스, ECS Exec 로그, Alloy(로그 수집 DAEMON).
#   참고: v2/modules/ecs/ecs-cluster/main.tf, v2/alloy.tf

locals {
  monitoring_loki_port = 3100
  monitoring_otlp_port = 9090

  alloy_config = templatefile("${path.module}/templates/alloy.alloy.tftpl", {
    stage         = "prod"
    family_prefix = "${local.name_prefix}-"
    loki_push_url = "http://${data.aws_instance.monitoring.private_ip}:${local.monitoring_loki_port}/loki/api/v1/push"
  })
}

resource "aws_service_discovery_http_namespace" "this" {
  name        = "prod.moyeota-v4.local"
  description = "Service Connect namespace for ${local.cluster_name}"
}

resource "aws_cloudwatch_log_group" "exec" {
  name              = local.exec_log_group_name
  retention_in_days = var.exec_log_retention_days
}

resource "aws_ecs_cluster" "this" {
  name = local.cluster_name

  # 최소 운영이라 Container Insights는 끈다. ECS·ALB 기본 지표와 앱 OTLP 지표로 본다.
  setting {
    name  = "containerInsights"
    value = "disabled"
  }

  service_connect_defaults {
    namespace = aws_service_discovery_http_namespace.this.arn
  }

  configuration {
    execute_command_configuration {
      logging = "OVERRIDE"

      log_configuration {
        cloud_watch_log_group_name = aws_cloudwatch_log_group.exec.name
      }
    }
  }
}

# ---------------------------------------------------------------------------
# Alloy: 컨테이너 인스턴스마다 1개(DAEMON). Docker API로 같은 호스트 태스크 로그를 읽어 Loki로 보낸다.
#   host 네트워크라 ENI를 쓰지 않는다 (호스트당 awsvpc 태스크 2개 한도와 무관).
#   태스크는 계속 awslogs로 CloudWatch에 보내고, Docker dual logging 캐시를 Alloy가 읽는다.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "alloy" {
  name              = "/ecs/${local.cluster_name}/alloy"
  retention_in_days = var.log_retention_days
}

resource "aws_ecs_task_definition" "alloy" {
  family                   = "${local.name_prefix}-alloy"
  requires_compatibilities = ["EC2"]
  network_mode             = "host"
  execution_role_arn       = aws_iam_role.task_execution.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  volume {
    name      = "docker-sock"
    host_path = "/var/run/docker.sock"
  }

  # 컨테이너별 읽은 위치. 재시작해도 이어서 읽는다
  volume {
    name      = "alloy-data"
    host_path = "/var/lib/moyeota-alloy"
  }

  container_definitions = jsonencode([
    {
      name      = "alloy"
      image     = var.alloy_image
      essential = true
      # docker.sock(root:docker 0660)을 읽기 위해 root로 실행
      user              = "0"
      memoryReservation = 128
      memory            = 256

      # UI·지표 포트(12345)는 호스트 루프백에만 연다 (host 네트워크라 0.0.0.0이면 VPC에 노출된다)
      entryPoint = ["/bin/sh", "-c"]
      command = [
        "printf '%s' \"$ALLOY_CONFIG\" > /tmp/config.alloy && exec /bin/alloy run /tmp/config.alloy --server.http.listen-addr=127.0.0.1:12345 --storage.path=/var/lib/alloy/data --disable-reporting",
      ]

      environment = [
        { name = "ALLOY_CONFIG", value = local.alloy_config },
      ]

      mountPoints = [
        { sourceVolume = "docker-sock", containerPath = "/var/run/docker.sock", readOnly = true },
        { sourceVolume = "alloy-data", containerPath = "/var/lib/alloy", readOnly = false },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.alloy.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "alloy"
        }
      }
    },
  ])
}

# DAEMON은 Capacity Provider 전략을 쓸 수 없어 launch_type = EC2로 둔다
resource "aws_ecs_service" "alloy" {
  name                = "alloy"
  cluster             = aws_ecs_cluster.this.arn
  task_definition     = aws_ecs_task_definition.alloy.arn
  scheduling_strategy = "DAEMON"
  launch_type         = "EC2"

  enable_ecs_managed_tags = true
  propagate_tags          = "SERVICE"
}
