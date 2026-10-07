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
  vpc_id      = aws_vpc.v2.id

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
