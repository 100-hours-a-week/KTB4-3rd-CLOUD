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
    Name = "${var.project_name}-alb-sg"
    Tier = "public"
  }
}

resource "aws_security_group" "prod_instances" {
  name                   = "${var.project_name}-prod-instances"
  description            = "Prod EC2 ports reachable only from the V2 ALB"
  vpc_id                 = aws_vpc.v2.id
  revoke_rules_on_delete = true

  dynamic "ingress" {
    for_each = local.prod_ingress_ports

    content {
      description     = "Application and health-check port ${ingress.value} from ALB"
      from_port       = ingress.value
      to_port         = ingress.value
      protocol        = "tcp"
      security_groups = [aws_security_group.alb.id]
    }
  }

  egress {
    description = "Package repositories, image registries and external APIs through NAT"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.project_name}-prod-instances-sg"
    Environment = "prod"
  }
}

resource "aws_security_group" "dev_instance" {
  name                   = "${var.project_name}-dev-instance"
  description            = "Private Dev EC2 with no inbound access; use SSM Session Manager"
  vpc_id                 = aws_vpc.v2.id
  revoke_rules_on_delete = true

  egress {
    description = "Package repositories, image registries and external APIs through NAT"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.project_name}-dev-instance-sg"
    Environment = "dev"
  }
}
