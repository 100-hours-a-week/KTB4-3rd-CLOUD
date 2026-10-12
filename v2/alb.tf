resource "aws_lb" "public" {
  name                             = "${var.project_name}-alb"
  internal                         = false
  load_balancer_type               = "application"
  ip_address_type                  = "ipv4"
  security_groups                  = [aws_security_group.alb.id]
  subnets                          = [aws_subnet.v2["public_a"].id, aws_subnet.v2["public_b"].id]
  enable_cross_zone_load_balancing = true
  enable_http2                     = true
  drop_invalid_header_fields       = true
  idle_timeout                     = var.alb_idle_timeout_seconds

  tags = {
    Name = "${var.project_name}-alb"
    Tier = "public"
  }
}

resource "aws_lb_target_group" "service" {
  for_each = local.target_groups

  name        = "${var.project_name}-${each.key}"
  port        = each.value.port
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = data.aws_vpc.shared.id

  health_check {
    enabled             = true
    healthy_threshold   = 2
    interval            = 30
    matcher             = each.value.health_matcher
    path                = each.value.health_path
    port                = tostring(each.value.health_port)
    protocol            = "HTTP"
    timeout             = 5
    unhealthy_threshold = 3
  }

  tags = {
    Name    = "${var.project_name}-${each.key}-tg"
    Service = each.key
  }
}

resource "aws_lb_target_group_attachment" "service" {
  for_each = local.target_groups

  target_group_arn = aws_lb_target_group.service[each.key].arn
  target_id        = aws_instance.host[each.value.host_key].id
  port             = each.value.port
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.public.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = var.alb_certificate_arn == null ? "forward" : "redirect"

    target_group_arn = var.alb_certificate_arn == null ? aws_lb_target_group.service["frontend"].arn : null

    dynamic "redirect" {
      for_each = var.alb_certificate_arn == null ? [] : [true]

      content {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  }
}

resource "aws_lb_listener" "https" {
  count = var.alb_certificate_arn == null ? 0 : 1

  load_balancer_arn = aws_lb.public.arn
  port              = 443
  protocol          = "HTTPS"
  certificate_arn   = var.alb_certificate_arn
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.service["frontend"].arn
  }
}

resource "aws_lb_listener_rule" "http_service_routes" {
  for_each = var.alb_certificate_arn == null ? local.path_routes : {}

  listener_arn = aws_lb_listener.http.arn
  priority     = each.value.priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.service[each.value.target_group].arn
  }

  condition {
    path_pattern {
      values = each.value.path_patterns
    }
  }
}

resource "aws_lb_listener_rule" "https_service_routes" {
  for_each = var.alb_certificate_arn == null ? {} : local.path_routes

  listener_arn = aws_lb_listener.https[0].arn
  priority     = each.value.priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.service[each.value.target_group].arn
  }

  condition {
    path_pattern {
      values = each.value.path_patterns
    }
  }
}

# -----------------------------------------------------------------------------
# Non-Prod ALB (dev·stg)
#   설계: issues/ecs-alb-multi-target-groups.md 8절 (선택지 B), issues/ecs-network-topology.md 4.5
#   - dev·stg ECS 서비스가 이 ALB 하나를 공유하고, Listener Rule의 host-header
#     (dev.moyeota.com / stg.moyeota.com)로 스테이지를 나눈다 → locals.tf ecs_alb_routing
#   - 어느 규칙에도 맞지 않는 요청은 404로 끝낸다 (기본 대상 Target Group 없음)
#   - Prod ALB(aws_lb.public)와 분리돼 있어 Prod 리스너 규칙·SG 변경이 dev·stg 작업과 섞이지 않는다
# -----------------------------------------------------------------------------

resource "aws_lb" "nonprod" {
  name                             = "${var.project_name}-nonprod-alb"
  internal                         = false
  load_balancer_type               = "application"
  ip_address_type                  = "ipv4"
  security_groups                  = [aws_security_group.nonprod_alb.id]
  subnets                          = [aws_subnet.v2["public_a"].id, aws_subnet.v2["public_b"].id]
  enable_cross_zone_load_balancing = true
  enable_http2                     = true
  drop_invalid_header_fields       = true
  idle_timeout                     = var.alb_idle_timeout_seconds

  tags = {
    Name        = "${var.project_name}-nonprod-alb"
    Tier        = "public"
    Environment = "nonprod"
  }
}

resource "aws_lb_listener" "nonprod_http" {
  load_balancer_arn = aws_lb.nonprod.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = local.nonprod_tls_enabled ? "redirect" : "fixed-response"

    dynamic "fixed_response" {
      for_each = local.nonprod_tls_enabled ? [] : [true]

      content {
        content_type = "text/plain"
        message_body = "Not Found"
        status_code  = "404"
      }
    }

    dynamic "redirect" {
      for_each = local.nonprod_tls_enabled ? [true] : []

      content {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  }
}

resource "aws_lb_listener" "nonprod_https" {
  count = local.nonprod_tls_enabled ? 1 : 0

  load_balancer_arn = aws_lb.nonprod.arn
  port              = 443
  protocol          = "HTTPS"
  certificate_arn   = local.nonprod_certificate_arn
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"

  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "Not Found"
      status_code  = "404"
    }
  }
}
