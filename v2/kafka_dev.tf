# =============================================================================
# dev Kafka (EC2 1노드) — issues/kafka-msk-setup.md, issues/v2-kafka-compose-design.md
#
#   왜 EC2인가 : MSK는 최소 2대이고 중지할 수 없으며 kafka.t3.small도 4.1.x.kraft에서 지원하지 않는다.
#                dev는 연결·기능 확인용이라 1노드로 충분하고, 복제·브로커 장애는 stg MSK에서 확인한다.
#   구성 : 전용 EC2 + Docker compose (v2/kafka/compose.yaml), 기존 dev 호스트는 변경하지 않는다.
#          브로커 버전은 stg MSK와 같은 4.1 계열로 고정한다. 토픽은 MSK와 같은 local.msk_topics를 RF 1로 만든다.
#   접근 : 9092만, dev의 msk_client_services 태스크 SG에서만. 접속은 SSM Session Manager.
#   가동 : 기존 dev 스케줄에 포함 (09:00 시작 / 24:00 중지). private IP와 데이터는 stop/start에도 유지된다.
#   주입 : KAFKA_BOOTSTRAP_SERVERS. 실행 중인 태스크에는 다음 새 이미지 CD에서 반영된다.
#          주의: 호스트를 교체하면 IP가 바뀌므로 .env와 SSM이 달라진다 → -replace 뒤 부트스트랩 결과를 확인하고 재배포한다.
# =============================================================================

locals {
  dev_kafka_active = var.dev_kafka_enabled && contains(keys(local.ecs_stages), "dev")
  dev_kafka_port   = 9092
  dev_kafka_image  = "apache/kafka:${var.dev_kafka_version}"

  dev_kafka_client_task_sgs = local.dev_kafka_active ? {
    for k, s in local.ecs_service_instances : k => module.ecs_service[k].task_security_group_id
    if s.stage == "dev" && contains(local.msk_client_services, s.service)
  } : {}

  # ecs.tf secrets에 합친다. 스테이지 → { 환경 변수 → SSM ARN }. MSK와 dev EC2를 한 경로로 다룬다.
  kafka_secrets = merge(
    local.msk_secrets,
    { for s in(local.dev_kafka_active ? ["dev"] : []) : s => {
      KAFKA_BOOTSTRAP_SERVERS = aws_ssm_parameter.dev_kafka_bootstrap_servers[0].arn
    } },
  )
}

resource "aws_iam_role" "dev_kafka" {
  count = local.dev_kafka_active ? 1 : 0

  name                 = "${var.project_name}-dev-kafka"
  assume_role_policy   = data.aws_iam_policy_document.ec2_assume_role.json
  max_session_duration = 3600

  tags = {
    Name  = "${var.project_name}-dev-kafka-role"
    Stage = "dev"
  }
}

resource "aws_iam_instance_profile" "dev_kafka" {
  count = length(aws_iam_role.dev_kafka)

  name = "${var.project_name}-dev-kafka"
  role = aws_iam_role.dev_kafka[0].name
}

resource "aws_iam_role_policy_attachment" "dev_kafka_ssm" {
  count = length(aws_iam_role.dev_kafka)

  role       = aws_iam_role.dev_kafka[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_security_group" "dev_kafka" {
  count = local.dev_kafka_active ? 1 : 0

  name                   = "${var.project_name}-dev-kafka"
  description            = "dev Kafka host; 9092 from client task SGs only, access via SSM"
  vpc_id                 = data.aws_vpc.shared.id
  revoke_rules_on_delete = true

  egress {
    description = "Image registry and package repositories through NAT"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name  = "${var.project_name}-dev-kafka-sg"
    Stage = "dev"
  }
}

resource "aws_vpc_security_group_ingress_rule" "dev_kafka_from_clients" {
  for_each = local.dev_kafka_client_task_sgs

  security_group_id            = aws_security_group.dev_kafka[0].id
  description                  = "Kafka 9092 from ${each.key} tasks"
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = local.dev_kafka_port
  to_port                      = local.dev_kafka_port

  tags = {
    Stage = "dev"
  }
}

resource "aws_instance" "dev_kafka" {
  count = local.dev_kafka_active ? 1 : 0

  ami                         = data.aws_ssm_parameter.ubuntu_24_04_x86_64.value
  instance_type               = var.dev_kafka_instance_type
  subnet_id                   = aws_subnet.v2["dev"].id
  vpc_security_group_ids      = [aws_security_group.dev_kafka[0].id]
  iam_instance_profile        = aws_iam_instance_profile.dev_kafka[0].name
  associate_public_ip_address = false
  monitoring                  = false
  ebs_optimized               = true

  user_data = templatefile("${path.module}/templates/kafka/dev_user_data.sh.tftpl", {
    compose_b64 = filebase64("${path.module}/kafka/compose.yaml")
    topics_b64 = base64encode(templatefile("${path.module}/templates/kafka/topics.sh.tftpl", {
      topics             = local.msk_topics
      replication_factor = 1
    }))
    kafka_image = local.dev_kafka_image
  })
  user_data_replace_on_change = false

  # 토픽·오프셋이 있는 호스트라 AMI·user_data 변경으로 교체되지 않게 한다 (compute.tf host와 같은 사유).
  lifecycle {
    ignore_changes = [ami, user_data]

    precondition {
      condition     = !contains(var.msk_stages, "dev")
      error_message = "dev는 MSK와 EC2 Kafka를 함께 켤 수 없다 (같은 SSM 경로를 쓴다)."
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
    instance_metadata_tags      = "disabled"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.dev_kafka_root_gib
    iops                  = 3000
    throughput            = 125
    encrypted             = true
    delete_on_termination = true
  }

  tags = {
    Name        = "${var.project_name}-kafka-dev"
    Role        = "kafka"
    Environment = "dev"
    Stage       = "dev"
  }
}

resource "aws_ssm_parameter" "dev_kafka_bootstrap_servers" {
  count = local.dev_kafka_active ? 1 : 0

  name        = "/${var.config_path_prefix}/dev/broker/KAFKA_BOOTSTRAP_SERVERS"
  description = "dev Kafka bootstrap (Terraform 관리 — 콘솔에서 수정하지 않는다)"
  type        = "String"
  tier        = "Standard"
  value       = "${aws_instance.dev_kafka[0].private_ip}:${local.dev_kafka_port}"

  tags = {
    Stage = "dev"
    Group = "broker"
  }
}

output "dev_kafka" {
  description = "dev Kafka 호스트. 접속: aws ssm start-session --target <instance_id>. 부트스트랩 로그: /var/log/kafka-bootstrap.log"
  value = local.dev_kafka_active ? {
    instance_id = aws_instance.dev_kafka[0].id
    bootstrap   = "${aws_instance.dev_kafka[0].private_ip}:${local.dev_kafka_port}"
    image       = local.dev_kafka_image
  } : null
}
