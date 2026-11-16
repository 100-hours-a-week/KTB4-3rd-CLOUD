#!/usr/bin/env bash
# ALB 규칙의 ECS·EKS 가중치를 바꾼다.
#   alb-weight.sh <dev|stg|prod> status
#   alb-weight.sh <dev|stg|prod> assert-attached   EKS Target Group 연결 여부만 확인
#   alb-weight.sh <dev|stg|prod> set <0|1|10|50|100> [--yes]
#   alb-weight.sh <dev|stg|prod> rollback [--yes]  EKS 0%로 즉시 복귀
#
# 환경 변수: DRY_RUN=1(변경 없이 내용 출력), CUTOVER_LOG(기록 파일)
# prod 가중치를 올릴 때는 TLS 조건(Redis 전송 암호화, RDS 필수 TLS, ALB→파드 HTTPS)을 확인한다. 줄일 때와 롤백은 막지 않는다.
#   미충족이면 중단한다. 리스크를 수용한 전환에서만 ACCEPT_TLS_GAP=yes로 경고를 남기고 진행한다.
# 주의: V2 terraform apply를 하면 규칙이 ECS 100%로 되돌아간다. 전환 기간에는 금지한다.
#
# 규칙은 우선순위가 아니라 "경로 조건 + V2 ECS Target Group(moyeota-v2-<stage>-<service>)"으로 찾는다.
#   우선순위는 바뀔 수 있다 (prod: 1·2·4 → 5·6·8, v4 규칙이 1·2·3을 쓴다. v3/docs/ECS_MINIMAL_OPS_TRANSITION.md 5.10절).
#   같은 경로의 다른 규칙은 대상 TG로 걸러진다: v4(moyeota-v4-prod-*), 옛 Compose(moyeota-v2-websocket·rest).
#   서비스마다 정확히 1개가 맞아야 진행한다.
set -euo pipefail

CUTOVER_LOG="${CUTOVER_LOG:-$HOME/.moyeota/cutover.log}"
DRY_RUN="${DRY_RUN:-0}"
LADDER=(0 1 10 50 100)
SERVICES=(websocket rest frontend)

stage="${1:-}"
command="${2:-}"
percent=""
assume_yes=0

die() {
  echo "오류: $*" >&2
  exit 1
}

case "$stage" in
  prod) alb_name="moyeota-v2-alb" ;;
  dev | stg) alb_name="moyeota-v2-nonprod-alb" ;;
  *) die "스테이지는 dev, stg, prod입니다: '$stage'" ;;
esac

case "$command" in
  status | assert-attached) ;;
  set)
    percent="${3:-}"
    case "$percent" in
      0 | 1 | 10 | 50 | 100) ;;
      *) die "가중치는 0, 1, 10, 50, 100 중 하나입니다: '$percent'" ;;
    esac
    [ "${4:-}" = "--yes" ] && assume_yes=1
    ;;
  rollback)
    percent=0
    [ "${3:-}" = "--yes" ] && assume_yes=1
    ;;
  *) die "명령은 status, assert-attached, set, rollback입니다: '$command'" ;;
esac

# 서비스 → V2 ECS 규칙의 경로 조건 (v2/locals.tf ecs_service_specs path_patterns)
path_of() {
  case "$1" in
    websocket) echo "/api/wss" ;;
    rest) echo "/api/*" ;;
    frontend) echo "/*" ;;
  esac
}

index_of() {
  local index
  for index in "${!SERVICES[@]}"; do
    [ "${SERVICES[$index]}" = "$1" ] && { echo "$index"; return 0; }
  done
  return 1
}

ecs_group_name() { echo "moyeota-v2-$stage-$1"; }
eks_group_name() { echo "moyeota-v3-eks-$stage-$1"; }

group_arn() {
  aws elbv2 describe-target-groups --names "$1" --query 'TargetGroups[0].TargetGroupArn' --output text
}

healthy_count() {
  aws elbv2 describe-target-health --target-group-arn "$1" --output json |
    jq '[.TargetHealthDescriptions[] | select(.TargetHealth.State == "healthy")] | length'
}

lb_arn="$(aws elbv2 describe-load-balancers --names "$alb_name" --query 'LoadBalancers[0].LoadBalancerArn' --output text)"
listener_arn="$(aws elbv2 describe-listeners --load-balancer-arn "$lb_arn" --query 'Listeners[?Port==`443`].ListenerArn | [0]' --output text)"
rules_json="$(aws elbv2 describe-rules --listener-arn "$listener_arn" --output json)"

# 규칙의 forward 대상 TG 목록. 단순 forward(TargetGroupArn)와 가중치 forward(ForwardConfig) 모두 다룬다.
JQ_TARGETS='(.Actions[0].ForwardConfig.TargetGroups // [{TargetGroupArn: .Actions[0].TargetGroupArn}]) | map(select(.TargetGroupArn != null))'

# 경로 조건이 같고 V2 ECS Target Group을 forward 대상으로 가진 규칙을 모두 찾는다 (JSON 배열).
find_rules() {
  jq -c --arg path "$(path_of "$1")" --arg tg "/$(ecs_group_name "$1")/" "
    [.Rules[]
      | select(any(.Conditions[]?; .Field == \"path-pattern\" and (((.PathPatternConfig.Values // .Values) // []) | index(\$path) != null)))
      | select(any(${JQ_TARGETS}[]; .TargetGroupArn | contains(\$tg)))]" <<<"$rules_json"
}

rule_json=()
rule_of() {
  echo "${rule_json[$(index_of "$1")]}"
}

# 규칙에서 해당 TG의 가중치를 출력한다. 연결되어 있지 않으면 빈 값이다. 단순 forward면 ECS 100으로 본다.
current_eks_weight() {
  jq -r --arg arn "$2" "${JQ_TARGETS} | map(select(.TargetGroupArn == \$arn)) | .[0] | if . == null then empty else (.Weight // 100) end" <<<"$(rule_of "$1")"
}

ecs_arn_from_rule() {
  jq -r --arg name "/$(ecs_group_name "$1")/" "${JQ_TARGETS} | map(select(.TargetGroupArn | contains(\$name))) | .[0].TargetGroupArn // empty" <<<"$(rule_of "$1")"
}

ecs_arn=()
eks_arn=()
for index in "${!SERVICES[@]}"; do
  service="${SERVICES[$index]}"
  matches="$(find_rules "$service")"
  count="$(jq 'length' <<<"$matches")"
  case "$count" in
    1) ;;
    0) die "$service 규칙을 찾지 못했습니다 (경로 $(path_of "$service") + 대상 $(ecs_group_name "$service"))." ;;
    *) die "$service 규칙이 ${count}개입니다 (우선순위 $(jq -r 'map(.Priority) | join(",")' <<<"$matches")). 하나만 남기고 다시 실행합니다." ;;
  esac
  rule_json[index]="$(jq -c '.[0]' <<<"$matches")"
  ecs="$(ecs_arn_from_rule "$service")"
  [ -n "$ecs" ] || die "$service 규칙에 ECS Target Group $(ecs_group_name "$service")이 없습니다."
  ecs_arn[index]="$ecs"
  eks_arn[index]="$(group_arn "$(eks_group_name "$service")")"
done

# 앱 설정(RDS sslMode, fastapi 호출자 인증)은 AWS에서 확인할 수 없으므로 전환 체크리스트로 따로 확인한다.
assert_prod_tls() {
  local failed=0 value parameter_group index protocol

  value="$(aws elasticache describe-replication-groups --replication-group-id moyeota-v2-prod-redis \
    --query 'ReplicationGroups[0].TransitEncryptionEnabled' --output text)"
  if [ "$value" != "True" ]; then
    echo "TLS 미충족: prod Redis 전송 암호화가 꺼져 있습니다." >&2
    failed=1
  fi

  parameter_group="$(aws rds describe-db-instances --db-instance-identifier moyeota-v2-prod \
    --query 'DBInstances[0].DBParameterGroups[0].DBParameterGroupName' --output text)"
  value="$(aws rds describe-db-parameters --db-parameter-group-name "$parameter_group" \
    --query "Parameters[?ParameterName=='require_secure_transport'].ParameterValue | [0]" --output text)"
  if [ "$value" != "1" ] && [ "$value" != "ON" ]; then
    echo "TLS 미충족: prod RDS require_secure_transport가 켜져 있지 않습니다." >&2
    failed=1
  fi

  for index in "${!SERVICES[@]}"; do
    protocol="$(aws elbv2 describe-target-groups --target-group-arns "${eks_arn[$index]}" \
      --query 'TargetGroups[0].Protocol' --output text)"
    if [ "$protocol" != "HTTPS" ]; then
      echo "TLS 미충족: ${SERVICES[$index]} EKS Target Group이 $protocol 입니다." >&2
      failed=1
    fi
  done

  [ "$failed" -eq 0 ] && return 0
  [ "${ACCEPT_TLS_GAP:-}" = "yes" ] || die "TLS 조건을 충족해야 prod 가중치를 올릴 수 있습니다. 리스크를 수용했다면 ACCEPT_TLS_GAP=yes를 지정합니다."
  echo "경고: TLS 조건 미충족 상태로 진행합니다 (ACCEPT_TLS_GAP=yes)." >&2
  mkdir -p "$(dirname "$CUTOVER_LOG")"
  printf '%s\t%s\tACCEPT_TLS_GAP\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$stage" >>"$CUTOVER_LOG"
}

show_status() {
  local index service weight ecs_weight
  for index in "${!SERVICES[@]}"; do
    service="${SERVICES[$index]}"
    weight="$(current_eks_weight "$service" "${eks_arn[$index]}")"
    ecs_weight="$(current_eks_weight "$service" "${ecs_arn[$index]}")"
    printf '%-10s 우선순위 %-4s ECS %-4s EKS %-4s ECS healthy %-3s EKS healthy %s\n' \
      "$service" "$(jq -r '.Priority' <<<"$(rule_of "$service")")" "${ecs_weight:-?}" "${weight:-미연결}" \
      "$(healthy_count "${ecs_arn[$index]}")" "$(healthy_count "${eks_arn[$index]}")"
  done
}

if [ "$command" = "status" ]; then
  show_status
  exit 0
fi

if [ "$command" = "assert-attached" ]; then
  for index in "${!SERVICES[@]}"; do
    weight="$(current_eks_weight "${SERVICES[$index]}" "${eks_arn[$index]}")"
    [ -n "$weight" ] || die "${SERVICES[$index]} 규칙에 EKS Target Group이 없습니다. 먼저 'alb-weight.sh $stage set 0'을 실행합니다."
  done
  echo "$stage 규칙에 EKS Target Group이 연결되어 있습니다."
  exit 0
fi

if [ "$command" = "set" ]; then
  # 가중치를 올릴 때 EKS 대상이 있어야 한다. 줄일 때는 복구가 우선이라 막지 않는다.
  current=0
  for index in "${!SERVICES[@]}"; do
    weight="$(current_eks_weight "${SERVICES[$index]}" "${eks_arn[$index]}")"
    if [ "${weight:-0}" -gt "$current" ]; then
      current="$weight"
    fi
  done

  if [ "$percent" -gt "$current" ]; then
    if [ "$stage" = "prod" ]; then
      assert_prod_tls
      next=""
      for step in "${LADDER[@]}"; do
        if [ "$step" -gt "$current" ]; then
          next="$step"
          break
        fi
      done
      [ "$percent" = "$next" ] || die "prod는 한 단계씩 올립니다. 현재 $current%, 다음 $next%."
    fi
    for index in "${!SERVICES[@]}"; do
      count="$(healthy_count "${eks_arn[$index]}")"
      [ "$count" -ge 1 ] || die "${SERVICES[$index]} EKS healthy 대상이 없습니다."
    done
  fi

  # ECS를 줄일 때 ECS 비중이 남으면 ECS도 살아 있어야 한다.
  if [ "$percent" -lt 100 ]; then
    for index in "${!SERVICES[@]}"; do
      count="$(healthy_count "${ecs_arn[$index]}")"
      [ "$count" -ge 1 ] || die "${SERVICES[$index]} ECS healthy 대상이 없습니다."
    done
  fi
fi

if [ "$assume_yes" -ne 1 ] && [ "$DRY_RUN" != "1" ]; then
  printf '%s EKS 가중치를 %s%%로 변경합니다. 진행하려면 %s 입력: ' "$alb_name" "$percent" "$stage"
  read -r answer
  [ "$answer" = "$stage" ] || die "취소했습니다."
fi

mkdir -p "$(dirname "$CUTOVER_LOG")"
failed=0
for index in "${!SERVICES[@]}"; do
  service="${SERVICES[$index]}"
  rule_arn="$(rule_of "$service" | jq -r '.RuleArn')"
  actions="$(jq -nc --arg ecs "${ecs_arn[$index]}" --arg eks "${eks_arn[$index]}" --argjson eks_weight "$percent" \
    '[{Type: "forward", ForwardConfig: {TargetGroups: [
      {TargetGroupArn: $ecs, Weight: (100 - $eks_weight)},
      {TargetGroupArn: $eks, Weight: $eks_weight}
    ], TargetGroupStickinessConfig: {Enabled: false}}}]')"
  if [ "$DRY_RUN" = "1" ]; then
    echo "[DRY_RUN] $service $rule_arn $actions"
    continue
  fi
  # 롤백은 일부 규칙이 실패해도 나머지를 계속 되돌린다.
  if aws elbv2 modify-rule --rule-arn "$rule_arn" --actions "$actions" --output text >/dev/null; then
    echo "$service: EKS $percent%"
  else
    echo "실패: $service" >&2
    failed=1
  fi
done

if [ "$DRY_RUN" != "1" ]; then
  printf '%s\t%s\t%s\tEKS=%s\tfailed=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$stage" "$command" "$percent" "$failed" >>"$CUTOVER_LOG"
fi

exit "$failed"
