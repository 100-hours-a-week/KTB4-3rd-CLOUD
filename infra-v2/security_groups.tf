resource "aws_security_group" "alb" {
  name                   = "${var.project_name}-alb"
  description            = "Internet-facing V2 application load balancer"
  vpc_id                 = aws_vpc.v2.id
  revoke_rules_on_delete = true

  dynamic "ingress" {
    for_each = var.alb_cloudfront_prefix_list_id == null ? var.alb_ingress_cidrs : []

    content {
      description = "HTTP from ${ingress.value}"
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }

  dynamic "ingress" {
    for_each = var.alb_cloudfront_prefix_list_id == null ? [] : [var.alb_cloudfront_prefix_list_id]

    content {
      description     = "HTTP from CloudFront origin-facing addresses"
      from_port       = 80
      to_port         = 80
      protocol        = "tcp"
      prefix_list_ids = [ingress.value]
    }
  }

  dynamic "ingress" {
    for_each = var.alb_certificate_arn == null ? [] : var.alb_ingress_cidrs
    for_each = var.alb_certificate_arn == null || var.alb_cloudfront_prefix_list_id != null ? [] : var.alb_ingress_cidrs

    content {
      description = "HTTPS from ${ingress.value}"
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }

  dynamic "ingress" {
    for_each = var.alb_certificate_arn == null || var.alb_cloudfront_prefix_list_id == null ? [] : [var.alb_cloudfront_prefix_list_id]

    content {
      description     = "HTTPS from CloudFront origin-facing addresses"
      from_port       = 443
      to_port         = 443
      protocol        = "tcp"
      prefix_list_ids = [ingress.value]
    }
  }

  egress {
    description = "ALB health checks and application traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {