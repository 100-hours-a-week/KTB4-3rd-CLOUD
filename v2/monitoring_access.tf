# =============================================================================
# Grafana 접근 — Non-Prod ALB 호스트 규칙 (monitor.moyeota.com)
#   팀원 → Non-Prod ALB(팀 CIDR만 허용) → 모니터링 호스트 :3000 → Grafana 로그인
#   - 모니터링 호스트는 private 서브넷에 그대로 두고 ALB만 앞에 선다 (공인 IP 없음)
#   - HTTPS 리스너가 있으면 HTTPS 규칙, 없으면 HTTP 규칙 (HTTP 리스너는 TLS가 켜지면 443으로 리다이렉트만 한다)
#   - monitoring_grafana_host가 null이면 SSM 포트 포워딩(output monitoring.grafana_forward)으로만 접속한다
# =============================================================================

locals {
  grafana_access_enabled = local.monitoring_enabled && var.monitoring_grafana_host != null
  grafana_root_url       = var.monitoring_grafana_host == null ? "" : "${local.nonprod_tls_enabled ? "https" : "http"}://${var.monitoring_grafana_host}"
  grafana_listener_arn   = local.nonprod_tls_enabled ? try(aws_lb_listener.nonprod_https[0].arn, null) : aws_lb_listener.nonprod_http.arn
}

resource "aws_lb_target_group" "grafana" {
  count = local.grafana_access_enabled ? 1 : 0

  name        = "${var.project_name}-grafana"
  port        = 3000
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = data.aws_vpc.shared.id

  health_check {
    enabled             = true
    path                = "/api/health"
    port                = "traffic-port"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = {
    Name = "${var.project_name}-grafana-tg"
  }
}

resource "aws_lb_target_group_attachment" "grafana" {
  count = local.grafana_access_enabled ? 1 : 0

  target_group_arn = aws_lb_target_group.grafana[0].arn
  target_id        = module.monitoring[0].instance_id
  port             = 3000
}

resource "aws_lb_listener_rule" "grafana" {
  count = local.grafana_access_enabled ? 1 : 0

  listener_arn = local.grafana_listener_arn
  priority     = var.monitoring_grafana_listener_priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.grafana[0].arn
  }

  condition {
    host_header {
      values = [var.monitoring_grafana_host]
    }
  }

  tags = {
    Name = "${var.project_name}-grafana-rule"
  }
}

resource "aws_vpc_security_group_ingress_rule" "monitoring_grafana_from_nonprod_alb" {
  count = local.grafana_access_enabled ? 1 : 0

  security_group_id            = aws_security_group.monitoring[0].id
  description                  = "Grafana from Non-Prod ALB"
  referenced_security_group_id = aws_security_group.nonprod_alb.id
  ip_protocol                  = "tcp"
  from_port                    = 3000
  to_port                      = 3000
}

# DNS: monitor.moyeota.com → Non-Prod ALB
resource "aws_route53_record" "grafana" {
  count = local.grafana_access_enabled && var.monitoring_grafana_dns_record ? 1 : 0

  zone_id = data.aws_route53_zone.public[0].zone_id
  name    = var.monitoring_grafana_host
  type    = "A"

  alias {
    name                   = aws_lb.nonprod.dns_name
    zone_id                = aws_lb.nonprod.zone_id
    evaluate_target_health = false
  }
}

# 인증서: monitor 전용 인증서를 HTTPS 리스너에 추가 인증서(SNI)로 붙인다 (기존 dev·stg 인증서는 그대로)
resource "aws_acm_certificate" "grafana" {
  count = local.grafana_access_enabled && var.monitoring_grafana_certificate_create ? 1 : 0

  domain_name       = var.monitoring_grafana_host
  validation_method = "DNS"

  tags = {
    Name        = "${var.project_name}-grafana"
    Environment = "monitoring"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "grafana_cert_validation" {
  for_each = local.grafana_access_enabled && var.monitoring_grafana_certificate_create ? {
    for dvo in aws_acm_certificate.grafana[0].domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  } : {}

  zone_id         = data.aws_route53_zone.public[0].zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "grafana" {
  count = local.grafana_access_enabled && var.monitoring_grafana_certificate_create ? 1 : 0

  certificate_arn         = aws_acm_certificate.grafana[0].arn
  validation_record_fqdns = [for r in aws_route53_record.grafana_cert_validation : r.fqdn]
}

resource "aws_lb_listener_certificate" "grafana" {
  count = local.grafana_access_enabled && var.monitoring_grafana_certificate_create ? 1 : 0

  listener_arn    = aws_lb_listener.nonprod_https[0].arn
  certificate_arn = aws_acm_certificate_validation.grafana[0].certificate_arn
}
