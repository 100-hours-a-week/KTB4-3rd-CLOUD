# V2가 소유하는 공유 리소스. 이 root는 data source로 읽기만 하고 수정하지 않는다 (설계 4절 책임 경계).
# v4가 추가하는 것은 v4 소유 리소스(SG 인바운드 규칙, 리스너 규칙, TG)뿐이다.

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_vpc" "shared" {
  id = var.vpc_id
}

data "aws_subnet" "public" {
  for_each = toset(["a", "b"])

  vpc_id = data.aws_vpc.shared.id
  filter {
    name   = "tag:Name"
    values = ["${var.v2_project_name}-public-${each.key}"]
  }
}

# 전환 직후 v4 private 서브넷의 기본 경로. NAT 인스턴스로 바꾸기 전까지 쓴다 (설계 5.6절).
data "aws_nat_gateway" "v2" {
  vpc_id = data.aws_vpc.shared.id
  state  = "available"
  filter {
    name   = "tag:Name"
    values = ["${var.v2_project_name}-nat-a"]
  }
}

data "aws_vpc_endpoint" "s3" {
  vpc_id       = data.aws_vpc.shared.id
  service_name = "com.amazonaws.${var.aws_region}.s3"
}

# prod ALB와 HTTPS 리스너. v4는 이 리스너에 자기 규칙을 추가한다 (설계 5.10절).
data "aws_lb" "prod" {
  name = "${var.v2_project_name}-alb"
}

data "aws_lb_listener" "prod_https" {
  load_balancer_arn = data.aws_lb.prod.arn
  port              = 443
}

data "aws_db_instance" "prod" {
  db_instance_identifier = "${var.v2_project_name}-prod"
}

# v4가 인바운드 규칙을 추가하는 V2 SG
data "aws_security_group" "v2" {
  for_each = {
    alb        = "${var.v2_project_name}-alb"
    rds        = "${var.v2_project_name}-prod-rds"
    monitoring = "${var.v2_project_name}-monitoring"
  }

  name   = each.value
  vpc_id = data.aws_vpc.shared.id
}

# V2 모니터링 EC2 (Grafana, Prometheus, Loki). Alloy 로그와 앱 OTLP 지표의 목적지다.
data "aws_instance" "monitoring" {
  filter {
    name   = "tag:Name"
    values = ["${var.v2_project_name}-monitoring"]
  }

  filter {
    name   = "instance-state-name"
    values = ["running"]
  }
}

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

data "aws_s3_bucket" "images" {
  bucket = var.images_bucket
}
