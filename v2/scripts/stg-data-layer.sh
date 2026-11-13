#!/usr/bin/env bash
# V2 stg 데이터 계층(MSK, ElastiCache Redis, RDS) 끄기·켜기. 절차와 배경: v2/STG_DATA_LAYER_TOGGLE.md
#
#   사용법 (v2 디렉터리 밖에서 실행해도 된다):
#     v2/scripts/stg-data-layer.sh status   # 현재 상태만 조회
#     v2/scripts/stg-data-layer.sh down     # terraform.tfvars의 stg_data_layer_enabled = false 후 실행
#     v2/scripts/stg-data-layer.sh up       # terraform.tfvars의 stg_data_layer_enabled = true 후 실행
#
#   down : 사용 중 확인 → stg MSK·Redis만 -target apply로 삭제 → stg RDS 중지
#   up   : stg RDS 시작 → stg MSK·Redis만 -target apply로 생성(30~40분) → RDS 대기 → kafka-init 토픽 생성
#   apply는 Terraform의 확인 프롬프트를 그대로 거친다. 전체 apply는 하지 않는다(다른 미적용 변경이 섞인다).
#   필요: terraform, aws(자격 증명, 기본 AWS_PROFILE=moyeota-terraform), jq
set -Euo pipefail

V2_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export AWS_PROFILE="${AWS_PROFILE:-moyeota-terraform}"
export AWS_REGION="${AWS_REGION:-ap-northeast-2}"
PROJECT=moyeota-v2
MSK_NAME="${PROJECT}-stg"
REDIS_ID="${PROJECT}-stg-redis"
RDS_ID="${STG_RDS_ID:-moyeota-v2-stg}"
ECS_CLUSTER="${PROJECT}-stg"
EKS_CLUSTER=moyeota-v3-eks

TARGETS=(
  -target='aws_msk_cluster.kafka["stg"]'
  -target='aws_appautoscaling_target.msk_storage["stg"]'
  -target='aws_appautoscaling_policy.msk_storage["stg"]'
  -target='aws_ssm_parameter.kafka_bootstrap_servers["stg"]'
  -target='aws_elasticache_replication_group.redis["stg"]'
  -target='aws_ssm_parameter.broker["stg/broker/REDIS_HOST"]'
  -target=aws_cloudwatch_metric_alarm.redis
  -target=aws_cloudwatch_metric_alarm.msk_disk
  -target=aws_cloudwatch_metric_alarm.msk_offline_partitions
  -target=aws_cloudwatch_metric_alarm.msk_active_controller
  -target=aws_scheduler_schedule.stg_rds_keep_stopped
)

info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mWARN\033[0m %s\n' "$*"; }
die()  { printf '\033[31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

for bin in terraform aws jq; do
  command -v "$bin" >/dev/null || die "missing: $bin"
done

tfvars_flag() {
  sed -nE 's/^[[:space:]]*stg_data_layer_enabled[[:space:]]*=[[:space:]]*(true|false).*/\1/p' "$V2_DIR/terraform.tfvars" | tail -1
}

msk_state() {
  aws kafka list-clusters-v2 --cluster-name-filter "$MSK_NAME" \
    --query "ClusterInfoList[?ClusterName=='${MSK_NAME}'].State | [0]" --output text 2>/dev/null
}

redis_state() {
  aws elasticache describe-replication-groups --replication-group-id "$REDIS_ID" \
    --query 'ReplicationGroups[0].Status' --output text 2>/dev/null || echo "없음"
}

rds_state() {
  aws rds describe-db-instances --db-instance-identifier "$RDS_ID" \
    --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || echo "없음"
}

ssm_value() {
  aws ssm get-parameter --name "$1" --query 'Parameter.Value' --output text 2>/dev/null || echo "없음"
}

status() {
  local prefix
  prefix=$(sed -nE 's/^[[:space:]]*config_path_prefix[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$V2_DIR/terraform.tfvars" | tail -1)
  prefix="${prefix:-moyeota/v2}"
  echo "tfvars stg_data_layer_enabled : $(tfvars_flag)"
  echo "MSK   ${MSK_NAME}           : $(msk_state)"
  echo "Redis ${REDIS_ID}     : $(redis_state)"
  echo "RDS   ${RDS_ID}           : $(rds_state)"
  echo "SSM   KAFKA_BOOTSTRAP_SERVERS : $(ssm_value "/${prefix}/stg/broker/KAFKA_BOOTSTRAP_SERVERS" | cut -c1-60)"
  echo "SSM   REDIS_HOST              : $(ssm_value "/${prefix}/stg/broker/REDIS_HOST")"
  echo "ECS   ${ECS_CLUSTER} running tasks : $(aws ecs describe-clusters --clusters "$ECS_CLUSTER" --query 'clusters[0].runningTasksCount' --output text 2>/dev/null)"
  echo "EKS   stg 노드그룹 desired      : $(stg_nodegroup_desired)"
}

stg_nodegroup_desired() {
  local total=0 ng n
  for ng in $(aws eks list-nodegroups --cluster-name "$EKS_CLUSTER" --query 'nodegroups[?starts_with(@, `stg`)]' --output text 2>/dev/null); do
    n=$(aws eks describe-nodegroup --cluster-name "$EKS_CLUSTER" --nodegroup-name "$ng" --query 'nodegroup.scalingConfig.desiredSize' --output text)
    total=$((total + n))
  done
  echo "$total"
}

tf_apply() {
  info "terraform apply (stg 데이터 계층 대상만)"
  (cd "$V2_DIR" && terraform apply "${TARGETS[@]}")
}

down() {
  [[ "$(tfvars_flag)" == "false" ]] || die "terraform.tfvars에서 stg_data_layer_enabled = false로 바꾼 뒤 실행한다."

  info "사용 중인지 확인"
  local tasks nodes
  tasks=$(aws ecs describe-clusters --clusters "$ECS_CLUSTER" --query 'clusters[0].runningTasksCount' --output text)
  nodes=$(stg_nodegroup_desired)
  # alloy DAEMON 태스크는 호스트가 있으면 함께 뜬다. 앱 서비스 desired 합으로 판단한다.
  local app_desired=0 services
  services=$(aws ecs list-services --cluster "$ECS_CLUSTER" --query 'serviceArns' --output text | tr '\t' '\n' | grep -v alloy | tr '\n' ' ')
  if [[ -n "${services// /}" ]]; then
    # shellcheck disable=SC2086
    app_desired=$(aws ecs describe-services --cluster "$ECS_CLUSTER" --services $services --query 'sum(services[].desiredCount)' --output text)
  fi
  echo "  stg ECS 실행 태스크 ${tasks}개, 앱 서비스 desired 합 ${app_desired}, EKS stg 노드 desired ${nodes}"
  if [[ "${app_desired}" != "0" || "$nodes" != "0" ]]; then
    warn "stg 앱이 아직 떠 있다. 끄면 Kafka·Redis·DB 연결이 끊긴다."
    read -r -p "그래도 계속할까? [y/N] " ans
    [[ "$ans" == "y" ]] || die "중단"
  fi

  tf_apply || die "terraform apply 실패"

  case "$(rds_state)" in
    available)
      info "stg RDS 중지 (${RDS_ID})"
      aws rds stop-db-instance --db-instance-identifier "$RDS_ID" --query 'DBInstance.DBInstanceStatus' --output text
      ;;
    stopped|stopping) info "stg RDS는 이미 $(rds_state)" ;;
    *) warn "stg RDS 상태 $(rds_state) — 중지하지 않았다. available이 된 뒤 다시 실행하거나 매일 05:00 스케줄을 기다린다." ;;
  esac

  info "완료"
  status
}

up() {
  [[ "$(tfvars_flag)" == "true" ]] || die "terraform.tfvars에서 stg_data_layer_enabled = true로 바꾼 뒤 실행한다."

  # RDS 시작이 가장 먼저 끝나므로 먼저 걸어 두고 apply와 겹쳐서 기다린다
  case "$(rds_state)" in
    stopped)
      info "stg RDS 시작 (${RDS_ID})"
      aws rds start-db-instance --db-instance-identifier "$RDS_ID" --query 'DBInstance.DBInstanceStatus' --output text
      ;;
    *) info "stg RDS 상태 $(rds_state) — 시작 호출 생략" ;;
  esac

  tf_apply || die "terraform apply 실패"

  info "stg RDS available 대기"
  aws rds wait db-instance-available --db-instance-identifier "$RDS_ID" || warn "RDS 대기 시간 초과 — 상태를 직접 확인한다."

  info "kafka-init 토픽 생성 (stg ECS 호스트가 없으면 Capacity Provider가 1대 띄울 때까지 PENDING)"
  local cmd task_arn exit_code
  cmd=$(cd "$V2_DIR" && terraform output -json msk_kafka_init_run_commands | jq -r '.stg // empty')
  [[ -n "$cmd" ]] || die "msk_kafka_init_run_commands.stg 출력이 없다."
  task_arn=$(eval "$cmd --query 'tasks[0].taskArn' --output text")
  echo "  task: $task_arn"
  aws ecs wait tasks-stopped --cluster "$ECS_CLUSTER" --tasks "$task_arn" || warn "kafka-init 대기 시간 초과"
  exit_code=$(aws ecs describe-tasks --cluster "$ECS_CLUSTER" --tasks "$task_arn" --query 'tasks[0].containers[0].exitCode' --output text)
  if [[ "$exit_code" == "0" ]]; then
    info "kafka-init 성공"
  else
    warn "kafka-init exit=${exit_code} — 로그: /ecs/${ECS_CLUSTER}/kafka-init"
  fi

  info "완료. 클라이언트는 새 주소를 읽도록 재배포해야 한다 (STG_DATA_LAYER_TOGGLE.md 4장)."
  status
}

case "${1:-}" in
  status) status ;;
  down)   down ;;
  up)     up ;;
  *) echo "usage: $0 {status|down|up}"; exit 2 ;;
esac
