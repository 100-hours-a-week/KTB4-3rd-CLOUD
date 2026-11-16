# v4 데이터 호스트: Kafka(KRaft 단일 노드) · MongoDB · Redis를 EC2 1대의 컨테이너로 운영한다 (설계 5.4절).
#   위치   : v4 app 서브넷 2a, 고정 사설 IP. 접속 정보가 바뀌지 않아 Kafka·Redis 값은 Terraform이 SSM에 직접 쓴다.
#   구매   : On-Demand 고정. 단일 인스턴스에 데이터가 있으므로 Spot으로 바꾸지 않는다.
#   디스크 : 루트 EBS + 데이터 EBS(/mnt/data). Kafka 로그와 MongoDB 데이터를 둔다. Redis는 디스크에 저장하지 않는다.
#   비밀값 : MongoDB 비밀번호와 URI는 호스트가 부팅 시 만들어 SSM에 직접 쓴다. Terraform state에 남지 않는다.
#   운영   : 컨테이너 구성은 /usr/local/bin/data-host-apply 하나로 맞춘다. 다시 실행해도 된다 (SSM Run Command).
#   참고   : v2/kafka_dev.tf, v2/templates/kafka/*, v3/eks/mongodb.tf, v3/eks/templates/mongodb/*
#
# MongoDB 8.0은 Linux 커널 6.19 이상에서 시작을 거부하므로 커널이 고정된 AL2023을 쓴다 (v3/eks/mongodb.tf와 같은 사유).

data "aws_ssm_parameter" "al2023_kernel_6_12" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.12-x86_64"
}

locals {
  data_host_private_ip = cidrhost(aws_subnet.app["a"].cidr_block, var.data_host_ip_offset)

  kafka_port = 9092
  mongo_port = 27017
  redis_port = 6379

  kafka_retention_1day = 86400000
  kafka_retention_7day = 604800000

  # V2 local.msk_topics와 같은 목록이다. 단일 브로커라 RF 1로 만든다.
  # 매칭 Streams의 내부 토픽(changelog, repartition)은 Streams가 직접 만든다.
  kafka_topics = concat(
    [
      for name, retention in {
        "matching.request"                  = local.kafka_retention_1day
        "matching.decision"                 = local.kafka_retention_1day
        "community.post.changed"            = local.kafka_retention_7day
        "congestion.analysis.result"        = local.kafka_retention_1day
        "notification.push.request"         = local.kafka_retention_1day
        "notification.bulk-push.request"    = local.kafka_retention_1day
        "settlement.image-analysis.request" = local.kafka_retention_1day
        "settlement.image-analysis.result"  = local.kafka_retention_1day
        "companion.changed"                 = local.kafka_retention_7day
        "settlement.changed"                = local.kafka_retention_7day
      } : { name = name, partitions = 6, config = "retention.ms=${retention}" }
    ],
    [{ name = "congestion.analysis.request", partitions = 6, config = "retention.ms=${local.kafka_retention_1day},max.message.bytes=4194304" }],
    [
      for name in [
        "matching.decision",
        "community.post.changed",
        "congestion.analysis.result",
        "notification.push.request",
        "notification.bulk-push.request",
        "settlement.image-analysis.request",
        "settlement.image-analysis.result",
        "companion.changed",
        "settlement.changed",
      ] : { name = "${name}-dlt", partitions = 1, config = "retention.ms=${local.kafka_retention_7day}" }
    ],
    [{ name = "congestion.analysis.request-dlt", partitions = 1, config = "retention.ms=${local.kafka_retention_7day},max.message.bytes=4194304" }],
  )

  data_host_snapshot_tag = "${local.name_prefix}-data-host"
}

# ---------------------------------------------------------------------------
# IAM
# ---------------------------------------------------------------------------

resource "aws_iam_role" "data_host" {
  name               = "${local.name_prefix}-data-host"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "data_host_ssm_core" {
  role       = aws_iam_role.data_host.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "data_host_params" {
  statement {
    sid       = "ManageMongoParameters"
    actions   = ["ssm:GetParameter", "ssm:PutParameter"]
    resources = [for p in aws_ssm_parameter.mongo : p.arn]
  }

  statement {
    sid       = "UseSsmKey"
    actions   = ["kms:Decrypt", "kms:Encrypt"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${local.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "data_host_params" {
  name   = "manage-mongo-parameters"
  role   = aws_iam_role.data_host.id
  policy = data.aws_iam_policy_document.data_host_params.json
}

resource "aws_iam_instance_profile" "data_host" {
  name = aws_iam_role.data_host.name
  role = aws_iam_role.data_host.name
}

# ---------------------------------------------------------------------------
# 인스턴스와 데이터 EBS
# ---------------------------------------------------------------------------

resource "aws_instance" "data_host" {
  ami                         = data.aws_ssm_parameter.al2023_kernel_6_12.value
  instance_type               = var.data_host_instance_type
  subnet_id                   = aws_subnet.app["a"].id
  private_ip                  = local.data_host_private_ip
  vpc_security_group_ids      = [aws_security_group.data_host.id]
  iam_instance_profile        = aws_iam_instance_profile.data_host.name
  associate_public_ip_address = false
  ebs_optimized               = true

  # 안쪽 스크립트는 gzip+base64로 넣는다. user_data 한도(16KB)를 넘지 않게 한다.
  user_data = templatefile("${path.module}/templates/data-host/user_data.sh.tftpl", {
    apply_b64 = base64gzip(templatefile("${path.module}/templates/data-host/data-host-apply.sh.tftpl", {
      aws_region          = var.aws_region
      private_ip          = local.data_host_private_ip
      kafka_image         = var.data_host_images.kafka
      mongo_image         = var.data_host_images.mongo
      redis_image         = var.data_host_images.redis
      kafka_port          = local.kafka_port
      mongo_port          = local.mongo_port
      redis_port          = local.redis_port
      root_password_param = aws_ssm_parameter.mongo["root_password"].name
      app_password_param  = aws_ssm_parameter.mongo["app_password"].name
      uri_param           = aws_ssm_parameter.mongo["uri"].name
    }))
    topics_b64 = base64gzip(templatefile("${path.module}/templates/data-host/topics.sh.tftpl", {
      topics             = local.kafka_topics
      replication_factor = 1
    }))
  })
  user_data_replace_on_change = false

  # 데이터 호스트라서 AMI·user_data 변경으로 교체되지 않게 한다. 구성 변경은 data-host-apply로 반영한다.
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
    volume_size           = 20
    encrypted             = true
    delete_on_termination = true
  }

  tags = {
    Name = "${local.name_prefix}-data-host"
    Role = "data-host"
  }

  # user_data가 부팅 중 파라미터를 읽고 쓰므로 권한과 파라미터가 먼저 있어야 한다.
  depends_on = [
    aws_iam_role_policy.data_host_params,
    aws_iam_role_policy_attachment.data_host_ssm_core,
    aws_route_table_association.app,
  ]
}

resource "aws_ebs_volume" "data_host" {
  # 인스턴스를 교체해도 볼륨이 유지되도록 서브넷의 AZ를 쓴다.
  availability_zone = aws_subnet.app["a"].availability_zone
  type              = "gp3"
  size              = var.data_host_data_gib
  encrypted         = true

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name      = "${local.name_prefix}-data-host-data"
    DataClass = "persistent"
    Snapshot  = local.data_host_snapshot_tag
  }
}

resource "aws_volume_attachment" "data_host" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data_host.id
  instance_id = aws_instance.data_host.id
}

# ---------------------------------------------------------------------------
# 일일 스냅샷 (DLM)
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "dlm_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["dlm.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "data_host_dlm" {
  name               = "${local.name_prefix}-data-host-dlm"
  assume_role_policy = data.aws_iam_policy_document.dlm_assume.json
}

resource "aws_iam_role_policy_attachment" "data_host_dlm" {
  role       = aws_iam_role.data_host_dlm.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

resource "aws_dlm_lifecycle_policy" "data_host" {
  description        = "v4 data host data volume daily snapshot"
  execution_role_arn = aws_iam_role.data_host_dlm.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]
    target_tags    = { Snapshot = local.data_host_snapshot_tag }

    schedule {
      name = "daily"

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["18:00"] # 03:00 KST
      }

      retain_rule {
        count = var.data_host_snapshot_retain_days
      }

      copy_tags = true
    }
  }

  depends_on = [aws_iam_role_policy_attachment.data_host_dlm]
}

# ---------------------------------------------------------------------------
# 자동 복구: 하드웨어(시스템 상태 검사) 장애 시 같은 인스턴스·IP·EBS로 복구한다
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "data_host_recover" {
  alarm_name          = "${local.name_prefix}-data-host-system-check"
  alarm_description   = "v4 data host system status check failed: auto recover"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_System"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = ["arn:${local.partition}:automate:${local.region}:ec2:recover"]

  dimensions = {
    InstanceId = aws_instance.data_host.id
  }
}
