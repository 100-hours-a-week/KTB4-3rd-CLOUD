#!/usr/bin/env bash
# 전환 롤백 기준을 CloudWatch로 판정한다. 읽기 전용이다.
#   cutover-check.sh <stg|prod> [--watch]
# 하나라도 FAIL이면 종료 코드 1이다. --watch는 60초마다 반복한다.
# WebSocket 재연결 실패는 ALB 지표로 근사하므로 클라이언트 확인을 함께 한다.
set -uo pipefail

stage="${1:-}"
watch="${2:-}"
case "$stage" in
  prod) alb_name="moyeota-v2-alb" ;;
  stg) alb_name="moyeota-v2-nonprod-alb" ;;
  *)
    echo "스테이지는 stg 또는 prod입니다: '$stage'" >&2
    exit 2
    ;;
esac

LIMIT_5XX_PERCENT=1
LIMIT_P95_SECONDS=1
LIMIT_DB_CONNECTIONS=120
WINDOW_MINUTES=5

lb_suffix="$(aws elbv2 describe-load-balancers --names "$alb_name" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text | sed 's#.*loadbalancer/##')"

group_suffix() {
  aws elbv2 describe-target-groups --names "$1" --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null |
    sed -n 's#.*:\(targetgroup/.*\)#\1#p'
}

minutes_ago() {
  if date -u -v-1M +%s >/dev/null 2>&1; then
    date -u -v-"$1"M +%Y-%m-%dT%H:%M:00Z
  else
    date -u -d "$1 minutes ago" +%Y-%m-%dT%H:%M:00Z
  fi
}

# 분 단위 값을 {timestamp: value} JSON으로 출력한다. 마지막 1분은 아직 집계 중이라 제외한다.
fetch() {
  local namespace="$1" metric="$2" statistic="$3"
  shift 3
  local statistic_args=(--statistics "$statistic") key="$statistic"
  case "$statistic" in
    p95)
      statistic_args=(--extended-statistics p95)
      key="p95"
      ;;
  esac
  aws cloudwatch get-metric-statistics --namespace "$namespace" --metric-name "$metric" \
    --dimensions "$@" --start-time "$(minutes_ago $((WINDOW_MINUTES + 1)))" --end-time "$(minutes_ago 1)" \
    --period 60 "${statistic_args[@]}" --output json |
    jq -c --arg key "$key" 'def v: if $key == "p95" then .ExtendedStatistics.p95 else .[$key] end;
      [.Datapoints[] | {key: .Timestamp, value: v}] | from_entries'
}

failed=0
report() {
  local name="$1" value="$2" limit="$3" verdict="$4"
  printf '%-36s %-14s 기준 %-10s %s\n' "$name" "$value" "$limit" "$verdict"
  if [ "$verdict" = "FAIL" ]; then
    failed=1
  fi
}

# sustained: 기준 시간 동안 매분 초과일 때 FAIL. latest: 마지막 완료 분이 초과일 때 FAIL.
check_series() {
  local name="$1" series="$2" limit="$3" mode="${4:-latest}"
  local result
  result="$(jq -r --argjson limit "$limit" --argjson need "$WINDOW_MINUTES" --arg mode "$mode" '
    (to_entries | sort_by(.key) | map(.value)) as $v
    | if ($v | length) == 0 then "데이터없음 OK"
      elif $mode == "sustained" then
        (($v | max * 100 | round / 100 | tostring) + " "
          + (if ($v | length) >= $need and ($v | all(. > $limit)) then "FAIL" else "OK" end))
      else
        (($v | last * 100 | round / 100 | tostring) + " "
          + (if ($v | last) > $limit then "FAIL" else "OK" end))
      end' <<<"$series")"
  report "$name" "${result% *}" "$limit" "${result##* }"
}

check_once() {
  failed=0
  echo "== $stage $(date '+%H:%M:%S')"

  # AWS CLI dimension 형식(Name=...,Value=...)은 쉼표가 들어간 한 개의 인자다
  # shellcheck disable=SC2054
  local lb=(Name=LoadBalancer,Value="$lb_suffix")
  local requests target_5xx elb_5xx ratio
  requests="$(fetch AWS/ApplicationELB RequestCount Sum "${lb[@]}")"
  target_5xx="$(fetch AWS/ApplicationELB HTTPCode_Target_5XX_Count Sum "${lb[@]}")"
  elb_5xx="$(fetch AWS/ApplicationELB HTTPCode_ELB_5XX_Count Sum "${lb[@]}")"
  ratio="$(jq -nc --argjson r "$requests" --argjson t "$target_5xx" --argjson e "$elb_5xx" '
    $r | to_entries | map(select(.value > 0)
      | {key, value: ((($t[.key] // 0) + ($e[.key] // 0)) / .value * 100)}) | from_entries')"
  check_series "ALB 5xx 비율(%)" "$ratio" "$LIMIT_5XX_PERCENT" sustained

  local eks_rest ecs_rest
  eks_rest="$(group_suffix "moyeota-v3-eks-$stage-rest")"
  ecs_rest="$(group_suffix "moyeota-v2-$stage-rest")"
  if [ -n "$eks_rest" ]; then
    check_series "EKS rest p95(초)" \
      "$(fetch AWS/ApplicationELB TargetResponseTime p95 "${lb[@]}" Name=TargetGroup,Value="$eks_rest")" "$LIMIT_P95_SECONDS"
  fi
  if [ -n "$ecs_rest" ]; then
    check_series "ECS rest p95(초)" \
      "$(fetch AWS/ApplicationELB TargetResponseTime p95 "${lb[@]}" Name=TargetGroup,Value="$ecs_rest")" "$LIMIT_P95_SECONDS"
  fi

  local eks_ws
  eks_ws="$(group_suffix "moyeota-v3-eks-$stage-websocket")"
  if [ -n "$eks_ws" ]; then
    check_series "EKS websocket 연결 오류(건)" \
      "$(fetch AWS/ApplicationELB TargetConnectionErrorCount Sum "${lb[@]}" Name=TargetGroup,Value="$eks_ws")" 0
    check_series "EKS websocket 5xx(건)" \
      "$(fetch AWS/ApplicationELB HTTPCode_Target_5XX_Count Sum "${lb[@]}" Name=TargetGroup,Value="$eks_ws")" 0
  fi

  check_series "RDS 연결(개)" \
    "$(fetch AWS/RDS DatabaseConnections Maximum Name=DBInstanceIdentifier,Value="moyeota-v2-$stage")" "$LIMIT_DB_CONNECTIONS"

  if [ "$failed" -eq 1 ]; then
    echo "판정: 롤백 기준 초과. alb-weight.sh $stage rollback --yes"
  else
    echo "판정: 기준 이내"
  fi
}

check_once
if [ "$watch" = "--watch" ]; then
  while sleep 60; do
    check_once
  done
fi
exit "$failed"
