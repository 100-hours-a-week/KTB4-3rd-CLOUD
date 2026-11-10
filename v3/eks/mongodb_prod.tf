# prod MongoDB: 데이터 서브넷 3개 AZ의 EC2 레플리카 셋 (rs0).
#   위치 : data-a(2a), data-b(2c), data-msk-c(2b). NAT가 없어 SSM·ECR은 Interface Endpoint, 패키지는 S3 Gateway로 받는다.
#   이미지 : Docker Hub에 닿지 못하므로 mongo 이미지를 ECR에 미러링해 digest로 고정한다. 값이 없으면 호스트를 만들지 않는다.
#   접근 : TCP 27017은 멤버끼리와 core·realtime 노드에서만. burst(fastapi)는 제외한다.
#   비밀값 : 첫 번째 노드가 부팅 시 생성해 SSM에 직접 쓴다. Terraform state에 값이 남지 않는다.
#   백업 : EBS 일일 스냅샷 14일.
variable "mongodb_prod_image" {
  description = "ECR에 미러링한 mongo 이미지 (<registry>/moyeota/mongo@sha256:...). null이면 prod MongoDB를 만들지 않는다."
  type        = string
  default     = null

  validation {
    condition     = var.mongodb_prod_image == null || can(regex("@sha256:[0-9a-f]{64}$", var.mongodb_prod_image))
    error_message = "mongodb_prod_image는 digest로 고정해야 합니다."
  }
}

locals {
  mongodb_prod_enabled      = var.mongodb_prod_image != null
  mongodb_prod_param_prefix = "/moyeota/v2/prod"
  mongodb_prod_params = {
    uri           = "${local.mongodb_prod_param_prefix}/backend/MONGODB_URI"
    root_password = "${local.mongodb_prod_param_prefix}/mongo/ROOT_PASSWORD"
    app_password  = "${local.mongodb_prod_param_prefix}/mongo/APP_PASSWORD"
    keyfile       = "${local.mongodb_prod_param_prefix}/mongo/KEYFILE"
  }
  # data 서브넷은 RDS, Redis, MSK, Endpoint ENI와 공유한다. host는 서브넷에서 비어 있는 주소다.
  mongodb_prod_nodes = {
    a = { index = 0, subnet = "data-a", host = 30 }
    c = { index = 1, subnet = "data-b", host = 30 }
    b = { index = 2, subnet = "data-msk-c", host = 20 }
  }
  mongodb_prod_ips = {
    for key, node in local.mongodb_prod_nodes :
    key => cidrhost(data.aws_subnet.mongodb_prod[key].cidr_block, node.host)
    if local.mongodb_prod_enabled
  }
  # 관리 경로에만 쓰이지만 Private DNS가 VPC 전체에 적용되므로 AZ 장애에 대비해 2개 AZ에 둔다.
  mongodb_prod_interface_endpoints = local.mongodb_prod_enabled ? toset(["ssm", "ssmmessages", "ec2messages", "ecr.api", "ecr.dkr"]) : toset([])
  mongodb_prod_client_node_groups  = toset(["core", "realtime"])
}

resource "aws_ecr_repository" "mongodb" {
  name                 = "moyeota/mongo"
  image_tag_mutability = "IMMUTABLE"

  encryption_configuration {
    encryption_type = "AES256"
  }
}

data "aws_subnet" "mongodb_prod" {
  for_each = local.mongodb_prod_enabled ? local.mongodb_prod_nodes : {}

  filter {
    name   = "tag:Name"
    values = ["${var.project_name}-${each.value.subnet}"]
  }
  vpc_id = data.aws_vpc.shared.id
}

data "aws_route_table" "private_data" {
  count = local.mongodb_prod_enabled ? 1 : 0

  vpc_id = data.aws_vpc.shared.id
  filter {
    name   = "tag:Name"
    values = ["${var.project_name}-private-data-rt"]
  }
}

# AL2023 패키지 저장소는 S3에 있다.
resource "aws_vpc_endpoint_route_table_association" "mongodb_prod_s3" {
  count = local.mongodb_prod_enabled ? 1 : 0

  vpc_endpoint_id = data.aws_vpc_endpoint.s3.id
  route_table_id  = data.aws_route_table.private_data[0].id
}

resource "aws_security_group" "vpc_endpoints" {
  count = local.mongodb_prod_enabled ? 1 : 0

  name                   = "${local.name_prefix}-vpc-endpoints"
  description            = "Interface endpoints; Private DNS applies VPC-wide"
  vpc_id                 = data.aws_vpc.shared.id
  revoke_rules_on_delete = true

  ingress {
    description = "HTTPS from the VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.shared.cidr_block]
  }

  tags = {
    Name = "${local.name_prefix}-vpc-endpoints-sg"
  }
}

resource "aws_vpc_endpoint" "mongodb_prod" {
  for_each = local.mongodb_prod_interface_endpoints

  vpc_id              = data.aws_vpc.shared.id
  service_name        = "com.amazonaws.${var.aws_region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [data.aws_subnet.mongodb_prod["a"].id, data.aws_subnet.mongodb_prod["c"].id]
  security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
  private_dns_enabled = true

  tags = {
    Name = "${local.name_prefix}-${each.key}"
  }
}

# 값은 첫 번째 노드가 채운다. 이후 값 변경을 Terraform이 되돌리지 않는다.
resource "aws_ssm_parameter" "mongodb_prod" {
  for_each = local.mongodb_prod_enabled ? local.mongodb_prod_params : {}

  name  = each.value
  type  = "SecureString"
  tier  = "Standard"
  value = "CHANGE_ME"

  lifecycle {
    ignore_changes = [value]
  }

  tags = {
    Stage = "prod"
    Group = "mongodb"
  }
}

resource "aws_security_group" "mongodb_prod" {
  count = local.mongodb_prod_enabled ? 1 : 0

  name                   = "${local.name_prefix}-prod-mongodb"
  description            = "prod MongoDB replica set"
  vpc_id                 = data.aws_vpc.shared.id
  revoke_rules_on_delete = true

  egress {
    description = "VPC endpoints"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name_prefix}-prod-mongodb-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "mongodb_prod_members" {
  count = local.mongodb_prod_enabled ? 1 : 0

  security_group_id            = aws_security_group.mongodb_prod[0].id
  description                  = "Replica set members"
  referenced_security_group_id = aws_security_group.mongodb_prod[0].id
  ip_protocol                  = "tcp"
  from_port                    = 27017
  to_port                      = 27017
}

resource "aws_vpc_security_group_ingress_rule" "mongodb_prod_from_nodes" {
  for_each = local.mongodb_prod_enabled ? local.mongodb_prod_client_node_groups : toset([])

  security_group_id            = aws_security_group.mongodb_prod[0].id
  description                  = "MongoDB from EKS ${each.key} nodes"
  referenced_security_group_id = aws_security_group.node[each.key].id
  ip_protocol                  = "tcp"
  from_port                    = 27017
  to_port                      = 27017
}

data "aws_iam_policy_document" "mongodb_prod_params" {
  count = local.mongodb_prod_enabled ? 1 : 0

  statement {
    sid       = "ManageOwnParameters"
    actions   = ["ssm:GetParameter", "ssm:PutParameter"]
    resources = [for param in aws_ssm_parameter.mongodb_prod : param.arn]
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

resource "aws_iam_role" "mongodb_prod" {
  count = local.mongodb_prod_enabled ? 1 : 0

  name               = "${local.name_prefix}-prod-mongodb"
  assume_role_policy = data.aws_iam_policy_document.mongodb_assume.json
}

resource "aws_iam_role_policy_attachment" "mongodb_prod" {
  for_each = local.mongodb_prod_enabled ? toset([
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
  ]) : toset([])

  role       = aws_iam_role.mongodb_prod[0].name
  policy_arn = each.value
}

resource "aws_iam_role_policy" "mongodb_prod_params" {
  count = local.mongodb_prod_enabled ? 1 : 0

  name   = "manage-own-parameters"
  role   = aws_iam_role.mongodb_prod[0].id
  policy = data.aws_iam_policy_document.mongodb_prod_params[0].json
}

resource "aws_iam_instance_profile" "mongodb_prod" {
  count = local.mongodb_prod_enabled ? 1 : 0

  name = aws_iam_role.mongodb_prod[0].name
  role = aws_iam_role.mongodb_prod[0].name
}

resource "aws_instance" "mongodb_prod" {
  for_each = local.mongodb_prod_enabled ? local.mongodb_prod_nodes : {}

  ami                         = data.aws_ssm_parameter.al2023_kernel_6_12.value
  instance_type               = "t3.medium"
  subnet_id                   = data.aws_subnet.mongodb_prod[each.key].id
  private_ip                  = local.mongodb_prod_ips[each.key]
  vpc_security_group_ids      = [aws_security_group.mongodb_prod[0].id]
  iam_instance_profile        = aws_iam_instance_profile.mongodb_prod[0].name
  associate_public_ip_address = false
  ebs_optimized               = true

  user_data = templatefile("${path.module}/templates/mongodb-replica/user_data.sh.tftpl", {
    aws_region          = var.aws_region
    node_index          = each.value.index
    hosts               = join(" ", values(local.mongodb_prod_ips))
    image               = var.mongodb_prod_image
    root_password_param = local.mongodb_prod_params.root_password
    app_password_param  = local.mongodb_prod_params.app_password
    keyfile_param       = local.mongodb_prod_params.keyfile
    uri_param           = local.mongodb_prod_params.uri
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
    Name  = "${local.name_prefix}-prod-mongodb-${each.key}"
    Role  = "mongodb"
    Stage = "prod"
  }

  # 부팅 중 SSM·ECR·패키지 저장소에 접근하므로 경로와 권한이 먼저 있어야 한다.
  depends_on = [
    aws_iam_role_policy.mongodb_prod_params,
    aws_iam_role_policy_attachment.mongodb_prod,
    aws_vpc_endpoint.mongodb_prod,
    aws_vpc_endpoint_route_table_association.mongodb_prod_s3,
  ]
}

resource "aws_ebs_volume" "mongodb_prod_data" {
  for_each = local.mongodb_prod_enabled ? local.mongodb_prod_nodes : {}

  availability_zone = aws_instance.mongodb_prod[each.key].availability_zone
  type              = "gp3"
  size              = 50
  encrypted         = true

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name      = "${local.name_prefix}-prod-mongodb-${each.key}-data"
    DataClass = "persistent"
    Snapshot  = "mongodb-prod"
  }
}

resource "aws_volume_attachment" "mongodb_prod_data" {
  for_each = local.mongodb_prod_enabled ? local.mongodb_prod_nodes : {}

  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.mongodb_prod_data[each.key].id
  instance_id = aws_instance.mongodb_prod[each.key].id
}

resource "aws_dlm_lifecycle_policy" "mongodb_prod" {
  count = local.mongodb_prod_enabled ? 1 : 0

  description        = "prod MongoDB data volume daily snapshot"
  execution_role_arn = aws_iam_role.mongodb_dlm.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]
    target_tags    = { Snapshot = "mongodb-prod" }

    schedule {
      name = "daily"

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["18:30"] # 03:30 KST
      }

      retain_rule {
        count = 14
      }

      copy_tags = true
    }
  }

  depends_on = [aws_iam_role_policy_attachment.mongodb_dlm]
}

output "mongodb_prod_ecr_repository_url" {
  description = "mongo 이미지를 미러링할 ECR 저장소"
  value       = aws_ecr_repository.mongodb.repository_url
}

output "mongodb_prod_instance_ids" {
  description = "prod MongoDB 노드 인스턴스 ID"
  value       = { for key, instance in aws_instance.mongodb_prod : key => instance.id }
}
