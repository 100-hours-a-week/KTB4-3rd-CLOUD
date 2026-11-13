# =============================================================================
# stg 데이터 계층 스위치 — var.stg_data_layer_enabled (절차: STG_DATA_LAYER_TOGGLE.md)
#
#   MSK Provisioned와 ElastiCache는 중지 기능이 없어 끌 때 클러스터를 삭제하고 켤 때 다시 만든다.
#   다시 만들 때 필요한 것과 다른 스택이 이름으로 찾는 것은 남긴다.
#     남김 : MSK·Redis 보안그룹과 인바운드 규칙 (v3/eks/security.tf가 이름으로 조회한다)
#            KAFKA_BOOTSTRAP_SERVERS·REDIS_HOST SSM 파라미터 (ECS secrets·V3 External Secrets가 참조한다)
#            MSK 설정, 세 번째 AZ 서브넷, kafka-init 태스크 정의, 로그 그룹
#     삭제 : aws_msk_cluster.kafka["stg"], 스토리지 오토스케일링, MSK·Redis 알람, Prometheus MSK 수집 대상,
#            aws_elasticache_replication_group.redis["stg"]
#   꺼진 동안 SSM 주소 값은 local.stg_data_layer_paused_host로 바뀐다. 켜면 새 엔드포인트로 돌아오며,
#   클라이언트는 재배포해야 새 값을 읽는다.
#
#   stg RDS는 Terraform 밖(CLI)에 있어 이 스위치로 삭제하지 않는다. 실제로 중지할 수 있으므로
#   scripts/stg-data-layer.sh가 중지·시작하고, 꺼진 동안에는 아래 스케줄이 매일 다시 중지해
#   AWS의 7일 자동 시작을 막는다. 이미 중지 상태면 호출이 실패하고 끝나며 상태는 바뀌지 않는다.
# =============================================================================

locals {
  stg_data_layer_paused_stages = var.stg_data_layer_enabled ? toset([]) : toset(["stg"])

  # 꺼진 동안 SSM 주소에 넣는 값. .invalid는 DNS 조회가 항상 실패하는 예약 도메인이다.
  stg_data_layer_paused_host = "stg-data-layer-paused.invalid"

  # 실제 클러스터를 둘 스테이지. 보안그룹·SSM은 msk_active_stages·redis_stages 기준으로 남는다.
  msk_running_stages   = setsubtract(local.msk_active_stages, local.stg_data_layer_paused_stages)
  redis_running_stages = setsubtract(local.redis_stages, local.stg_data_layer_paused_stages)

  stg_rds_keep_stopped = !var.stg_data_layer_enabled
}

# -----------------------------------------------------------------------------
# stg RDS 중지 유지 스케줄 (꺼진 동안만 존재)
# -----------------------------------------------------------------------------

resource "aws_iam_role" "stg_rds_keep_stopped" {
  count = local.stg_rds_keep_stopped ? 1 : 0

  name               = "${var.project_name}-stg-rds-keep-stopped"
  description        = "EventBridge Scheduler role that re-stops the V2 stg RDS while the stg data layer is off"
  assume_role_policy = data.aws_iam_policy_document.dev_instance_scheduler_assume.json
}

data "aws_iam_policy_document" "stg_rds_keep_stopped" {
  count = local.stg_rds_keep_stopped ? 1 : 0

  statement {
    sid       = "StopStgRdsOnly"
    actions   = ["rds:StopDBInstance"]
    resources = ["arn:${data.aws_partition.current.partition}:rds:${var.aws_region}:${data.aws_caller_identity.current.account_id}:db:${var.stg_rds_identifier}"]
  }
}

resource "aws_iam_role_policy" "stg_rds_keep_stopped" {
  count = local.stg_rds_keep_stopped ? 1 : 0

  name   = "stop-stg-rds"
  role   = aws_iam_role.stg_rds_keep_stopped[0].id
  policy = data.aws_iam_policy_document.stg_rds_keep_stopped[0].json
}

resource "aws_scheduler_schedule" "stg_rds_keep_stopped" {
  count = local.stg_rds_keep_stopped ? 1 : 0

  name        = "${var.project_name}-stg-rds-keep-stopped"
  description = "Re-stop V2 stg RDS daily while stg_data_layer_enabled = false (AWS auto-starts after 7 days)"

  schedule_expression          = var.stg_rds_keep_stopped_cron
  schedule_expression_timezone = "Asia/Seoul"
  state                        = "ENABLED"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = "arn:${data.aws_partition.current.partition}:scheduler:::aws-sdk:rds:stopDBInstance"
    role_arn = aws_iam_role.stg_rds_keep_stopped[0].arn
    input = jsonencode({
      DbInstanceIdentifier = var.stg_rds_identifier
    })

    # 이미 중지 상태면 InvalidDBInstanceState로 실패한다. 재시도해도 결과가 같으므로 하지 않는다.
    retry_policy {
      maximum_event_age_in_seconds = 3600
      maximum_retry_attempts       = 0
    }
  }

  depends_on = [aws_iam_role_policy.stg_rds_keep_stopped]
}
