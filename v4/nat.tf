# v4 NAT 인스턴스 (설계 5.6절, V4-13). V2 NAT Gateway(월 약 $43) 대신 t4g.nano(월 약 $4.5)로 v4 서브넷의 외부 통신을 중계한다.
#   단계 1: nat_instance_enabled = true  → 인스턴스만 만든다. 경로는 그대로 V2 NAT Gateway다.
#   단계 2: nat_mode = "instance"        → v4 라우팅 테이블의 기본 경로를 NAT 인스턴스 ENI로 바꾼다.
#   롤백  : nat_mode = "v2_gateway"      → 경로만 되돌린다. V2 NAT Gateway를 지우기 전까지 쓸 수 있다.
#
#   - 라우팅은 인스턴스가 아니라 전용 ENI를 가리킨다. 자동 복구(같은 인스턴스)나 인스턴스 교체 뒤에도 ENI만 붙으면 경로가 유지된다.
#   - 공인 IP는 새 EIP다. 나가는 IP가 V2 NAT Gateway와 달라지므로 외부 허용 목록이 있으면 먼저 등록한다.
#   - 운영 접근은 SSM Session Manager. SSH·인바운드 공개 포트 없음.
#   - 공개 AMI 대신 AL2023에 iptables MASQUERADE를 직접 설정한다.

data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

locals {
  nat_instance_count = var.nat_instance_enabled ? 1 : 0
  app_subnet_cidrs   = [for s in aws_subnet.app : s.cidr_block]
}

resource "aws_security_group" "nat" {
  count = local.nat_instance_count

  name                   = "${local.name_prefix}-nat"
  description            = "v4 NAT instance: forwards traffic from v4 app subnets"
  vpc_id                 = data.aws_vpc.shared.id
  revoke_rules_on_delete = true

  ingress {
    description = "All traffic from v4 app subnets (forwarded to the internet)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = local.app_subnet_cidrs
  }

  egress {
    description = "Internet"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name_prefix}-nat-sg"
  }
}

resource "aws_network_interface" "nat" {
  count = local.nat_instance_count

  subnet_id         = data.aws_subnet.public["a"].id
  security_groups   = [aws_security_group.nat[0].id]
  source_dest_check = false
  description       = "v4 NAT instance primary ENI (route target)"

  tags = {
    Name = "${local.name_prefix}-nat-eni"
  }
}

resource "aws_eip" "nat" {
  count = local.nat_instance_count

  domain            = "vpc"
  network_interface = aws_network_interface.nat[0].id

  tags = {
    Name = "${local.name_prefix}-nat-eip"
  }
}

resource "aws_iam_role" "nat" {
  count = local.nat_instance_count

  name               = "${local.name_prefix}-nat"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "nat_ssm_core" {
  count = local.nat_instance_count

  role       = aws_iam_role.nat[0].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "nat" {
  count = local.nat_instance_count

  name = aws_iam_role.nat[0].name
  role = aws_iam_role.nat[0].name
}

resource "aws_instance" "nat" {
  count = local.nat_instance_count

  ami                  = data.aws_ssm_parameter.al2023_arm64.value
  instance_type        = var.nat_instance_type
  iam_instance_profile = aws_iam_instance_profile.nat[0].name

  primary_network_interface {
    network_interface_id = aws_network_interface.nat[0].id
  }

  user_data = templatefile("${path.module}/templates/nat/user_data.sh.tftpl", {
    source_cidrs = local.app_subnet_cidrs
  })
  user_data_replace_on_change = false

  # NAT 설정은 부팅 때 한 번 한다. AMI·user_data 변경으로 교체되지 않게 한다.
  lifecycle {
    ignore_changes = [ami, user_data]
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 8
    encrypted             = true
    delete_on_termination = true
  }

  tags = {
    Name = "${local.name_prefix}-nat"
    Role = "nat"
  }

  depends_on = [aws_eip.nat, aws_iam_role_policy_attachment.nat_ssm_core]
}

# 하드웨어(시스템 상태 검사) 장애 시 같은 인스턴스·ENI·EIP로 복구한다
resource "aws_cloudwatch_metric_alarm" "nat_recover" {
  count = local.nat_instance_count

  alarm_name          = "${local.name_prefix}-nat-system-check"
  alarm_description   = "v4 NAT instance system status check failed: auto recover"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_System"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = ["arn:${local.partition}:automate:${local.region}:ec2:recover"]

  dimensions = {
    InstanceId = aws_instance.nat[0].id
  }
}

# OS가 응답하지 않으면 재부팅한다 (iptables 규칙과 ip_forward는 부팅 때 다시 적용된다)
resource "aws_cloudwatch_metric_alarm" "nat_instance_check" {
  count = local.nat_instance_count

  alarm_name          = "${local.name_prefix}-nat-instance-check"
  alarm_description   = "v4 NAT instance status check failed: reboot"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_Instance"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = ["arn:${local.partition}:automate:${local.region}:ec2:reboot"]

  dimensions = {
    InstanceId = aws_instance.nat[0].id
  }
}
