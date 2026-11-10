# stg MongoDB (혼잡도: 2dsphere·시계열+TTL). DocumentDB는 시계열 컬렉션을 지원하지 않아 직접 운영한다.
#   구성 : 단일 EC2 + Docker + 별도 EBS. v2/qdrant.tf와 같은 방식이다.
#   위치 : NAT 경로가 필요해(이미지 pull, SSM) non-prod 서브넷 dev-a에 둔다. prod 데이터는 데이터 서브넷에 둔다.
#   접근 : TCP 27017만, stg 노드 SG에서만. 퍼블릭 IP·SSH 없음 (접속은 SSM Session Manager).
#   비밀값 : 호스트가 부팅 시 생성해 SSM에 직접 쓴다. Terraform state와 운영자 화면에 값이 남지 않는다.
#   백업 : EBS 일일 스냅샷 14일.
# MongoDB 8.0은 Linux 커널 6.19 이상에서 시작을 거부한다. 최신 Ubuntu AMI는 이 조건에 걸리므로 커널이 고정된 AL2023을 쓴다.
data "aws_ssm_parameter" "al2023_kernel_6_12" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.12-x86_64"
}

locals {
  mongodb_stage        = "stg"
  mongodb_image        = "mongo:8.0" # dev(v2/dev-db/compose.db.yaml)와 같은 버전
  mongodb_param_prefix = "/moyeota/v2/${local.mongodb_stage}"
  mongodb_params = {
    uri           = "${local.mongodb_param_prefix}/backend/MONGODB_URI"
    root_password = "${local.mongodb_param_prefix}/mongo/ROOT_PASSWORD"
    app_password  = "${local.mongodb_param_prefix}/mongo/APP_PASSWORD"
  }
}

# 값은 호스트의 mongodb-apply가 채운다. 이후 값 변경을 Terraform이 되돌리지 않는다.
resource "aws_ssm_parameter" "mongodb" {
  for_each = local.mongodb_params

  name  = each.value
  type  = "SecureString"
  tier  = "Standard"
  value = "CHANGE_ME"

  lifecycle {
    ignore_changes = [value]
  }

  tags = {
    Stage = local.mongodb_stage
    Group = "mongodb"
  }
}

resource "aws_security_group" "mongodb" {
  name                   = "${local.name_prefix}-${local.mongodb_stage}-mongodb"
  description            = "stg MongoDB host"
  vpc_id                 = data.aws_vpc.shared.id
  revoke_rules_on_delete = true

  egress {
    description = "Image registry and AWS APIs"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name_prefix}-${local.mongodb_stage}-mongodb-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "mongodb_from_stg_nodes" {
  security_group_id            = aws_security_group.mongodb.id
  description                  = "MongoDB from EKS stg nodes"
  referenced_security_group_id = aws_security_group.node["stg"].id
  ip_protocol                  = "tcp"
  from_port                    = 27017
  to_port                      = 27017
}

data "aws_iam_policy_document" "mongodb_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "mongodb_params" {
  statement {
    sid       = "ManageOwnParameters"
    actions   = ["ssm:GetParameter", "ssm:PutParameter"]
    resources = [for param in aws_ssm_parameter.mongodb : param.arn]
  }

  statement {
    sid       = "UseSsmKey"
    actions   = ["kms:Decrypt", "kms:Encrypt"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.aws_region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "mongodb" {
  name               = "${local.name_prefix}-${local.mongodb_stage}-mongodb"
  assume_role_policy = data.aws_iam_policy_document.mongodb_assume.json
}

resource "aws_iam_role_policy_attachment" "mongodb_ssm_core" {
  role       = aws_iam_role.mongodb.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "mongodb_params" {
  name   = "manage-own-parameters"
  role   = aws_iam_role.mongodb.id
  policy = data.aws_iam_policy_document.mongodb_params.json
}

resource "aws_iam_instance_profile" "mongodb" {
  name = aws_iam_role.mongodb.name
  role = aws_iam_role.mongodb.name
}

resource "aws_instance" "mongodb" {
  ami                         = data.aws_ssm_parameter.al2023_kernel_6_12.value
  instance_type               = "t3.small"
  subnet_id                   = data.aws_subnet.dev.id
  vpc_security_group_ids      = [aws_security_group.mongodb.id]
  iam_instance_profile        = aws_iam_instance_profile.mongodb.name
  associate_public_ip_address = false
  ebs_optimized               = true

  user_data = templatefile("${path.module}/templates/mongodb/user_data.sh.tftpl", {
    aws_region          = var.aws_region
    mongodb_image       = local.mongodb_image
    uri_param           = local.mongodb_params.uri
    root_password_param = local.mongodb_params.root_password
    app_password_param  = local.mongodb_params.app_password
  })
  user_data_replace_on_change = false

  # 데이터 호스트라서 AMI·user_data 변경으로 교체되지 않게 한다.
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
    Name  = "${local.name_prefix}-${local.mongodb_stage}-mongodb"
    Role  = "mongodb"
    Stage = local.mongodb_stage
  }

  # user_data가 부팅 중 파라미터를 읽고 쓰므로 권한과 파라미터가 먼저 있어야 한다.
  depends_on = [
    aws_iam_role_policy.mongodb_params,
    aws_iam_role_policy_attachment.mongodb_ssm_core,
  ]
}

resource "aws_ebs_volume" "mongodb_data" {
  # 인스턴스를 교체해도 볼륨이 유지되도록 인스턴스가 아니라 서브넷의 AZ를 쓴다.
  availability_zone = data.aws_subnet.dev.availability_zone
  type              = "gp3"
  size              = 20
  encrypted         = true

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name      = "${local.name_prefix}-${local.mongodb_stage}-mongodb-data"
    DataClass = "persistent"
    Snapshot  = "mongodb-${local.mongodb_stage}"
  }
}

resource "aws_volume_attachment" "mongodb_data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.mongodb_data.id
  instance_id = aws_instance.mongodb.id
}

data "aws_iam_policy_document" "dlm_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["dlm.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "mongodb_dlm" {
  name               = "${local.name_prefix}-${local.mongodb_stage}-mongodb-dlm"
  assume_role_policy = data.aws_iam_policy_document.dlm_assume.json
}

resource "aws_iam_role_policy_attachment" "mongodb_dlm" {
  role       = aws_iam_role.mongodb_dlm.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

resource "aws_dlm_lifecycle_policy" "mongodb" {
  description        = "stg MongoDB data volume daily snapshot"
  execution_role_arn = aws_iam_role.mongodb_dlm.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]
    target_tags    = { Snapshot = "mongodb-${local.mongodb_stage}" }

    schedule {
      name = "daily"

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["18:00"] # 03:00 KST
      }

      retain_rule {
        count = 14
      }

      copy_tags = true
    }
  }

  depends_on = [aws_iam_role_policy_attachment.mongodb_dlm]
}

output "mongodb_stg_instance_id" {
  description = "SSM Run Command로 mongodb-apply를 실행할 대상"
  value       = aws_instance.mongodb.id
}
