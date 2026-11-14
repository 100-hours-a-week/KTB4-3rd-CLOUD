# V3 prod MongoDB → v4 데이터 호스트 이관용 임시 권한 (MONGODB_MIGRATION.md).
#   mongo_migration_enabled = true 동안만:
#     - V3 MongoDB SG(moyeota-v3-prod-mongodb)에 v4 데이터 호스트 SG → 27017 인바운드
#     - 데이터 호스트 Role에 V3 MongoDB 접속 정보(URI, root 비밀번호) SSM 읽기
#   이관이 끝나면 false로 되돌린다. V3를 destroy하기 전에 반드시 false여야 한다 (V3 SG를 조회하므로).
#
#   데이터 호스트가 V3 replica set에 직접 접속해 mongodump | mongorestore로 옮긴다. 중간 저장소(S3)는 쓰지 않는다.

variable "mongo_migration_enabled" {
  description = "V3 prod MongoDB 이관 동안만 true. V3 SG 인바운드와 V3 SSM 읽기 권한을 연다."
  type        = bool
  default     = false
}

variable "v3_mongodb_sg_name" {
  description = "V3 prod MongoDB replica set SG 이름 (v3/eks/mongodb_prod.tf)."
  type        = string
  default     = "moyeota-v3-prod-mongodb"
}

variable "v3_mongodb_param_prefix" {
  description = "V3 prod MongoDB SSM 경로 (앞뒤 슬래시 없이). backend/MONGODB_URI, mongo/ROOT_PASSWORD를 읽는다."
  type        = string
  default     = "moyeota/v2/prod"
}

locals {
  mongo_migration_count = var.mongo_migration_enabled ? 1 : 0

  v3_mongodb_params = {
    uri           = "/${var.v3_mongodb_param_prefix}/backend/MONGODB_URI"
    root_password = "/${var.v3_mongodb_param_prefix}/mongo/ROOT_PASSWORD"
  }
}

data "aws_security_group" "v3_mongodb" {
  count = local.mongo_migration_count

  name   = var.v3_mongodb_sg_name
  vpc_id = data.aws_vpc.shared.id
}

resource "aws_vpc_security_group_ingress_rule" "v3_mongodb_from_data_host" {
  count = local.mongo_migration_count

  security_group_id            = data.aws_security_group.v3_mongodb[0].id
  description                  = "v4 data host (MongoDB migration, temporary)"
  referenced_security_group_id = aws_security_group.data_host.id
  ip_protocol                  = "tcp"
  from_port                    = 27017
  to_port                      = 27017
}

data "aws_iam_policy_document" "mongo_migration" {
  count = local.mongo_migration_count

  statement {
    sid     = "ReadV3MongoParameters"
    actions = ["ssm:GetParameter"]
    resources = [
      for name in values(local.v3_mongodb_params) :
      "arn:${local.partition}:ssm:${local.region}:${local.account_id}:parameter${name}"
    ]
  }
}

# kms:Decrypt(SSM 경유)는 data_host_params 정책에 이미 있다
resource "aws_iam_role_policy" "mongo_migration" {
  count = local.mongo_migration_count

  name   = "read-v3-mongo-parameters"
  role   = aws_iam_role.data_host.id
  policy = data.aws_iam_policy_document.mongo_migration[0].json
}
