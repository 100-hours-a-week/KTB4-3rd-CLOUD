# =============================================================================
# Non-Prod (dev·stg) DNS · 인증서
#   - ALIAS : nonprod_dns_records에 넣은 호스트만 Non-Prod ALB로 ALIAS (V1 레코드와 충돌 방지)
#   - ACM   : nonprod_acm_certificate_create = true → dev·stg 호스트 SAN 인증서를 DNS 검증 후 HTTPS 리스너에 연결
#             nonprod_alb_certificate_arn을 직접 주면 그 값이 우선이다
#   - host-header 라우팅이므로 레코드가 없을 때는
#       curl -H "Host: stg.moyeota.com" http://<nonprod_alb_dns_name>/api/... 로 확인한다
# =============================================================================

locals {
  nonprod_hosts = distinct(concat(
    lookup(var.ecs_alb_host_headers, "dev", []),
    lookup(var.ecs_alb_host_headers, "stg", []),
  ))

  nonprod_acm_create  = var.nonprod_alb_certificate_arn == null && var.nonprod_acm_certificate_create
  nonprod_tls_enabled = var.nonprod_alb_certificate_arn != null || var.nonprod_acm_certificate_create

  nonprod_certificate_arn = (
    var.nonprod_alb_certificate_arn != null ? var.nonprod_alb_certificate_arn :
    local.nonprod_acm_create ? aws_acm_certificate_validation.nonprod[0].certificate_arn : null
  )
}

data "aws_route53_zone" "public" {
  count = var.route53_zone_name == null ? 0 : 1

  name         = var.route53_zone_name
  private_zone = false
}

resource "aws_route53_record" "nonprod_alias" {
  for_each = toset(var.nonprod_dns_records)

  zone_id = data.aws_route53_zone.public[0].zone_id
  name    = each.value
  type    = "A"

  alias {
    name                   = aws_lb.nonprod.dns_name
    zone_id                = aws_lb.nonprod.zone_id
    evaluate_target_health = false
  }
}

resource "aws_acm_certificate" "nonprod" {
  count = local.nonprod_acm_create ? 1 : 0

  domain_name               = local.nonprod_hosts[0]
  subject_alternative_names = slice(local.nonprod_hosts, 1, length(local.nonprod_hosts))
  validation_method         = "DNS"

  tags = {
    Name        = "${var.project_name}-nonprod"
    Environment = "nonprod"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# V1 인증서(dev.moyeota.com)와 검증 CNAME이 같을 수 있어 덮어쓰기를 허용한다 (ACM 검증 레코드는 계정·도메인 단위로 동일)
resource "aws_route53_record" "nonprod_cert_validation" {
  for_each = local.nonprod_acm_create ? {
    for dvo in aws_acm_certificate.nonprod[0].domain_validation_options : dvo.domain_name => {
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

resource "aws_acm_certificate_validation" "nonprod" {
  count = local.nonprod_acm_create ? 1 : 0

  certificate_arn         = aws_acm_certificate.nonprod[0].arn
  validation_record_fqdns = [for r in aws_route53_record.nonprod_cert_validation : r.fqdn]
}

# =============================================================================
# Prod DNS · 인증서
#   - ACM   : prod_acm_certificate_create = true → prod_hosts(moyeota.com) 인증서를 DNS 검증 후 Prod ALB HTTPS 리스너에 연결
#             alb_certificate_arn을 직접 주면 그 값이 우선이다
#   - ALIAS : prod_dns_records에 넣은 호스트만 Prod ALB로 ALIAS. 기본값 [] — moyeota.com은 V1 콘솔 레코드(V1 EIP)라 건드리지 않는다
#             DNS 전환(컷오버)은 CLI UPSERT로 하고, 안정화 후 import해서 넘겨받는다 (variables.tf prod_dns_records)
#   - DNS 전환 전 확인 : 인증서가 moyeota.com이므로 ALB IP로 이름을 고정해 실제 도메인 그대로 호출한다
#       curl --resolve moyeota.com:443:<Prod ALB IP> https://moyeota.com/api/...
# =============================================================================

locals {
  prod_acm_create  = var.alb_certificate_arn == null && var.prod_acm_certificate_create
  prod_tls_enabled = var.alb_certificate_arn != null || var.prod_acm_certificate_create

  prod_certificate_arn = (
    var.alb_certificate_arn != null ? var.alb_certificate_arn :
    local.prod_acm_create ? aws_acm_certificate_validation.prod[0].certificate_arn : null
  )
}

resource "aws_acm_certificate" "prod" {
  count = local.prod_acm_create ? 1 : 0

  domain_name               = var.prod_hosts[0]
  subject_alternative_names = slice(var.prod_hosts, 1, length(var.prod_hosts))
  validation_method         = "DNS"

  tags = {
    Name        = "${var.project_name}-prod"
    Environment = "prod"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# 같은 도메인의 기존 인증서(V1 등)가 있으면 검증 CNAME이 같으므로 덮어쓰기를 허용한다
resource "aws_route53_record" "prod_cert_validation" {
  for_each = local.prod_acm_create ? {
    for dvo in aws_acm_certificate.prod[0].domain_validation_options : dvo.domain_name => {
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

resource "aws_acm_certificate_validation" "prod" {
  count = local.prod_acm_create ? 1 : 0

  certificate_arn         = aws_acm_certificate.prod[0].arn
  validation_record_fqdns = [for r in aws_route53_record.prod_cert_validation : r.fqdn]
}

resource "aws_route53_record" "prod_alias" {
  for_each = toset(var.prod_dns_records)

  zone_id = data.aws_route53_zone.public[0].zone_id
  name    = each.value
  type    = "A"

  alias {
    name                   = aws_lb.public.dns_name
    zone_id                = aws_lb.public.zone_id
    evaluate_target_health = false
  }
}
