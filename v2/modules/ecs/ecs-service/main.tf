# =============================================================================
# ecs-service : 애플리케이션 경계 (클러스터 안의 rest / websocket / frontend / fastapi)
#   설계 근거: issues/ecs-asg-by-cluster-service.md 3·5·7절, issues/ecs-iam-network.md 8.2,
#             issues/ECS-Task·Container-spec.md, issues/ECS-Task-Definition.md
#
#   - networkMode awsvpc → 태스크마다 ENI + 태스크 SG (<stage>-<service>-task-sg) [D8] [D10]
#   - capacity_provider_strategy + memberOf(attribute:role == <role>) + distinctInstance
#   - 서비스 전용 ip Target Group (서비스끼리 Target Group을 공유하지 않는다)
#   - 롤링 배포 min 100 / max 200 + circuit breaker rollback
#   - Service Auto Scaling(태스크) → Capacity Provider managed scaling(인스턴스) — autoscaling.tf
# =============================================================================

data "aws_region" "current" {}

locals {
  cluster_label = "${var.project_name}-${var.stage}"
  full_name     = "${local.cluster_label}-${var.name}"

  tags = merge(var.tags, {
    Stage   = var.stage
    Service = var.name
  })

  lb_enabled = var.load_balancer != null

  # ALB → 태스크로 열어야 하는 포트 (앱 포트 + 헬스체크 포트)
  alb_ingress_ports = local.lb_enabled ? toset(compact([
    tostring(var.container_port),
    var.load_balancer.health_check_port == null ? "" : tostring(var.load_balancer.health_check_port),
  ])) : toset([])

  container_ports = distinct(concat([var.container_port], var.additional_container_ports))

  # 빈 environment/secrets 배열은 AWS가 지워서 반환하므로 매 plan마다 diff가 생긴다 → 비어 있으면 키 자체를 뺀다
  container_definition = merge(
    {
      name        = var.name
      image       = var.image
      essential   = true
      cpu         = var.container_cpu
      memory      = var.container_memory
      stopTimeout = var.stop_timeout_seconds

      portMappings = [
        for p in local.container_ports : {
          containerPort = p
          hostPort      = p
          protocol      = "tcp"
        }
      ]

      # ECS Exec 권장 설정
      linuxParameters = {
        initProcessEnabled = true
      }

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.this.name
          awslogs-region        = data.aws_region.current.region
          awslogs-stream-prefix = var.name
        }
      }
    },
    { for k, v in { environment = [for name, value in var.environment : { name = name, value = value }] } : k => v if length(var.environment) > 0 },
    { for k, v in { secrets = [for name, arn in var.secrets : { name = name, valueFrom = arn }] } : k => v if length(var.secrets) > 0 },
  )
}

# -----------------------------------------------------------------------------
# 로그
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${local.cluster_label}/${var.name}"
  retention_in_days = var.log_retention_days
  tags              = local.tags
}

# -----------------------------------------------------------------------------
# 태스크 보안 그룹: <stage>-<service>-task-sg
#   MySQL·Redis SG는 rest/websocket 태스크 SG만 허용한다 (frontend가 뚫려도 DB 경로 없음)
# -----------------------------------------------------------------------------

resource "aws_security_group" "task" {
  name                   = "${local.full_name}-task"
  description            = "ECS tasks of ${var.name} in ${local.cluster_label}"
  vpc_id                 = var.vpc_id
  revoke_rules_on_delete = true

  tags = merge(local.tags, {
    Name = "${local.full_name}-task-sg"
  })
}

resource "aws_vpc_security_group_ingress_rule" "from_alb" {
  for_each = local.alb_ingress_ports

  security_group_id            = aws_security_group.task.id
  description                  = "Port ${each.value} from ALB"
  referenced_security_group_id = var.load_balancer.alb_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = tonumber(each.value)
  to_port                      = tonumber(each.value)
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.task.id
  description       = "ECR, SSM, data tier and external APIs"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# -----------------------------------------------------------------------------
# Task Definition (부트스트랩 revision)
# -----------------------------------------------------------------------------

resource "aws_ecs_task_definition" "this" {
  family                   = local.full_name
  requires_compatibilities = ["EC2"]
  network_mode             = "awsvpc"
  cpu                      = tostring(var.task_cpu)
  memory                   = tostring(var.task_memory)
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = var.task_role_arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([local.container_definition])

  tags = local.tags
}

# -----------------------------------------------------------------------------
# ALB: 서비스 전용 ip Target Group + Listener Rule
# -----------------------------------------------------------------------------

resource "aws_lb_target_group" "this" {
  count = local.lb_enabled ? 1 : 0

  name                 = local.full_name
  port                 = var.container_port
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = var.vpc_id
  deregistration_delay = var.load_balancer.deregistration_delay

  health_check {
    enabled             = true
    path                = var.load_balancer.health_check_path
    port                = var.load_balancer.health_check_port == null ? "traffic-port" : tostring(var.load_balancer.health_check_port)
    protocol            = "HTTP"
    matcher             = var.load_balancer.health_check_matcher
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = merge(local.tags, {
    Name = "${local.full_name}-tg"
  })
}

resource "aws_lb_listener_rule" "this" {
  count = local.lb_enabled ? 1 : 0

  listener_arn = var.load_balancer.listener_arn
  priority     = var.load_balancer.priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this[0].arn
  }

  condition {
    path_pattern {
      values = var.load_balancer.path_patterns
    }
  }

  dynamic "condition" {
    for_each = length(var.load_balancer.host_headers) > 0 ? [var.load_balancer.host_headers] : []

    content {
      host_header {
        values = condition.value
      }
    }
  }

  dynamic "condition" {
    for_each = var.load_balancer.http_headers

    content {
      http_header {
        http_header_name = condition.key
        values           = condition.value
      }
    }
  }

  tags = merge(local.tags, {
    Name = "${local.full_name}-rule"
  })
}

# -----------------------------------------------------------------------------
# ECS Service
# -----------------------------------------------------------------------------

resource "aws_ecs_service" "this" {
  name            = var.name
  cluster         = var.cluster_arn
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = var.desired_count

  enable_execute_command  = var.enable_execute_command
  enable_ecs_managed_tags = true
  propagate_tags          = "SERVICE"

  # capacity_provider_strategy·placement 변경을 즉시 반영
  force_new_deployment = true

  deployment_minimum_healthy_percent = var.deployment_minimum_healthy_percent
  deployment_maximum_percent         = var.deployment_maximum_percent

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  health_check_grace_period_seconds = local.lb_enabled ? var.health_check_grace_period_seconds : null

  dynamic "capacity_provider_strategy" {
    for_each = var.capacity_provider_strategy

    content {
      capacity_provider = capacity_provider_strategy.value.capacity_provider
      base              = capacity_provider_strategy.value.base
      weight            = capacity_provider_strategy.value.weight
    }
  }

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [aws_security_group.task.id]
    assign_public_ip = false
  }

  dynamic "placement_constraints" {
    for_each = var.placement_role == null ? [] : [var.placement_role]

    content {
      type       = "memberOf"
      expression = "attribute:role == ${placement_constraints.value}"
    }
  }

  dynamic "placement_constraints" {
    for_each = var.distinct_instance ? [1] : []

    content {
      type = "distinctInstance"
    }
  }

  dynamic "ordered_placement_strategy" {
    for_each = var.placement_strategies

    content {
      type  = ordered_placement_strategy.value.type
      field = ordered_placement_strategy.value.field
    }
  }

  dynamic "load_balancer" {
    for_each = local.lb_enabled ? [1] : []

    content {
      target_group_arn = aws_lb_target_group.this[0].arn
      container_name   = var.name
      container_port   = var.container_port
    }
  }

  tags = local.tags

  lifecycle {
    # task_definition : CI(Deploy Role)가 digest로 등록한 revision을 Terraform이 되돌리지 않게
    # desired_count   : Service Auto Scaling이 관리
    ignore_changes = [task_definition, desired_count]
  }

  depends_on = [aws_lb_listener_rule.this]
}
