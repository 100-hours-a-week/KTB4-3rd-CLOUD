# EKS 파드용 Target Group. 파드 등록은 TargetGroupBinding이 맡는다.
locals {
  target_services = {
    rest      = { port = 8080, health_path = "/actuator/health/readiness", health_port = "8090", deregistration_delay = 20 }
    websocket = { port = 8080, health_path = "/actuator/health/readiness", health_port = "8090", deregistration_delay = 120 }
    frontend  = { port = 3000, health_path = "/", health_port = "traffic-port", deregistration_delay = 20 }
  }

  stage_targets = merge([
    for stage in keys(var.stages) : {
      for service, spec in local.target_services : "${stage}-${service}" => merge(spec, { stage = stage, service = service })
    }
  ]...)

  # stg 검증 규칙. 기존 ECS 규칙(200~)보다 먼저 평가되고, 헤더가 있는 요청만 EKS로 보낸다.
  stg_test_routes = {
    websocket = { priority = 197, path = "/api/wss" }
    rest      = { priority = 198, path = "/api/*" }
    frontend  = { priority = 199, path = "/*" }
  }

  dev_test_routes = {
    websocket = { priority = 297, path = "/api/wss" }
    rest      = { priority = 298, path = "/api/*" }
    frontend  = { priority = 299, path = "/*" }
  }
}

resource "aws_lb_target_group" "eks" {
  for_each = local.stage_targets

  name                 = "${local.name_prefix}-eks-${each.key}"
  port                 = each.value.port
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = data.aws_vpc.shared.id
  deregistration_delay = each.value.deregistration_delay

  # 이름을 바꿀 때 ALB 규칙이 새 Target Group으로 옮겨 간 뒤에 이전 것을 지운다.
  lifecycle {
    create_before_destroy = true
  }

  health_check {
    enabled             = true
    path                = each.value.health_path
    port                = each.value.health_port
    protocol            = "HTTP"
    matcher             = "200-399"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = {
    Name    = "${local.name_prefix}-eks-${each.key}-tg"
    Stage   = each.value.stage
    Service = each.value.service
  }
}

data "aws_lb" "nonprod" {
  name = "${var.project_name}-nonprod-alb"
}

data "aws_lb_listener" "nonprod_https" {
  load_balancer_arn = data.aws_lb.nonprod.arn
  port              = 443
}

resource "aws_lb_listener_rule" "stg_test" {
  for_each = local.stg_test_routes

  listener_arn = data.aws_lb_listener.nonprod_https.arn
  priority     = each.value.priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.eks["stg-${each.key}"].arn
  }

  condition {
    host_header {
      values = ["stg.moyeota.com"]
    }
  }

  condition {
    path_pattern {
      values = [each.value.path]
    }
  }

  condition {
    http_header {
      http_header_name = "X-Moyeota-Target"
      values           = ["eks"]
    }
  }
}

# dev 검증 규칙. 기존 ECS 규칙(300~)보다 먼저 평가되고, 헤더가 있는 요청만 EKS로 보낸다.
resource "aws_lb_listener_rule" "dev_test" {
  for_each = local.dev_test_routes

  listener_arn = data.aws_lb_listener.nonprod_https.arn
  priority     = each.value.priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.eks["dev-${each.key}"].arn
  }

  condition {
    host_header {
      values = ["dev.moyeota.com"]
    }
  }

  condition {
    path_pattern {
      values = [each.value.path]
    }
  }

  condition {
    http_header {
      http_header_name = "X-Moyeota-Target"
      values           = ["eks"]
    }
  }
}

output "target_group_arns" {
  description = "TargetGroupBinding에 넣을 값"
  value       = { for k, tg in aws_lb_target_group.eks : k => tg.arn }
}

# next에서 frontend로 되돌렸다. 주소를 옮겨 ALB 규칙을 유지하고, 새 Target Group으로 옮겨 간 뒤에 이전 것을 지운다.

moved {
  from = aws_lb_target_group.eks["dev-next"]
  to   = aws_lb_target_group.eks["dev-frontend"]
}

moved {
  from = aws_lb_target_group.eks["stg-next"]
  to   = aws_lb_target_group.eks["stg-frontend"]
}

moved {
  from = aws_lb_target_group.eks["prod-next"]
  to   = aws_lb_target_group.eks["prod-frontend"]
}

moved {
  from = aws_lb_listener_rule.stg_test["next"]
  to   = aws_lb_listener_rule.stg_test["frontend"]
}

moved {
  from = aws_lb_listener_rule.dev_test["next"]
  to   = aws_lb_listener_rule.dev_test["frontend"]
}

moved {
  from = aws_cloudwatch_metric_alarm.prod_5xx_ratio["next"]
  to   = aws_cloudwatch_metric_alarm.prod_5xx_ratio["frontend"]
}
