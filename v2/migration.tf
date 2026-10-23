# =============================================================================
# V1 Prod → V2 Stg DB 이관 리허설 (binlog 복제 + ProxySQL 컷오버)
#   런북: v2/MIGRATION_REHEARSAL.md
#
#   migration_rehearsal_enabled = false(기본)면 아무것도 만들지 않는다. 리허설이 끝나면 false로 apply해 전부 지운다.
#   리허설 기간에만 쓰는 리소스라 변수·출력도 이 파일에 모아 둔다 (지울 때 파일 하나만 보면 된다).
#
#   새 EC2는 만들지 않는다 (EC2 vCPU 한도). 소스는 기존 V1 Prod EC2의 MySQL 컨테이너다.
#   V1 Prod 호스트에는 기존 Compose 프로젝트(moyeota)를 건드리지 않는 별도 프로젝트(moyeota-migration)로 사이드카만 띄운다.
#     proxysql : app·database 네트워크(외부 네트워크로 참조), 6033(앱) · 6032(관리, 호스트 루프백) · 6070(exporter, 사설 IP)
#                hg10 = V1 MySQL(ONLINE) + stg RDS(OFFLINE_HARD)
#     relay    : socat. 호스트 사설 IP:3307 → V1 MySQL:3306 (database 네트워크가 internal이라 MySQL은 포트를 게시할 수 없다)
#     migcli   : host 네트워크 mysql 클라이언트 (보류 구간 SQL 호출용)
#   설정 파일은 이관 버킷 config/에 올리고, V1 Prod에서 `sudo mig render`로 받는다.
#
#   네트워크 경로 (V1과 V2는 같은 VPC — 피어링·엔드포인트 없이 SG 규칙만 더한다)
#     stg RDS ─3307→ V1 relay                      (정방향 복제: RDS가 V1 binlog를 가져감)
#     V1 ─3306→ stg RDS                            (S1 적재, S5 이후 ProxySQL writer, S6 역방향 복제)
#     모니터링 ─3307→ V1 relay, ─3306→ stg RDS      (Grafana MySQL 데이터소스 — ProxySQL을 거치지 않는다)
#     모니터링 ─6070→ V1 ProxySQL exporter          (Prometheus 정적 타깃)
#     stg RDS SG(CLI 생성)는 기본 아웃바운드 전체 허용이라 RDS → V1 3307 아웃바운드 규칙은 두지 않는다
#
#   V1 Prod 쪽 변경 (V1 state 밖에서 덧붙이고 false apply로 걷는다)
#     - V1 Prod SG: 인바운드 3307(stg RDS·모니터링), 6070(모니터링), 아웃바운드 3306(stg RDS)
#       V1 SG 규칙은 infra/ 인라인 블록 소유다 → 리허설이 끝날 때까지 infra/ apply 금지 (이 규칙들이 지워진다)
#     - V1 Prod EC2 Role: 이 파일의 인라인 정책 하나 (SSM 비밀값·stg RDS master 시크릿·이관 버킷 config/ 읽기)
#
#   비밀값: Terraform은 SSM 파라미터 자리만 만든다(CHANGE_ME + ignore_changes). 값은 CLI로 넣는다 (ssm.tf 원칙)
#     /moyeota/v2/migration/REPL_PASSWORD, PROXYSQL_ADMIN_PASSWORD
#     /moyeota/v2/monitoring/MIGRATION_DB_MON_PASSWORD 조회 계정(mig_mon) — V1 Prod·모니터링 호스트가 같이 읽는다
#     ProxySQL 앱 계정은 stg 값(/moyeota/v2/stg/backend/DB_NAME·DB_USERNAME·DB_PASSWORD)을 쓴다
#       → S0에서 V1 backend를 proxysql:6033 + stg 앱 계정으로 재생성한다 (V1 Prod 비밀번호를 stg로 복사하지 않는다)
#     V1 MySQL root는 SSM에 두지 않고 V1 MySQL 컨테이너의 MYSQL_ROOT_PASSWORD 환경변수를 컨테이너 안에서 쓴다
#
#   지우는 순서: V1 Prod에서 `sudo mig teardown` → 이 파일을 false로 apply → stg RDS 복원·정리
# =============================================================================

variable "migration_rehearsal_enabled" {
  description = "true면 V1 Prod → stg 이관 리허설 연결(SG 규칙·V1 Role 정책·이관 버킷·Grafana 연결)을 만든다. 리허설이 끝나면 false로 apply한다."
  type        = bool
  default     = false

  validation {
    condition     = !var.migration_rehearsal_enabled || var.migration_v1_prod_instance_id != null
    error_message = "migration_rehearsal_enabled = true면 migration_v1_prod_instance_id가 필요하다."
  }
}

variable "migration_stg_rds_identifier" {
  description = "리허설 대상 stg RDS (Claude outputs/stg-rds-create.sh가 만든 인스턴스). 없으면 plan이 실패한다."
  type        = string
  default     = "moyeota-v2-stg"
}

variable "migration_v1_prod_instance_id" {
  description = "리허설 소스 V1 Prod EC2 ID (infra/ state: aws_instance.ec2[\"prod\"]). 사설 IP·보안 그룹·IAM Role을 여기서 읽는다."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.migration_v1_prod_instance_id == null || can(regex("^i-[0-9a-f]{8,17}$", var.migration_v1_prod_instance_id))
    error_message = "migration_v1_prod_instance_id must be an EC2 instance ID (i-...)."
  }
}

variable "migration_v1_compose" {
  description = "V1 Prod 호스트의 기존 Compose 이름 (deploy/v1-compose.yaml, APP_ENV=prod 기준). mig check가 실제 값과 대조한다."
  type = object({
    deploy_path       = optional(string, "/opt/moyeota")
    mysql_container   = optional(string, "moyeota-mysql-1")
    backend_container = optional(string, "moyeota-backend-1")
    app_network       = optional(string, "moyeota-app-prod")
    db_network        = optional(string, "moyeota-db-prod")
  })
  default = {}
}

variable "migration_images" {
  description = "V1 Prod 사이드카 이미지 (버전 고정). mysql은 클라이언트 전용(V1·stg RDS와 같은 8.4), ProxySQL은 caching_sha2_password를 지원하는 2.6.0 이상."
  type = object({
    mysql    = optional(string, "mysql:8.4.11")
    proxysql = optional(string, "proxysql/proxysql:2.7.2")
    socat    = optional(string, "alpine/socat:1.8.0.0")
  })
  default = {}
}

# -----------------------------------------------------------------------------
# 공통 값
# -----------------------------------------------------------------------------

locals {
  migration_enabled = var.migration_rehearsal_enabled

  migration_name      = "${var.project_name}-stg-migration"
  migration_ssm_path  = "/${var.config_path_prefix}/migration"
  migration_mon_param = "/${var.config_path_prefix}/monitoring/MIGRATION_DB_MON_PASSWORD"
  migration_stg_db    = "/${var.config_path_prefix}/stg/backend"

  migration_ports = {
    mysql   = 3306
    relay   = var.rds_migration_relay_port
    metrics = 6070
  }

  migration_secret_keys = {
    REPL_PASSWORD           = "복제 계정 repl 비밀번호 — V1 Prod·stg RDS 양쪽 같은 값 (정방향·역방향 복제)"
    PROXYSQL_ADMIN_PASSWORD = "ProxySQL 원격 관리 계정 radmin 비밀번호 (기본 admin 계정은 컨테이너 안 루프백 전용)"
  }

  migration_stg_rds_sg_ids = local.migration_enabled ? toset(data.aws_db_instance.migration_stg[0].vpc_security_groups) : toset([])
  migration_rds_secret_arn = local.migration_enabled ? try(data.aws_db_instance.migration_stg[0].master_user_secret[0].secret_arn, null) : null

  migration_v1_sg_id     = local.migration_enabled ? one(data.aws_instance.migration_v1_prod[0].vpc_security_group_ids) : null
  migration_v1_ip        = local.migration_enabled ? data.aws_instance.migration_v1_prod[0].private_ip : null
  migration_v1_role_name = local.migration_enabled ? data.aws_iam_instance_profile.migration_v1_prod[0].role_name : null

  migration_monitoring_enabled = local.migration_enabled && local.monitoring_enabled
}

data "aws_db_instance" "migration_stg" {
  count = local.migration_enabled ? 1 : 0

  db_instance_identifier = var.migration_stg_rds_identifier
}

data "aws_instance" "migration_v1_prod" {
  count = local.migration_enabled ? 1 : 0

  instance_id = var.migration_v1_prod_instance_id

  lifecycle {
    postcondition {
      condition     = length(self.vpc_security_group_ids) == 1
      error_message = "V1 Prod EC2에 보안 그룹이 하나만 붙어 있어야 한다 (이관 규칙을 붙일 SG를 하나로 정한다)."
    }
    postcondition {
      condition     = self.iam_instance_profile != null && self.iam_instance_profile != ""
      error_message = "V1 Prod EC2에 인스턴스 프로파일이 없다."
    }
  }
}

data "aws_iam_instance_profile" "migration_v1_prod" {
  count = local.migration_enabled ? 1 : 0

  name = data.aws_instance.migration_v1_prod[0].iam_instance_profile
}

# -----------------------------------------------------------------------------
# 비밀값 자리 (SSM SecureString, 값은 CLI)
# -----------------------------------------------------------------------------

resource "aws_ssm_parameter" "migration" {
  for_each = local.migration_enabled ? local.migration_secret_keys : {}

  name        = "${local.migration_ssm_path}/${each.key}"
  description = each.value
  type        = "SecureString"
  value       = "CHANGE_ME"

  tags = {
    Stage   = "stg"
    Purpose = "migration-rehearsal"
  }

  lifecycle {
    ignore_changes = [value]
  }
}

# Grafana MySQL 데이터소스·ProxySQL monitor·V1 Prod 사이드카가 같이 쓰는 조회 계정(mig_mon) 비밀번호
#   모니터링 호스트는 /<prefix>/monitoring/*만 읽으므로 이 경로에 둔다 (modules/monitoring/templates/sync.sh → Grafana .env)
resource "aws_ssm_parameter" "migration_mon_password" {
  count = local.migration_enabled ? 1 : 0

  name        = local.migration_mon_param
  description = "이관 리허설 조회 계정 mig_mon 비밀번호 (V1 Prod·stg RDS 같은 값). Grafana MySQL 데이터소스·ProxySQL monitor"
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
# 이관 버킷 — config/ 만 쓴다 (compose, proxysql.cnf 템플릿, mig·cutover-switch, migration.env)
#   덤프는 버킷에 두지 않는다. S1은 V1 Prod의 root 전용 임시 경로에서 바로 stg RDS로 적재한다.
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
}

resource "aws_s3_bucket_policy" "migration" {
  count = local.migration_enabled ? 1 : 0

  bucket = aws_s3_bucket.migration[0].id
  policy = data.aws_iam_policy_document.migration_bucket[0].json

  depends_on = [aws_s3_bucket_public_access_block.migration]
}

# 사이드카 설정 파일 — 바꾸면 apply 후 V1 Prod에서 `sudo mig render`로 반영한다
#   S3(쓰기 보류)~S9(관찰 창) 사이에는 render를 다시 돌리지 않는다 (ProxySQL이 재생성될 수 있다)
locals {
  migration_template_dir = "${path.module}/templates/migration"

  migration_config_files = local.migration_enabled ? {
    "compose.yaml"       = file("${local.migration_template_dir}/compose.yaml")
    "proxysql.cnf.tpl"   = file("${local.migration_template_dir}/proxysql.cnf.tpl")
    "bin/mig"            = file("${local.migration_template_dir}/mig.sh")
    "bin/cutover-switch" = file("${local.migration_template_dir}/cutover-switch.sh")

    # 비밀이 아닌 실행 값 (mig·cutover-switch가 source한다)
    "migration.env" = join("\n", [
      "AWS_REGION=${var.aws_region}",
      "SSM_PATH=${local.migration_ssm_path}",
      "MON_PASSWORD_PARAM=${local.migration_mon_param}",
      "STG_DB_PARAM_PATH=${local.migration_stg_db}",
      "RDS_HOST=${data.aws_db_instance.migration_stg[0].address}",
      "RDS_PORT=${data.aws_db_instance.migration_stg[0].port}",
      "RDS_SECRET_ARN=${coalesce(local.migration_rds_secret_arn, "NONE")}",
      "RELAY_PORT=${local.migration_ports.relay}",
      "V1_INSTANCE_ID=${var.migration_v1_prod_instance_id}",
      "V1_PRIVATE_IP=${local.migration_v1_ip}",
      "V1_DEPLOY_PATH=${var.migration_v1_compose.deploy_path}",
      "V1_MYSQL_CONTAINER=${var.migration_v1_compose.mysql_container}",
      "V1_BACKEND_CONTAINER=${var.migration_v1_compose.backend_container}",
      "V1_APP_NETWORK=${var.migration_v1_compose.app_network}",
      "V1_DB_NETWORK=${var.migration_v1_compose.db_network}",
      "MYSQL_IMAGE=${var.migration_images.mysql}",
      "PROXYSQL_IMAGE=${var.migration_images.proxysql}",
      "SOCAT_IMAGE=${var.migration_images.socat}",
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
# 보안 그룹 규칙 — V1 Prod SG ↔ stg RDS SG
# -----------------------------------------------------------------------------

# 정방향 복제: stg RDS가 V1 relay(3307)로 접속해 V1 binlog를 가져간다
resource "aws_vpc_security_group_ingress_rule" "migration_v1_relay_from_stg_rds" {
  for_each = local.migration_stg_rds_sg_ids

  security_group_id            = local.migration_v1_sg_id
  description                  = "Stg migration: stg RDS pulls V1 binlog via relay"
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = local.migration_ports.relay
  to_port                      = local.migration_ports.relay
}

# V1 Prod → stg RDS: S1 적재, ProxySQL writer(S5~), 역방향 복제(S6). V1 SG 아웃바운드는 infra/ 기준 443만 있다
resource "aws_vpc_security_group_egress_rule" "migration_v1_to_stg_rds" {
  for_each = local.migration_stg_rds_sg_ids

  security_group_id            = local.migration_v1_sg_id
  description                  = "Stg migration: MySQL to stg RDS (dump load, ProxySQL, reverse replication)"
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = local.migration_ports.mysql
  to_port                      = local.migration_ports.mysql
}

resource "aws_vpc_security_group_ingress_rule" "migration_stg_rds_from_v1" {
  for_each = local.migration_stg_rds_sg_ids

  security_group_id            = each.value
  description                  = "Stg migration: MySQL from V1 Prod EC2 (dump load, ProxySQL, reverse replication)"
  referenced_security_group_id = local.migration_v1_sg_id
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

resource "aws_vpc_security_group_ingress_rule" "migration_v1_relay_from_monitoring" {
  count = local.migration_monitoring_enabled ? 1 : 0

  security_group_id            = local.migration_v1_sg_id
  description                  = "Stg migration: V1 MySQL via relay from monitoring host"
  referenced_security_group_id = aws_security_group.monitoring[0].id
  ip_protocol                  = "tcp"
  from_port                    = local.migration_ports.relay
  to_port                      = local.migration_ports.relay
}

resource "aws_vpc_security_group_ingress_rule" "migration_v1_metrics_from_monitoring" {
  count = local.migration_monitoring_enabled ? 1 : 0

  security_group_id            = local.migration_v1_sg_id
  description                  = "Stg migration: ProxySQL exporter from monitoring host"
  referenced_security_group_id = aws_security_group.monitoring[0].id
  ip_protocol                  = "tcp"
  from_port                    = local.migration_ports.metrics
  to_port                      = local.migration_ports.metrics
}

# -----------------------------------------------------------------------------
# V1 Prod EC2 Role — 리허설 기간 인라인 정책 하나 (infra/의 Role·기존 정책은 건드리지 않는다)
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "migration_v1_prod" {
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

  # stg RDS master 비밀번호 (RDS 관리형 시크릿) — 계정 생성·복제 프로시저 호출·S1 적재용
  dynamic "statement" {
    for_each = local.migration_rds_secret_arn == null ? [] : [local.migration_rds_secret_arn]

    content {
      sid       = "ReadStgRdsMasterSecret"
      actions   = ["secretsmanager:GetSecretValue"]
      resources = [statement.value]
    }
  }

  statement {
    sid       = "ListMigrationConfig"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.migration[0].arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["config/*"]
    }
  }

  statement {
    sid       = "ReadMigrationConfig"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.migration[0].arn}/config/*"]
  }
}

resource "aws_iam_role_policy" "migration_v1_prod" {
  count = local.migration_enabled ? 1 : 0

  name   = local.migration_name
  role   = local.migration_v1_role_name
  policy = data.aws_iam_policy_document.migration_v1_prod[0].json
}

# -----------------------------------------------------------------------------
# 모니터링 연결 (monitoring.tf module "monitoring"에 넘긴다)
#   - Prometheus 정적 타깃 : ProxySQL exporter (V1 Prod 사설 IP:6070/metrics)
#   - Grafana MySQL 데이터소스 : V1 = relay 3307, RDS = 3306 직접. 계정 mig_mon, 비밀번호는 Grafana .env
#   - 대시보드 : "V2 이관 리허설" (ProxySQL 전환 상태 · 복제 · 잠금/트랜잭션 · 행 수 대조 · CloudWatch)
# -----------------------------------------------------------------------------

locals {
  migration_scrape_targets = local.migration_monitoring_enabled ? [
    {
      job          = "migration-proxysql"
      stage        = "stg"
      service      = "proxysql"
      targets      = ["${local.migration_v1_ip}:${local.migration_ports.metrics}"]
      metrics_path = "/metrics"
    },
  ] : []

  migration_mysql_datasources = local.migration_monitoring_enabled ? [
    {
      name         = "Migration V1 (prod)"
      uid          = "mysql-mig-v1"
      url          = "${local.migration_v1_ip}:${local.migration_ports.relay}"
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
      rds_identifier = var.migration_stg_rds_identifier
      v1_instance_id = var.migration_v1_prod_instance_id
    })
  } : {}
}

# -----------------------------------------------------------------------------
# 출력
# -----------------------------------------------------------------------------

output "migration" {
  description = "이관 리허설 연결 (migration_rehearsal_enabled = true일 때). 값 입력·실행 순서는 런북 참고"
  value = local.migration_enabled ? {
    v1_instance_id     = var.migration_v1_prod_instance_id
    v1_private_ip      = local.migration_v1_ip
    v1_sg_id           = local.migration_v1_sg_id
    v1_role_name       = local.migration_v1_role_name
    ssm_session        = "aws ssm start-session --target ${var.migration_v1_prod_instance_id}"
    relay_endpoint     = "${local.migration_v1_ip}:${local.migration_ports.relay}"
    bucket             = aws_s3_bucket.migration[0].bucket
    stg_rds_address    = data.aws_db_instance.migration_stg[0].address
    stg_rds_sg_ids     = sort(tolist(local.migration_stg_rds_sg_ids))
    stg_rds_secret_arn = local.migration_rds_secret_arn
    secret_parameters  = merge({ for k, p in aws_ssm_parameter.migration : k => p.name }, { MIGRATION_DB_MON_PASSWORD = aws_ssm_parameter.migration_mon_password[0].name })
    grafana_datasource = [for d in local.migration_mysql_datasources : d.uid]
  } : null
}

# -----------------------------------------------------------------------------
# state 정리
# -----------------------------------------------------------------------------

# v1.moyeota.com은 V1 운영 레코드이고 리허설 부하 테스트의 V1_API_HOST로도 쓴다.
# 이 Terraform은 V1 DNS를 관리하지 않으므로 레코드는 남기고 state에서만 뺀다.
removed {
  from = aws_route53_record.v1_prod

  lifecycle {
    destroy = false
  }
}
