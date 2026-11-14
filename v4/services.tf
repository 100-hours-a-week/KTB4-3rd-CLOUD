# v4 ECS 서비스 4개 (설계 5.2·5.3·5.10절).
#   rest      : BE, APP_ROLE=var.rest_app_role (전환 전 "rest", 전환 후 "rest,worker,matching")
#   websocket : BE, APP_ROLE=websocket
#   frontend  : FE
#   fastapi   : AI, 내부 전용 (Service Connect 서버 http://fastapi:8000)
#
# - 서비스마다 레플리카 1개. 호스트당 awsvpc 태스크가 2개뿐이라 기존 태스크를 먼저 내리고 새 태스크를 띄운다(0% / 100%).
# - rest와 websocket은 서로 다른 호스트에 둔다 (memberOf + task:group 반대 배치).
# - Task Definition은 부트스트랩 revision이다. 이후 이미지는 CD(Deploy Role)가 digest로 새 revision을 등록해 반영하므로
#   서비스는 task_definition을 ignore한다. Terraform으로 환경 변수를 바꾼 뒤에는 서비스를 새 revision으로 갱신해야 한다 (README).
# - 시크릿 값은 V2 prod 경로(/moyeota/v2/prod/*)와 v4 경로(/moyeota/v4/prod/*)의 SSM에서 읽는다.
#   참고: v2/modules/ecs/ecs-service/main.tf, v3/helm/app-values/{services,prod}/*

locals {
  ecr_registry = "${local.account_id}.dkr.ecr.${local.region}.amazonaws.com"

  v2_param = "arn:${local.partition}:ssm:${local.region}:${local.account_id}:parameter/${var.v2_config_path}"

  otlp_environment = {
    OTLP_METRICS_ENABLED = "true"
    OTLP_METRICS_URL     = "http://${data.aws_instance.monitoring.private_ip}:${local.monitoring_otlp_port}/api/v1/otlp/v1/metrics"
    STAGE                = "prod"
  }

  # V3 backend-common.yaml의 시크릿 29개 + prod 추가분. broker 접속 정보와 MONGODB_URI는 v4 데이터 호스트 값을 쓴다.
  backend_v2_secret_keys = [
    "ACCOUNT_ENC_KEY", "DB_HOST", "DB_NAME", "DB_PASSWORD", "DB_PORT", "DB_USERNAME", "EXTRA_FRONT_ORIGINS",
    "FCM_SERVICE_ACCOUNT_JSON", "FRONT_CALLBACK_URI", "FRONT_URL", "IMAGE_PUBLIC_BASE_URL", "INTERNAL_API_KEY",
    "JWT_SECRET", "KAKAO_ADMIN_KEY", "KAKAO_CLIENT_ID", "KAKAO_CLIENT_SECRET", "KAKAO_REDIRECT_URI",
    "MANAGEMENT_ENDPOINTS_WEB_EXPOSURE_INCLUDE", "MANAGEMENT_ENDPOINT_PROMETHEUS_ENABLED",
    "MOYEOTA_AUTH_COOKIE_SAMESITE", "MOYEOTA_AUTH_COOKIE_SECURE", "MOYEOTA_NOTIFICATION_PUSH_ENABLED",
    "MOYEOTA_RELAY_ENV", "S3_BUCKET", "SERVER_FORWARD_HEADERS_STRATEGY", "SPRING_PROFILES_ACTIVE",
    "CONGESTION_AUTHOR_KEY_SECRET",
  ]

  backend_secrets = merge(
    { for k in local.backend_v2_secret_keys : k => "${local.v2_param}/backend/${k}" },
    {
      CHAT_FANOUT_CHANNEL = "${local.v2_param}/broker/CHAT_FANOUT_CHANNEL"
      REDIS_HOST          = aws_ssm_parameter.broker["REDIS_HOST"].arn
      REDIS_PORT          = aws_ssm_parameter.broker["REDIS_PORT"].arn
      MONGODB_URI         = aws_ssm_parameter.mongo["uri"].arn
    },
  )

  # FCM 서비스 계정 JSON을 파일로 쓰고 환경 변수에서 지운 뒤 java를 실행한다 (V3 backend-common.yaml과 같다)
  backend_command = [
    "case \"$FCM_SERVICE_ACCOUNT_JSON\" in \"{\"*) umask 077 && printf '%s' \"$FCM_SERVICE_ACCOUNT_JSON\" > /tmp/fcm.json && export GOOGLE_APPLICATION_CREDENTIALS=/tmp/fcm.json ;; esac; unset FCM_SERVICE_ACCOUNT_JSON; exec java $JAVA_OPTS -jar /app/app.jar",
  ]

  spring_health = {
    path    = "/actuator/health/readiness"
    port    = 8090
    matcher = "200-399"
  }

  service_specs = {
    rest = {
      image         = "${local.ecr_registry}/moyeota/be@${var.image_digests.be}"
      task_cpu      = 1024
      task_memory   = 2048 # 컨테이너 1792 + Service Connect 프록시 여유 256
      container_mem = 1792
      entry_point   = ["sh", "-c"]
      command       = local.backend_command
      service_conn  = "client"
      stop_timeout  = var.container_stop_timeout_seconds
      anti_affinity = "websocket"
      lb            = { priority = var.listener_priorities.rest, paths = ["/api/*"], health = local.spring_health, deregistration_delay = 20 }
      grace_period  = 150
      log_stream    = "rest"
      ports         = [8080, 8090]
      secrets       = merge(local.backend_secrets, { KAFKA_BOOTSTRAP_SERVERS = aws_ssm_parameter.broker["KAFKA_BOOTSTRAP_SERVERS"].arn })
      environment = merge(local.otlp_environment, {
        APP_ROLE                                  = var.rest_app_role
        AI_BASE_URL                               = "http://fastapi:${local.services.fastapi.port}"
        JAVA_TOOL_OPTIONS                         = "-Xms128m -Xmx1024m -XX:ActiveProcessorCount=2"
        SPRING_LIFECYCLE_TIMEOUTPERSHUTDOWNPHASE  = "15s"
        MOYEOTA_TAXIPOT_MATCHING_MODE             = "kafka"
        MOYEOTA_CONGESTION_WINDOW_DEFAULT_MINUTES = "10"
      })
    }

    websocket = {
      image         = "${local.ecr_registry}/moyeota/be@${var.image_digests.be}"
      task_cpu      = 512
      task_memory   = 1024
      container_mem = 1024
      entry_point   = ["sh", "-c"]
      command       = local.backend_command
      service_conn  = null
      stop_timeout  = var.container_stop_timeout_seconds
      anti_affinity = "rest"
      # Spot 회수 예고(2분) 안에 드레이닝과 종료가 끝나도록 60초로 둔다 (V3는 120초)
      lb           = { priority = var.listener_priorities.websocket, paths = ["/api/wss"], health = local.spring_health, deregistration_delay = 60 }
      grace_period = 150
      log_stream   = "websocket"
      ports        = [8080, 8090]
      secrets      = local.backend_secrets
      environment = merge(local.otlp_environment, {
        APP_ROLE                                  = "websocket"
        JAVA_TOOL_OPTIONS                         = "-Xms128m -Xmx512m -XX:ActiveProcessorCount=2"
        MOYEOTA_CONGESTION_WINDOW_DEFAULT_MINUTES = "10"
      })
    }

    frontend = {
      image         = "${local.ecr_registry}/moyeota/fe@${var.image_digests.fe}"
      task_cpu      = 256
      task_memory   = 768
      container_mem = 768
      entry_point   = null
      command       = null
      service_conn  = null
      stop_timeout  = 30
      anti_affinity = null
      lb            = { priority = var.listener_priorities.frontend, paths = ["/*"], health = { path = "/", port = null, matcher = "200-399" }, deregistration_delay = 20 }
      grace_period  = 60
      log_stream    = "frontend"
      ports         = [3000]
      secrets       = { for k in ["SENTRY_DSN", "SENTRY_ENVIRONMENT", "SENTRY_TRACES_SAMPLE_RATE"] : k => "${local.v2_param}/frontend/${k}" }
      environment   = {}
    }

    fastapi = {
      image         = "${local.ecr_registry}/moyeota/ai@${var.image_digests.ai}"
      task_cpu      = 512
      task_memory   = 1024 # 컨테이너 768 + Service Connect 프록시 여유 256
      container_mem = 768
      entry_point   = null
      command       = null
      service_conn  = "server"
      stop_timeout  = 30
      anti_affinity = null
      lb            = null
      grace_period  = null
      log_stream    = "fastapi"
      ports         = [8000]
      # 서버 모니터링 봇 값(AI DB, Qdrant, Discord, Telegram)은 넣지 않는다. 봇은 시작에 실패해도 fastapi에 영향이 없다.
      secrets = merge(
        { for k in ["OPENAI_API_KEY_1", "OPENAI_API_KEY_2", "ANTHROPIC_API_KEY", "MODAL_TOKEN_ID_2", "MODAL_TOKEN_SECRET_2"] : k => "${local.v2_param}/ai/${k}" },
        { KAFKA_BOOTSTRAP_SERVERS = aws_ssm_parameter.broker["KAFKA_BOOTSTRAP_SERVERS"].arn },
      )
      environment = merge(local.otlp_environment, {
        LOCAL_DEVICE = "FALSE"
      })
    }
  }

  # 빈 environment/secrets 배열은 AWS가 지워서 반환해 매 plan마다 diff가 생기므로 비어 있으면 키를 뺀다
  container_definitions = {
    for name, s in local.service_specs : name => merge(
      {
        name        = name
        image       = s.image
        essential   = true
        memory      = s.container_mem
        stopTimeout = s.stop_timeout

        portMappings = [
          for p in s.ports : merge(
            { containerPort = p, hostPort = p, protocol = "tcp" },
            # 앱 포트에는 이름을 붙인다 (Service Connect 서버의 port_name)
            p == local.services[name].port ? { name = name, appProtocol = "http" } : {},
          )
        ]

        # ECS Exec 권장 설정
        linuxParameters = { initProcessEnabled = true }

        logConfiguration = {
          logDriver = "awslogs"
          options = {
            awslogs-group         = aws_cloudwatch_log_group.service[name].name
            awslogs-region        = local.region
            awslogs-stream-prefix = s.log_stream
          }
        }

        environment = [for k, v in merge({ TZ = "Asia/Seoul" }, s.environment) : { name = k, value = v }]
      },
      length(s.secrets) > 0 ? { secrets = [for k, arn in s.secrets : { name = k, valueFrom = arn }] } : {},
      s.entry_point != null ? { entryPoint = s.entry_point } : {},
      s.command != null ? { command = s.command } : {},
    )
  }

  lb_services = { for name, s in local.service_specs : name => s if s.lb != null }

  capacity_provider = aws_ecs_capacity_provider.app[var.capacity_mode].name
}

resource "aws_cloudwatch_log_group" "service" {
  for_each = local.service_specs

  name              = "/ecs/${local.cluster_name}/${each.key}"
  retention_in_days = var.log_retention_days
}

resource "aws_ecs_task_definition" "service" {
  for_each = local.service_specs

  family                   = "${local.name_prefix}-${each.key}"
  requires_compatibilities = ["EC2"]
  network_mode             = "awsvpc"
  cpu                      = tostring(each.value.task_cpu)
  memory                   = tostring(each.value.task_memory)
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task[each.key].arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([local.container_definitions[each.key]])
}

# ---------------------------------------------------------------------------
# ALB: 서비스 전용 ip Target Group + V2 prod HTTPS 리스너에 v4 규칙
#   cutover_enabled = false : 헤더 X-Moyeota-Target: v4 요청만 v4로 (테스트)
#   cutover_enabled = true  : 경로가 맞으면 모두 v4로 (전환)
#   V2 prod 규칙(priority_base 100 이후)보다 앞선 우선순위를 쓴다. V2-1 적용 전에는 V2 규칙(1·2·4)이 먼저 걸린다.
# ---------------------------------------------------------------------------

resource "aws_lb_target_group" "service" {
  for_each = local.lb_services

  name                 = "${local.name_prefix}-${each.key}"
  port                 = local.services[each.key].port
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = data.aws_vpc.shared.id
  deregistration_delay = each.value.lb.deregistration_delay

  health_check {
    enabled             = true
    path                = each.value.lb.health.path
    port                = each.value.lb.health.port == null ? "traffic-port" : tostring(each.value.lb.health.port)
    protocol            = "HTTP"
    matcher             = each.value.lb.health.matcher
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = {
    Name    = "${local.name_prefix}-${each.key}-tg"
    Service = each.key
  }
}

resource "aws_lb_listener_rule" "service" {
  for_each = local.lb_services

  listener_arn = data.aws_lb_listener.prod_https.arn
  priority     = each.value.lb.priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.service[each.key].arn
  }

  condition {
    path_pattern {
      values = each.value.lb.paths
    }
  }

  dynamic "condition" {
    for_each = var.cutover_enabled ? [] : [1]

    content {
      http_header {
        http_header_name = "X-Moyeota-Target"
        values           = ["v4"]
      }
    }
  }

  tags = {
    Name    = "${local.name_prefix}-${each.key}-rule"
    Service = each.key
  }
}

# ---------------------------------------------------------------------------
# ECS 서비스
# ---------------------------------------------------------------------------

resource "aws_ecs_service" "service" {
  for_each = local.service_specs

  name            = each.key
  cluster         = aws_ecs_cluster.this.arn
  task_definition = aws_ecs_task_definition.service[each.key].arn
  desired_count   = 1

  enable_execute_command  = true
  enable_ecs_managed_tags = true
  propagate_tags          = "SERVICE"

  # capacity_provider_strategy·placement 변경을 즉시 반영
  force_new_deployment = true

  # 레플리카 1개, 호스트 여유 없음 → 기존 태스크를 먼저 내린다 (배포마다 약 2~3분 중단)
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  health_check_grace_period_seconds = each.value.grace_period

  capacity_provider_strategy {
    capacity_provider = local.capacity_provider
    weight            = 1
    base              = 0
  }

  network_configuration {
    subnets          = [for s in aws_subnet.app : s.id]
    security_groups  = [aws_security_group.task[each.key].id]
    assign_public_ip = false
  }

  # role=shared 호스트에만. rest·websocket은 서로가 떠 있는 호스트를 피한다
  placement_constraints {
    type = "memberOf"
    expression = join(" and ", compact([
      "attribute:role == shared",
      each.value.anti_affinity == null ? "" : "not(task:group == service:${each.value.anti_affinity})",
    ]))
  }

  ordered_placement_strategy {
    type  = "binpack"
    field = "memory"
  }

  dynamic "service_connect_configuration" {
    for_each = each.value.service_conn == null ? [] : [each.value.service_conn]

    content {
      enabled   = true
      namespace = aws_service_discovery_http_namespace.this.arn

      log_configuration {
        log_driver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.service[each.key].name
          awslogs-region        = local.region
          awslogs-stream-prefix = "${each.key}-service-connect"
        }
      }

      dynamic "service" {
        for_each = service_connect_configuration.value == "server" ? [1] : []

        content {
          port_name      = each.key
          discovery_name = each.key

          client_alias {
            port     = local.services[each.key].port
            dns_name = each.key
          }
        }
      }
    }
  }

  dynamic "load_balancer" {
    for_each = each.value.lb == null ? [] : [1]

    content {
      target_group_arn = aws_lb_target_group.service[each.key].arn
      container_name   = each.key
      container_port   = local.services[each.key].port
    }
  }

  lifecycle {
    # CD(Deploy Role)가 digest로 등록한 revision을 Terraform이 되돌리지 않게 한다
    ignore_changes = [task_definition]
  }

  depends_on = [
    aws_ecs_cluster_capacity_providers.this,
    aws_lb_listener_rule.service,
    aws_iam_role_policy.task_execution_config,
  ]
}
