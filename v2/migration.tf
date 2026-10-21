# =============================================================================
# V1 → V2 DB 이관 리허설 환경 (ProxySQL 컷오버) — stg
#   설계: Claude outputs/v2-stg-proxysql-migration-test-design.md (2·3·8장)
#   구축 런북: Claude outputs/v2-stg-proxysql-rehearsal-env-runbook.md
#
#   migration_rehearsal_enabled = false(기본)면 아무것도 만들지 않는다. 리허설이 끝나면 false로 apply해 전부 지운다.
#   리허설 기간에만 쓰는 리소스라 변수·출력도 이 파일에 모아 둔다 (지울 때 파일 하나만 보면 된다).
#
#   구성 (stg dev 서브넷, AZ-a — stg ECS·stg RDS와 같은 AZ)
#     v1-sim EC2 (AL2023, Docker Compose) = V1 Prod 호스트 재현
#       mysql    : V1과 같은 이미지·옵션, database 네트워크(internal)        — V1 MySQL
#       proxysql : app·database 네트워크, 6033(앱) · 6032(관리, 호스트 루프백) · 6070(exporter)
#                  hg10 = V1 MySQL(ONLINE) + stg RDS(OFFLINE_HARD), 백엔드 연결 TLS
#       relay    : socat, 호스트 사설 IP:3307 → mysql:3306 (RDS 정방향 복제, Grafana V1 조회)
#       backend·nginx (V1 backend 이미지가 있을 때만) : DB_HOST는 mysql로 시작 → S0에서 proxysql로 바꾼다
#     stg RDS (CLI로 만든 moyeota-v2-stg) : SG에 규칙만 붙인다 (인스턴스·SG·파라미터 그룹은 CLI 소유)
#
#   네트워크 경로 (보안 그룹)
#     v1-sim ProxySQL·mysql client ─3306→ stg RDS          (쓰기 전환 후 앱 쓰기, 역방향 복제, 덤프 적재)
#     stg RDS ─3307→ v1-sim relay                         (정방향 복제: RDS가 V1 binlog를 가져감)
#     모니터링 ─3307→ v1-sim relay, ─3306→ stg RDS         (Grafana MySQL 데이터소스 — ProxySQL을 거치지 않는다)
#     모니터링 ─6070→ v1-sim ProxySQL exporter             (Prometheus 정적 타깃)
#     Non-Prod ALB ─80→ v1-sim nginx                       (migration_v1_sim_host가 있을 때, k6 트래픽)
#
#   비밀값: Terraform은 SSM 파라미터 자리만 만든다(CHANGE_ME + ignore_changes). 값은 CLI로 넣는다 (ssm.tf 원칙)
#     /moyeota/v2/migration/*                          v1-sim 전용
#     /moyeota/v2/monitoring/MIGRATION_DB_MON_PASSWORD 조회 계정(mig_mon) — v1-sim·모니터링 호스트가 같이 읽는다
#     앱 계정은 stg 값(/moyeota/v2/stg/backend/DB_NAME·DB_USERNAME·DB_PASSWORD)을 그대로 쓴다
#       → ProxySQL은 백엔드(V1·RDS)에 같은 계정으로 접속하므로 두 DB의 앱 계정 비밀번호가 같아야 한다
#
#   지우는 순서: 이 파일을 false로 apply(규칙·호스트·버킷 삭제) → stg RDS CLI teardown
#     (RDS SG를 먼저 지우면 여기서 붙인 규칙이 남은 state 때문에 plan이 실패한다)
# =============================================================================

variable "migration_rehearsal_enabled" {
  description = "true면 이관 리허설 환경(v1-sim·SG 규칙·이관 버킷·Grafana 연결)을 만든다. 리허설이 끝나면 false로 apply한다."
  type        = bool
  default     = false
}

variable "migration_stg_rds_identifier" {
  description = "리허설 대상 stg RDS (Claude outputs/stg-rds-create.sh가 만든 인스턴스). 없으면 plan이 실패한다."
  type        = string
  default     = "moyeota-v2-stg"
}

variable "migration_v1_backend_image" {
  description = <<-EOT
    v1-sim에서 띄울 V1 backend 이미지 (V1 Prod와 같은 digest — V1 Prod EC2의 /opt/moyeota/.deploy/backend.env BACKEND_IMAGE_REF).
    null이면 backend·nginx 없이 mysql·proxysql·relay만 띄운다 (복제·전환만 시험할 때).
  EOT
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.migration_v1_backend_image == null || can(regex("@sha256:[0-9a-f]{64}$", var.migration_v1_backend_image))
    error_message = "migration_v1_backend_image는 digest 참조(...@sha256:<64 hex>)여야 한다 (V1 Prod와 같은 이미지)."
  }
}

variable "migration_v1_sim_instance_type" {
  description = "v1-sim 타입. V1 Prod와 같은 t3.medium (자원 경합까지 재현)."
  type        = string
  default     = "t3.medium"
}

variable "migration_v1_sim_root_volume_gib" {
  description = "v1-sim 루트 볼륨(GiB). D2(messages 약 1 GB) + binlog + 덤프 임시 파일이 들어가야 한다."
  type        = number
  default     = 30

  validation {
    condition     = var.migration_v1_sim_root_volume_gib >= 20
    error_message = "migration_v1_sim_root_volume_gib must be at least 20."
  }
}

variable "migration_images" {
  description = "v1-sim 컨테이너 이미지 (버전 고정). mysql은 V1 Prod·stg RDS와 같은 8.4.11, ProxySQL은 caching_sha2_password를 지원하는 2.6.0 이상."
  type = object({
    mysql    = optional(string, "mysql:8.4.11")
    proxysql = optional(string, "proxysql/proxysql:2.7.2")
    socat    = optional(string, "alpine/socat:1.8.0.0")
    nginx    = optional(string, "nginx:1.29-alpine")
  })
  default = {}
}

variable "migration_v1_sim_host" {
  description = <<-EOT
    v1-sim nginx를 Non-Prod ALB 호스트 규칙으로 열 도메인 (예: v1sim.moyeota.com). k6가 V1 쪽 트래픽을 이 주소로 보낸다.
    Non-Prod ALB SG가 admin_cidrs·dev_qa_cidrs만 허용한다. null이면 ALB에 붙이지 않는다.
    Non-Prod HTTPS 리스너가 있으면 이 호스트 전용 인증서를 SNI로 추가한다 (dev·stg 인증서는 그대로).
  EOT
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.migration_v1_sim_host == null || var.route53_zone_name != null
    error_message = "migration_v1_sim_host를 쓰려면 route53_zone_name이 필요하다 (DNS·인증서 검증)."
  }
}

variable "migration_v1_sim_listener_priority" {
  description = "Non-Prod ALB 리스너 규칙 우선순위. Grafana(monitoring_grafana_listener_priority)·ECS 규칙(stg 200~, dev 300~)과 겹치지 않게 둔다."
  type        = number
  default     = 60

  validation {
    condition     = var.migration_v1_sim_listener_priority >= 1 && var.migration_v1_sim_listener_priority < 200 && var.migration_v1_sim_listener_priority != var.monitoring_grafana_listener_priority
    error_message = "migration_v1_sim_listener_priority must be 1-199 and differ from monitoring_grafana_listener_priority."
  }
}

variable "migration_v1_prod_role_name" {
  description = <<-EOT
    D0(V1 Prod 사본) 덤프를 이관 버킷 dumps/d0/에 올릴 V1 Prod EC2 IAM Role 이름 (infra/ state: moyeota-ec2-prod).
    버킷 정책으로 그 Role에 PutObject만 허용한다 (V1 Role·SG는 건드리지 않는다. V1 SG 아웃바운드 443으로 S3에 올린다).
    null이면 허용하지 않는다.
  EOT
  type        = string
  default     = null
  nullable    = true
}

variable "migration_dump_retention_days" {
  description = "이관 버킷 dumps/ 객체 보존 기간(일). D0에는 운영 개인정보가 들어 있으므로 짧게 둔다."
  type        = number
  default     = 3

  validation {
    condition     = var.migration_dump_retention_days >= 1 && var.migration_dump_retention_days <= 14
    error_message = "migration_dump_retention_days must be between 1 and 14."
  }
}

# -----------------------------------------------------------------------------
# 공통 값
# -----------------------------------------------------------------------------

locals {
  migration_enabled = var.migration_rehearsal_enabled

  migration_name      = "${var.project_name}-stg-v1sim"
  migration_ssm_path  = "/${var.config_path_prefix}/migration"
  migration_mon_param = "/${var.config_path_prefix}/monitoring/MIGRATION_DB_MON_PASSWORD"
  migration_stg_db    = "/${var.config_path_prefix}/stg/backend"

  migration_ports = {
    mysql   = 3306
    relay   = 3307
    metrics = 6070
    http    = 80
  }

  # v1-sim 전용 비밀값 (값은 CLI — 런북 E-2)
  migration_secret_keys = {
    MYSQL_ROOT_PASSWORD     = "v1-sim MySQL root 비밀번호 (볼륨 최초 기동 때만 적용)"
    REPL_PASSWORD           = "복제 계정 repl 비밀번호 — V1(sim)·stg RDS 양쪽 같은 값 (정방향·역방향 복제)"
    PROXYSQL_ADMIN_PASSWORD = "ProxySQL 원격 관리 계정 radmin 비밀번호 (기본 admin 계정은 컨테이너 안 루프백 전용)"
    V1_BACKEND_ENV          = "V1 Prod /opt/moyeota/env/backend.env 내용 그대로 (DB_* 줄은 render가 stg 앱 계정으로 바꾼다)"
  }

  migration_stg_rds_sg_ids = local.migration_enabled ? toset(data.aws_db_instance.migration_stg[0].vpc_security_groups) : toset([])
  migration_rds_secret_arn = local.migration_enabled ? try(data.aws_db_instance.migration_stg[0].master_user_secret[0].secret_arn, null) : null

  migration_alb_enabled  = local.migration_enabled && var.migration_v1_sim_host != null
  migration_cert_enabled = local.migration_alb_enabled && local.nonprod_tls_enabled
  migration_listener_arn = local.nonprod_tls_enabled ? try(aws_lb_listener.nonprod_https[0].arn, null) : aws_lb_listener.nonprod_http.arn

  migration_monitoring_enabled = local.migration_enabled && local.monitoring_enabled
}

data "aws_db_instance" "migration_stg" {
  count = local.migration_enabled ? 1 : 0

  db_instance_identifier = var.migration_stg_rds_identifier
}

data "aws_ssm_parameter" "migration_al2023" {
  count = local.migration_enabled ? 1 : 0

  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# -----------------------------------------------------------------------------
# 비밀값 자리 (SSM SecureString, 값은 CLI)
# -----------------------------------------------------------------------------

resource "aws_ssm_parameter" "migration" {
  for_each = local.migration_enabled ? local.migration_secret_keys : {}

  name        = "${local.migration_ssm_path}/${each.key}"
  description = each.value
  type        = "SecureString"
  tier        = each.key == "V1_BACKEND_ENV" ? "Advanced" : "Standard"
  value       = "CHANGE_ME"

  tags = {
    Stage   = "stg"
    Purpose = "migration-rehearsal"
  }

  lifecycle {
    ignore_changes = [value]
  }
}

# Grafana MySQL 데이터소스·ProxySQL monitor·v1-sim이 같이 쓰는 조회 계정(mig_mon) 비밀번호
#   모니터링 호스트는 /<prefix>/monitoring/*만 읽으므로 이 경로에 둔다 (modules/monitoring/templates/sync.sh → Grafana .env)
resource "aws_ssm_parameter" "migration_mon_password" {
  count = local.migration_enabled ? 1 : 0

  name        = local.migration_mon_param
  description = "이관 리허설 조회 계정 mig_mon 비밀번호 (V1 sim·stg RDS 같은 값). Grafana MySQL 데이터소스·ProxySQL monitor"
  type        = "SecureString"
  value       = "CHANGE_ME"

  tags = {
    Stage   = "monitoring"
    Purpose = "migration-rehearsal"
  }

  lifecycle {
    ignore_changes = [value]
  }
}

# -----------------------------------------------------------------------------
# 이관 버킷
#   config/ : v1-sim 설정 (compose, proxysql.cnf 템플릿, nginx, 스크립트) — v1-sim이 render 때 받는다
#   dumps/  : D0(V1 Prod 사본)·D1·D2 덤프. migration_dump_retention_days 뒤 삭제, 리허설 종료 시 버킷째 삭제(force_destroy)
# -----------------------------------------------------------------------------

resource "aws_s3_bucket" "migration" {
  count = local.migration_enabled ? 1 : 0

  bucket        = "${var.project_name}-migration-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = {
    Name    = "${var.project_name}-migration"
    Stage   = "stg"
    Purpose = "migration-rehearsal"
  }
}

resource "aws_s3_bucket_public_access_block" "migration" {
  count = local.migration_enabled ? 1 : 0

  bucket                  = aws_s3_bucket.migration[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "migration" {
  count = local.migration_enabled ? 1 : 0

  bucket = aws_s3_bucket.migration[0].id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "migration" {
  count = local.migration_enabled ? 1 : 0

  bucket = aws_s3_bucket.migration[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "migration" {
  count = local.migration_enabled ? 1 : 0

  bucket = aws_s3_bucket.migration[0].id

  rule {
    id     = "expire-dumps"
    status = "Enabled"

    filter {
      prefix = "dumps/"
    }

    expiration {
      days = var.migration_dump_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

data "aws_iam_policy_document" "migration_bucket" {
  count = local.migration_enabled ? 1 : 0

  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.migration[0].arn,
      "${aws_s3_bucket.migration[0].arn}/*",
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  # V1 Prod EC2 → dumps/d0/ 업로드만 (같은 계정이라 버킷 정책만으로 허용된다. V1 Role 정책은 바꾸지 않는다)
  dynamic "statement" {
    for_each = var.migration_v1_prod_role_name == null ? [] : [var.migration_v1_prod_role_name]

    content {
      sid       = "AllowV1ProdD0Upload"
      effect    = "Allow"
      actions   = ["s3:PutObject"]
      resources = ["${aws_s3_bucket.migration[0].arn}/dumps/d0/*"]

      principals {
        type        = "AWS"
        identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${statement.value}"]
      }
    }
  }
}

resource "aws_s3_bucket_policy" "migration" {
  count = local.migration_enabled ? 1 : 0

  bucket = aws_s3_bucket.migration[0].id
  policy = data.aws_iam_policy_document.migration_bucket[0].json

  depends_on = [aws_s3_bucket_public_access_block.migration]
}

# v1-sim 설정 파일 — 바꾸면 apply 후 v1-sim에서 `sudo mig render`로 반영한다 (호스트는 교체하지 않는다)
locals {
  migration_template_dir = "${path.module}/templates/migration"

  migration_config_files = local.migration_enabled ? {
    "compose.yaml"     = file("${local.migration_template_dir}/compose.yaml")
    "proxysql.cnf.tpl" = file("${local.migration_template_dir}/proxysql.cnf.tpl")
    "nginx.conf"       = file("${local.migration_template_dir}/nginx.conf")
    "bin/mig"          = file("${local.migration_template_dir}/mig.sh")

    # 비밀이 아닌 실행 값 (render가 source한다)
    "v1sim.env" = join("\n", [
      "AWS_REGION=${var.aws_region}",
      "SSM_PATH=${local.migration_ssm_path}",
      "MON_PASSWORD_PARAM=${local.migration_mon_param}",
      "STG_DB_PARAM_PATH=${local.migration_stg_db}",
      "RDS_HOST=${data.aws_db_instance.migration_stg[0].address}",
      "RDS_PORT=${data.aws_db_instance.migration_stg[0].port}",
      "RDS_SECRET_ARN=${coalesce(local.migration_rds_secret_arn, "NONE")}",
      "MYSQL_IMAGE=${var.migration_images.mysql}",
      "PROXYSQL_IMAGE=${var.migration_images.proxysql}",
      "SOCAT_IMAGE=${var.migration_images.socat}",
      "NGINX_IMAGE=${var.migration_images.nginx}",
      "V1_BACKEND_IMAGE=${coalesce(var.migration_v1_backend_image, "NONE")}",
      "",
    ])
  } : {}
}

resource "aws_s3_object" "migration_config" {
  for_each = local.migration_config_files

  bucket       = aws_s3_bucket.migration[0].id
  key          = "config/${each.key}"
  content      = each.value
  content_type = "text/plain; charset=utf-8"
}

# -----------------------------------------------------------------------------
# v1-sim 보안 그룹 · stg RDS 규칙
# -----------------------------------------------------------------------------

resource "aws_security_group" "migration_v1_sim" {
  count = local.migration_enabled ? 1 : 0

  name                   = local.migration_name
  description            = "Migration rehearsal V1 simulator (MySQL, ProxySQL, relay); no public ingress"
  vpc_id                 = data.aws_vpc.shared.id
  revoke_rules_on_delete = true

  tags = {
    Name        = "${local.migration_name}-sg"
    Environment = "stg"
    Purpose     = "migration-rehearsal"
  }
}

resource "aws_vpc_security_group_egress_rule" "migration_v1_sim_all" {
  count = local.migration_enabled ? 1 : 0

  security_group_id = aws_security_group.migration_v1_sim[0].id
  description       = "RDS 3306, image pulls, SSM/S3/ECR APIs through NAT"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# 정방향 복제: RDS가 v1-sim relay(3307)로 접속해 V1 binlog를 가져간다
resource "aws_vpc_security_group_ingress_rule" "migration_relay_from_rds" {
  for_each = local.migration_stg_rds_sg_ids

  security_group_id            = aws_security_group.migration_v1_sim[0].id
  description                  = "Forward replication: stg RDS pulls V1 binlog via relay"
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = local.migration_ports.relay
  to_port                      = local.migration_ports.relay
}

# v1-sim(ProxySQL·역방향 복제·mysql client) → stg RDS
resource "aws_vpc_security_group_ingress_rule" "migration_rds_from_v1_sim" {
  for_each = local.migration_stg_rds_sg_ids

  security_group_id            = each.value
  description                  = "MySQL from migration v1-sim (ProxySQL, reverse replication, dump load)"
  referenced_security_group_id = aws_security_group.migration_v1_sim[0].id
  ip_protocol                  = "tcp"
  from_port                    = local.migration_ports.mysql
  to_port                      = local.migration_ports.mysql
}

# Grafana MySQL 데이터소스 — ProxySQL을 거치지 않고 직접 조회한다 (ProxySQL 장애 때도 DB 상태가 보이도록)
resource "aws_vpc_security_group_ingress_rule" "migration_rds_from_monitoring" {
  for_each = local.migration_monitoring_enabled ? local.migration_stg_rds_sg_ids : toset([])

  security_group_id            = each.value
  description                  = "MySQL from monitoring host (Grafana migration datasource)"
  referenced_security_group_id = aws_security_group.monitoring[0].id
  ip_protocol                  = "tcp"
  from_port                    = local.migration_ports.mysql
  to_port                      = local.migration_ports.mysql
}

resource "aws_vpc_security_group_ingress_rule" "migration_relay_from_monitoring" {
  count = local.migration_monitoring_enabled ? 1 : 0

  security_group_id            = aws_security_group.migration_v1_sim[0].id
  description                  = "V1 MySQL via relay from monitoring host (Grafana migration datasource)"
  referenced_security_group_id = aws_security_group.monitoring[0].id
  ip_protocol                  = "tcp"
  from_port                    = local.migration_ports.relay
  to_port                      = local.migration_ports.relay
}

resource "aws_vpc_security_group_ingress_rule" "migration_metrics_from_monitoring" {
  count = local.migration_monitoring_enabled ? 1 : 0

  security_group_id            = aws_security_group.migration_v1_sim[0].id
  description                  = "ProxySQL Prometheus exporter from monitoring host"
  referenced_security_group_id = aws_security_group.monitoring[0].id
  ip_protocol                  = "tcp"
  from_port                    = local.migration_ports.metrics
  to_port                      = local.migration_ports.metrics
}

resource "aws_vpc_security_group_ingress_rule" "migration_http_from_nonprod_alb" {
  count = local.migration_alb_enabled ? 1 : 0

  security_group_id            = aws_security_group.migration_v1_sim[0].id
  description                  = "V1 nginx from Non-Prod ALB (k6 traffic)"
  referenced_security_group_id = aws_security_group.nonprod_alb.id
  ip_protocol                  = "tcp"
  from_port                    = local.migration_ports.http
  to_port                      = local.migration_ports.http
}

# -----------------------------------------------------------------------------
# v1-sim IAM
# -----------------------------------------------------------------------------

resource "aws_iam_role" "migration_v1_sim" {
  count = local.migration_enabled ? 1 : 0

  name                 = local.migration_name
  assume_role_policy   = data.aws_iam_policy_document.ec2_assume_role.json
  max_session_duration = 3600

  tags = {
    Name    = "${local.migration_name}-role"
    Purpose = "migration-rehearsal"
  }
}

resource "aws_iam_instance_profile" "migration_v1_sim" {
  count = local.migration_enabled ? 1 : 0

  name = local.migration_name
  role = aws_iam_role.migration_v1_sim[0].name
}

resource "aws_iam_role_policy_attachment" "migration_v1_sim_ssm" {
  count = local.migration_enabled ? 1 : 0

  role       = aws_iam_role.migration_v1_sim[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "migration_v1_sim_ecr" {
  count = local.migration_enabled ? 1 : 0

  role       = aws_iam_role.migration_v1_sim[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

data "aws_iam_policy_document" "migration_v1_sim" {
  count = local.migration_enabled ? 1 : 0

  statement {
    sid     = "ReadMigrationParameters"
    actions = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = concat(
      [for k in keys(local.migration_secret_keys) : "arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${local.migration_ssm_path}/${k}"],
      ["arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${local.migration_mon_param}"],
      [for k in ["DB_NAME", "DB_USERNAME", "DB_PASSWORD"] : "arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${local.migration_stg_db}/${k}"],
    )
  }

  statement {
    sid       = "DecryptViaSsmAndSecretsManager"
    actions   = ["kms:Decrypt"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.aws_region}.amazonaws.com", "secretsmanager.${var.aws_region}.amazonaws.com"]
    }
  }

  # stg RDS master 비밀번호 (RDS 관리형 시크릿) — 계정 생성·복제 프로시저 호출용
  dynamic "statement" {
    for_each = local.migration_rds_secret_arn == null ? [] : [local.migration_rds_secret_arn]

    content {
      sid       = "ReadStgRdsMasterSecret"
      actions   = ["secretsmanager:GetSecretValue"]
      resources = [statement.value]
    }
  }

  statement {
    sid       = "ListMigrationBucket"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.migration[0].arn]
  }

  statement {
    sid       = "MigrationBucketObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.migration[0].arn}/*"]
  }
}

resource "aws_iam_role_policy" "migration_v1_sim" {
  count = local.migration_enabled ? 1 : 0

  name   = local.migration_name
  role   = aws_iam_role.migration_v1_sim[0].id
  policy = data.aws_iam_policy_document.migration_v1_sim[0].json
}

# -----------------------------------------------------------------------------
# v1-sim EC2
#   - user data는 Docker·Compose 설치와 첫 render만 한다. 설정 변경은 S3 config/ → `sudo mig render`
#   - 비밀값이 CHANGE_ME면 render가 컨테이너를 띄우지 않고 멈춘다 → 값을 넣고 `sudo mig render`
#   - MySQL 데이터는 루트 볼륨(Docker 볼륨)에 있다. 호스트를 교체하면 리허설 데이터가 사라진다
# -----------------------------------------------------------------------------

resource "aws_instance" "migration_v1_sim" {
  count = local.migration_enabled ? 1 : 0

  ami                         = data.aws_ssm_parameter.migration_al2023[0].insecure_value
  instance_type               = var.migration_v1_sim_instance_type
  subnet_id                   = aws_subnet.v2["dev"].id
  vpc_security_group_ids      = [aws_security_group.migration_v1_sim[0].id]
  iam_instance_profile        = aws_iam_instance_profile.migration_v1_sim[0].name
  associate_public_ip_address = false
  monitoring                  = false
  ebs_optimized               = true

  user_data = templatefile("${local.migration_template_dir}/user_data.sh.tftpl", {
    bucket                 = aws_s3_bucket.migration[0].bucket
    aws_region             = var.aws_region
    docker_compose_version = var.docker_compose_version
  })
  user_data_replace_on_change = false

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
    instance_metadata_tags      = "disabled"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.migration_v1_sim_root_volume_gib
    iops                  = 3000
    throughput            = 125
    encrypted             = true
    delete_on_termination = true
  }

  tags = {
    Name        = local.migration_name
    Environment = "stg"
    Role        = "v1-sim"
    Purpose     = "migration-rehearsal"
  }

  lifecycle {
    ignore_changes = [ami]
  }

  # 첫 부팅 render가 설정·권한을 바로 쓸 수 있게 한다
  depends_on = [
    aws_s3_object.migration_config,
    aws_iam_role_policy.migration_v1_sim,
    aws_s3_bucket_policy.migration,
  ]
}

# -----------------------------------------------------------------------------
# Non-Prod ALB 호스트 규칙 (migration_v1_sim_host) — k6 → v1sim.moyeota.com → v1-sim nginx:80
# -----------------------------------------------------------------------------

resource "aws_lb_target_group" "migration_v1_sim" {
  count = local.migration_alb_enabled ? 1 : 0

  name                 = "${var.project_name}-v1sim"
  port                 = local.migration_ports.http
  protocol             = "HTTP"
  target_type          = "instance"
  vpc_id               = data.aws_vpc.shared.id
  deregistration_delay = 30

  health_check {
    enabled             = true
    path                = "/nginx-health"
    port                = "traffic-port"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = {
    Name    = "${var.project_name}-v1sim-tg"
    Purpose = "migration-rehearsal"
  }
}

resource "aws_lb_target_group_attachment" "migration_v1_sim" {
  count = local.migration_alb_enabled ? 1 : 0

  target_group_arn = aws_lb_target_group.migration_v1_sim[0].arn
  target_id        = aws_instance.migration_v1_sim[0].id
  port             = local.migration_ports.http
}

resource "aws_lb_listener_rule" "migration_v1_sim" {
  count = local.migration_alb_enabled ? 1 : 0

  listener_arn = local.migration_listener_arn
  priority     = var.migration_v1_sim_listener_priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.migration_v1_sim[0].arn
  }

  condition {
    host_header {
      values = [var.migration_v1_sim_host]
    }
  }

  tags = {
    Name    = "${var.project_name}-v1sim-rule"
    Purpose = "migration-rehearsal"
  }

  depends_on = [aws_lb_listener_certificate.migration_v1_sim]
}

resource "aws_route53_record" "migration_v1_sim" {
  count = local.migration_alb_enabled ? 1 : 0

  zone_id = data.aws_route53_zone.public[0].zone_id
  name    = var.migration_v1_sim_host
  type    = "A"

  alias {
    name                   = aws_lb.nonprod.dns_name
    zone_id                = aws_lb.nonprod.zone_id
    evaluate_target_health = false
  }
}

resource "aws_acm_certificate" "migration_v1_sim" {
  count = local.migration_cert_enabled ? 1 : 0

  domain_name       = var.migration_v1_sim_host
  validation_method = "DNS"

  tags = {
    Name    = "${var.project_name}-v1sim"
    Purpose = "migration-rehearsal"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "migration_v1_sim_cert_validation" {
  for_each = local.migration_cert_enabled ? {
    for dvo in aws_acm_certificate.migration_v1_sim[0].domain_validation_options : dvo.domain_name => {
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

resource "aws_acm_certificate_validation" "migration_v1_sim" {
  count = local.migration_cert_enabled ? 1 : 0

  certificate_arn         = aws_acm_certificate.migration_v1_sim[0].arn
  validation_record_fqdns = [for r in aws_route53_record.migration_v1_sim_cert_validation : r.fqdn]
}

resource "aws_lb_listener_certificate" "migration_v1_sim" {
  count = local.migration_cert_enabled ? 1 : 0

  listener_arn    = aws_lb_listener.nonprod_https[0].arn
  certificate_arn = aws_acm_certificate_validation.migration_v1_sim[0].certificate_arn
}

# -----------------------------------------------------------------------------
# 모니터링 연결 (monitoring.tf module "monitoring"에 넘긴다)
#   - Prometheus 정적 타깃 : ProxySQL exporter (v1-sim:6070/metrics)
#   - Grafana MySQL 데이터소스 : V1(sim) = relay 3307, RDS = 3306 직접. 계정 mig_mon, 비밀번호는 Grafana .env
#   - 대시보드 : "V2 이관 리허설" (ProxySQL 전환 상태 · 복제 · 잠금/트랜잭션 · 행 수 대조 · RDS CloudWatch)
# -----------------------------------------------------------------------------

locals {
  migration_scrape_targets = local.migration_monitoring_enabled ? [
    {
      job          = "migration-proxysql"
      stage        = "stg"
      service      = "proxysql"
      targets      = ["${aws_instance.migration_v1_sim[0].private_ip}:${local.migration_ports.metrics}"]
      metrics_path = "/metrics"
    },
  ] : []

  migration_mysql_datasources = local.migration_monitoring_enabled ? [
    {
      name         = "Migration V1 (v1-sim)"
      uid          = "mysql-mig-v1"
      url          = "${aws_instance.migration_v1_sim[0].private_ip}:${local.migration_ports.relay}"
      user         = "mig_mon"
      password_env = "MIGRATION_DB_MON_PASSWORD"
    },
    {
      name         = "Migration RDS (stg)"
      uid          = "mysql-mig-rds"
      url          = "${data.aws_db_instance.migration_stg[0].address}:${data.aws_db_instance.migration_stg[0].port}"
      user         = "mig_mon"
      password_env = "MIGRATION_DB_MON_PASSWORD"
    },
  ] : []

  migration_dashboards = local.migration_monitoring_enabled ? {
    "migration.json" = templatefile("${local.migration_template_dir}/dashboard.json.tftpl", {
      rds_identifier     = var.migration_stg_rds_identifier
      v1_sim_instance_id = aws_instance.migration_v1_sim[0].id
    })
  } : {}
}

# -----------------------------------------------------------------------------
# 출력
# -----------------------------------------------------------------------------

output "migration" {
  description = "이관 리허설 환경 (migration_rehearsal_enabled = true일 때). 값 입력·접속 명령은 런북 참고"
  value = local.migration_enabled ? {
    v1_sim_instance_id = aws_instance.migration_v1_sim[0].id
    v1_sim_private_ip  = aws_instance.migration_v1_sim[0].private_ip
    v1_sim_sg_id       = aws_security_group.migration_v1_sim[0].id
    v1_sim_role_name   = aws_iam_role.migration_v1_sim[0].name
    ssm_session        = "aws ssm start-session --target ${aws_instance.migration_v1_sim[0].id}"
    relay_endpoint     = "${aws_instance.migration_v1_sim[0].private_ip}:${local.migration_ports.relay}"
    bucket             = aws_s3_bucket.migration[0].bucket
    d0_upload_prefix   = "s3://${aws_s3_bucket.migration[0].bucket}/dumps/d0/"
    stg_rds_address    = data.aws_db_instance.migration_stg[0].address
    stg_rds_sg_ids     = sort(tolist(local.migration_stg_rds_sg_ids))
    stg_rds_secret_arn = local.migration_rds_secret_arn
    secret_parameters  = merge({ for k, p in aws_ssm_parameter.migration : k => p.name }, { MIGRATION_DB_MON_PASSWORD = aws_ssm_parameter.migration_mon_password[0].name })
    v1_sim_url         = var.migration_v1_sim_host == null ? null : "${local.nonprod_tls_enabled ? "https" : "http"}://${var.migration_v1_sim_host}"
    grafana_datasource = [for d in local.migration_mysql_datasources : d.uid]
  } : null
}
