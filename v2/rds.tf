# =============================================================================
# RDS for MySQL (rds_stages = ["prod"]) — Single-AZ, 단일 writer, 읽기 복제본 없음
#   설계: wiki「V2 DB 인프라 설계」(최종 선택), 「V2 DB 무중단 마이그레이션 설계」1.2·7.1
#
#   - 엔진 8.4.11 (V1 Prod MySQL과 같은 버전. 낮은 버전 금지, 자동 마이너 업그레이드 끔)
#   - 파라미터 그룹 : time_zone=Asia/Seoul, utf8mb4 / utf8mb4_0900_ai_ci (RDS 기본 UTC면 NOW()가 9시간 어긋난다)
#   - 위치          : data-a(AZ-a, ECS 태스크와 같은 AZ). 서브넷 그룹은 data-a·data-b
#   - 백업          : 자동 백업·PITR (Single-AZ의 AZ 장애 대응 수단), 삭제 보호, 최종 스냅샷
#   - master 비밀번호 : RDS 관리형(Secrets Manager). state에 비밀번호가 남지 않는다
#   - 인바운드      : 같은 스테이지 rest·websocket 태스크 SG + rds_migration_source_security_group_ids(V1 Prod EC2, 이관 기간만)
#   - 이관 기간 복제 (Claude outputs/v2-stg-proxysql-migration-test-design.md)
#       정방향 V1 → RDS : RDS가 V1 binlog 중계(socat, <V1 사설 IP>:3307)로 접속 → RDS SG 아웃바운드 + V1 SG 인바운드 3307
#       역방향 RDS → V1 : V1 MySQL이 RDS 3306으로 접속 → RDS SG 인바운드 3306 (위)
#       binlog          : 백업 보존 ≥ 1이어야 RDS가 binlog를 남긴다. binlog retention hours는 CLI(mysql.rds_set_configuration)
#   - 앱 계정·DB_* SSM 값은 Terraform 밖에서 만든다 (ssm.tf 원칙: 값은 CLI)
#
#   stg RDS는 CLI(Claude outputs/stg-rds-create.sh)로 만들고 지운다 → 이름이 겹치지 않게 모든 이름에 스테이지를 넣는다
#   (CLI가 만든 moyeota-v2-mysql84 · moyeota-v2-data · moyeota-v2-stg-rds는 이 파일과 무관)
# =============================================================================

locals {
  rds_stages = toset(var.rds_stages)
  rds_port   = 3306

  # performance_schema는 정적 파라미터 → pending-reboot (생성 시에는 첫 기동에 반영된다). 이관 중 잠금·MDL·복제 상태 관측용
  rds_parameters = {
    time_zone            = { value = "Asia/Seoul", apply_method = "immediate" }
    character_set_server = { value = "utf8mb4", apply_method = "immediate" }
    collation_server     = { value = "utf8mb4_0900_ai_ci", apply_method = "immediate" }
    performance_schema   = { value = "1", apply_method = "pending-reboot" }
    sql_mode             = { value = "ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION", apply_method = "immediate" }
  }

  # "prod-v1-prod-ec2" → { stage, sg_id, name }
  rds_migration_sources = merge({}, [
    for stage in local.rds_stages : {
      for name, sg_id in var.rds_migration_source_security_group_ids : "${stage}-${name}" => {
        stage = stage
        name  = name
        sg_id = sg_id
      }
    }
  ]...)
}

resource "aws_db_subnet_group" "rds" {
  for_each = local.rds_stages

  name        = "${var.project_name}-${each.key}-db"
  description = "V2 ${each.key} RDS data subnets"
  subnet_ids  = [aws_subnet.v2["data_a"].id, aws_subnet.v2["data_b"].id]

  tags = {
    Name        = "${var.project_name}-${each.key}-db"
    Environment = each.key
  }
}

resource "aws_db_parameter_group" "mysql" {
  for_each = local.rds_stages

  name        = "${var.project_name}-${each.key}-mysql84"
  family      = "mysql8.4"
  description = "moyeota v2 ${each.key} mysql 8.4 (KST, utf8mb4)"

  dynamic "parameter" {
    for_each = local.rds_parameters

    content {
      name         = parameter.key
      value        = parameter.value.value
      apply_method = parameter.value.apply_method
    }
  }

  tags = {
    Environment = each.key
  }
}

resource "aws_security_group" "rds" {
  for_each = local.rds_stages

  name                   = "${var.project_name}-${each.key}-rds"
  description            = "RDS MySQL for ${each.key}; rest/websocket task SGs and migration sources only"
  vpc_id                 = data.aws_vpc.shared.id
  revoke_rules_on_delete = true

  tags = {
    Name        = "${var.project_name}-${each.key}-rds-sg"
    Environment = each.key
  }
}

# 같은 스테이지 rest·websocket 태스크만 (frontend·fastapi에는 데이터 계층 경로를 두지 않는다)
resource "aws_vpc_security_group_ingress_rule" "rds_from_tasks" {
  for_each = { for k, v in local.data_client_task_sgs : k => v if contains(local.rds_stages, v.stage) }

  security_group_id            = aws_security_group.rds[each.value.stage].id
  description                  = "MySQL from ${each.key} tasks"
  referenced_security_group_id = each.value.sg_id
  ip_protocol                  = "tcp"
  from_port                    = local.rds_port
  to_port                      = local.rds_port
}

# 이관 기간 임시 출발지 (V1 Prod EC2: 덤프 적재 + 컷오버 중 V1 backend의 RDS 연결) — V1 정리 후 변수에서 빼서 apply
resource "aws_vpc_security_group_ingress_rule" "rds_migration_source" {
  for_each = local.rds_migration_sources

  security_group_id            = aws_security_group.rds[each.value.stage].id
  description                  = "MySQL from ${each.value.name} (migration)"
  referenced_security_group_id = each.value.sg_id
  ip_protocol                  = "tcp"
  from_port                    = local.rds_port
  to_port                      = local.rds_port
}

# 정방향 복제: RDS(복제본)가 V1 binlog 중계로 나가는 연결. RDS SG에는 기본 아웃바운드가 없다
resource "aws_vpc_security_group_egress_rule" "rds_to_migration_source" {
  for_each = local.rds_migration_sources

  security_group_id            = aws_security_group.rds[each.value.stage].id
  description                  = "MySQL replication to ${each.value.name} binlog relay (migration)"
  referenced_security_group_id = each.value.sg_id
  ip_protocol                  = "tcp"
  from_port                    = local.rds_port
  to_port                      = var.rds_migration_relay_port
}

# 정방향 복제: V1 SG(V1 state 소유)에 RDS SG → 중계 포트 인바운드만 V2 state가 덧붙인다 (V1 SG 자체는 건드리지 않음)
resource "aws_vpc_security_group_ingress_rule" "migration_source_from_rds" {
  for_each = local.rds_migration_sources

  security_group_id            = each.value.sg_id
  description                  = "V2 ${each.value.stage} RDS binlog relay (migration)"
  referenced_security_group_id = aws_security_group.rds[each.value.stage].id
  ip_protocol                  = "tcp"
  from_port                    = var.rds_migration_relay_port
  to_port                      = var.rds_migration_relay_port
}

# V1 Prod EC2 → RDS 3306: S1 덤프 적재(P-6 접속 확인 포함), S5 이후 ProxySQL → RDS(writer), S6 V1 MySQL → RDS(역방향 복제)
# V1 SG 아웃바운드는 infra/ 인라인 규칙으로 443만 있다 → V2 state가 규칙만 덧붙인다.
# 이관이 끝날 때(S10)까지 infra/ apply 금지: 인라인 규칙 기준으로 이 규칙과 migration_source_from_rds가 지워진다
resource "aws_vpc_security_group_egress_rule" "migration_source_to_rds" {
  for_each = local.rds_migration_sources

  security_group_id            = each.value.sg_id
  description                  = "MySQL to V2 ${each.value.stage} RDS (migration)"
  referenced_security_group_id = aws_security_group.rds[each.value.stage].id
  ip_protocol                  = "tcp"
  from_port                    = local.rds_port
  to_port                      = local.rds_port
}

resource "aws_db_instance" "mysql" {
  for_each = local.rds_stages

  identifier     = "${var.project_name}-${each.key}"
  engine         = "mysql"
  engine_version = var.rds_engine_version
  instance_class = var.rds_instance_class
  port           = local.rds_port

  storage_type          = "gp3"
  allocated_storage     = var.rds_allocated_storage_gib
  max_allocated_storage = var.rds_max_allocated_storage_gib > 0 ? var.rds_max_allocated_storage_gib : null
  storage_encrypted     = true

  username                    = "admin"
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.rds[each.key].name
  parameter_group_name   = aws_db_parameter_group.mysql[each.key].name
  vpc_security_group_ids = [aws_security_group.rds[each.key].id]
  availability_zone      = local.az_a
  multi_az               = false
  publicly_accessible    = false

  # 백업 02:00–02:30 KST, 유지 관리 월 04:00–05:00 KST (출퇴근 피크 밖, 서로 겹치지 않게)
  backup_retention_period     = var.rds_backup_retention_days
  backup_window               = "17:00-17:30"
  maintenance_window          = "sun:19:00-sun:20:00"
  auto_minor_version_upgrade  = false
  allow_major_version_upgrade = false
  apply_immediately           = false

  copy_tags_to_snapshot     = true
  deletion_protection       = true
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.project_name}-${each.key}-final"

  tags = {
    Name        = "${var.project_name}-${each.key}"
    Environment = each.key
  }

  lifecycle {
    prevent_destroy = true
  }
}
