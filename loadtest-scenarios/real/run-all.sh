#!/usr/bin/env bash

# real 시나리오 전체 실행기.
# 개별 k6 실행이 threshold 초과로 실패해도 다음 단계까지 계속 실행한다.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT"

# 단계별 k6 결과와 Grafana 실행 구간을 이전 loadtest-target/k6.sh와 같은
# 형식으로 남긴다. GRAFANA_URL을 지정하면 해당 Grafana를 사용하고, 지정하지
# 않으면 loadtest-target/.local의 설정을 사용한다.
RESULTS="$ROOT/results"
LOCAL="$ROOT/../loadtest-target/.local"
K6_IMAGE="${K6_IMAGE:-grafana/k6:2.2.0}"
GRAFANA_URL="${GRAFANA_URL:-$(sed -n '1p' "$LOCAL/grafana_url" 2>/dev/null || true)}"
GRAFANA_PASSWORD="${GRAFANA_PASSWORD:-$(sed -n '1p' "$LOCAL/grafana_password" 2>/dev/null || true)}"
DASHBOARD_UID="${GRAFANA_DASHBOARD_UID:-moyeota-v1-loadtest}"
# 6·7단계 혼합 부하의 WS 연결 수. 행사 1,800 대신 평시 525
# (평시 활동 사용자 약 2,100명 × 채팅 접속률 25%)를 기본값으로 쓴다.
MIXED_WS_CONNECTIONS="${MIXED_WS_CONNECTIONS:-525}"
mkdir -p "$RESULTS"

grafana_api() {
  local method="$1" path="$2" body="$3"
  curl -sS -m 5 -u "admin:$GRAFANA_PASSWORD" \
    -H 'Content-Type: application/json' -X "$method" \
    "$GRAFANA_URL$path" -d "$body"
}

usage() {
  echo "사용법: $0 [--from 1..8 | --only 1..8]" >&2
}

START_STEP=1
ONLY_STEP=0
if [ "$#" -eq 2 ] && [ "$1" = "--from" ]; then
  START_STEP="$2"
elif [ "$#" -eq 2 ] && [ "$1" = "--only" ]; then
  ONLY_STEP="$2"
elif [ "$#" -ne 0 ]; then
  usage
  exit 2
fi
if ! [[ "$START_STEP" =~ ^[1-8]$ ]] || ! [[ "$ONLY_STEP" =~ ^[0-8]$ ]]; then
  usage
  exit 2
fi

FAILED_STEPS=()

k6real() {
  local script="${!#}"
  local scenario="${script##*/}"
  scenario="${scenario%.js}"
  local run_prefix="${RUN_ID:-real-$(date +%Y%m%d-%H%M%S)}"
  # One RUN_ID spans the whole 8-step run; keep each scenario's artifacts distinct.
  local invocation_id="$(python3 -c 'import time; print(int(time.time()*1000))')"
  local run_label="${run_prefix}-${scenario}-${invocation_id}"
  local start_ms end_ms annotation_id summary_path raw_path params body status
  start_ms="$(python3 -c 'import time; print(int(time.time()*1000))')"
  summary_path="results/${run_label}-summary.json"
  raw_path="results/${run_label}-raw.json"

  if [ -n "$GRAFANA_URL" ] && [ -n "$GRAFANA_PASSWORD" ]; then
    params="$(env | grep -E '^(TARGET_RPS|STEPS|STEP_DURATION|STEP_GAP|MODE|LEVELS|ROUNDS|PROFILE|PEAK_RPS|WS_CONNECTIONS|TARGET_CONNECTIONS|CONNECT_RATE|HOLD|MESSAGE_RATE|JOURNEY|JOURNEY_RATE|DURATION)=' | sort | tr '\n' ' ' || true)"
    body="$(python3 -c 'import json,sys; print(json.dumps({"dashboardUID":sys.argv[1],"time":int(sys.argv[2]),"tags":["loadtest",sys.argv[3],sys.argv[4]],"text":"START "+sys.argv[4]+" ("+sys.argv[3]+") "+sys.argv[5]}))' \
      "$DASHBOARD_UID" "$start_ms" "$scenario" "$run_label" "$params")"
    annotation_id="$(grafana_api POST /api/annotations "$body" \
      | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)"
    if [ -n "$annotation_id" ]; then
      echo "grafana annotation #$annotation_id started: $run_label"
    else
      echo "WARN: grafana annotation failed; k6 결과 저장은 계속합니다." >&2
    fi
  else
    annotation_id=""
    echo "WARN: Grafana URL/password가 없어 annotation을 생략합니다." >&2
  fi

  # fixture.js resolves paths relative to the real/ module directory; inside /work
  # these values map to /work/real/data/*.json.
  docker run --rm -i \
    --name "k6-${run_label}-$$" \
    --ulimit nofile=65536:65536 \
    -v "$ROOT:/work" \
    -w /work \
    "$K6_IMAGE" run \
    --summary-export="/work/$summary_path" \
    --out "json=/work/$raw_path" \
    --tag "testid=$run_label" \
    -e RUN_ID="$run_label" \
    -e BASE_URL=https://dev.moyeota.com \
    -e CONFIRM_TARGET_HOST=dev.moyeota.com \
    -e FIXTURE_FILE=./data/fixture.json \
    -e USERS_FILE=./data/users.json \
    "$@"
  status=$?

  end_ms="$(python3 -c 'import time; print(int(time.time()*1000))')"
  if [ -n "$annotation_id" ]; then
    body="$(python3 -c 'import json,sys; print(json.dumps({"timeEnd":int(sys.argv[1]),"text":"RUN "+sys.argv[2]+" ("+sys.argv[3]+") k6 exit="+sys.argv[4]}))' \
      "$end_ms" "$run_label" "$scenario" "$status")"
    grafana_api PATCH "/api/annotations/$annotation_id" "$body" >/dev/null || true
    echo "grafana annotation #$annotation_id closed (k6 exit=$status)"
  fi

  printf '%s\t%s\t%s\t%s\t%s\texit=%s\t%s\n' \
    "$run_label" "$scenario" "$start_ms" "$end_ms" \
    "$(sed -n '1p' "$LOCAL/release" 2>/dev/null || echo unknown)" "$status" \
    "$GRAFANA_URL/d/$DASHBOARD_UID/?from=$((start_ms - 60000))&to=$((end_ms + 60000))" \
    >> "$RESULTS/runs.tsv"
  echo "result summary: $summary_path"
  echo "result raw: $raw_path"
  return "$status"
}

run_step() {
  local label="$1"
  shift

  echo
  echo "=== $label 시작 ==="
  "$@"
  local status=$?

  if [ "$status" -ne 0 ]; then
    echo "WARN: $label 실패(exit=$status). 다음 단계로 계속 진행합니다." >&2
    FAILED_STEPS+=("$label")
  else
    echo "=== $label 완료 ==="
  fi
}

run_step_if() {
  local number="$1"
  shift
  if { [ "$ONLY_STEP" -eq 0 ] && [ "$number" -ge "$START_STEP" ]; } || [ "$number" -eq "$ONLY_STEP" ]; then
    run_step "$@"
  else
    echo "=== $number/8 단계 스킵 ==="
  fi
}

run_step_if 1 "1/8 조회 단계 부하" \
  k6real -e STEPS=45.5,91,180,226 -e STEP_DURATION=5m -e STEP_GAP=30s real/read.js

run_step_if 2 "2/8 WebSocket 연결 부하" \
  k6real -e TARGET_CONNECTIONS=1800 -e CONNECT_RATE=6 -e HOLD=10m -e MESSAGE_RATE=0 real/ws-chat.js

run_step_if 3 "3/8 WebSocket 메시지 부하" \
  k6real -e TARGET_CONNECTIONS=1800 -e CONNECT_RATE=6 -e HOLD=10m -e MESSAGE_RATE=36 real/ws-chat.js

run_step_if 4 "4/8 동행 좌석 경합" \
  k6real -e MODE=companion -e LEVELS=20,50,100 -e ROUNDS=3 real/hot-row.js

if [ "$ONLY_STEP" -eq 0 ] && [ "$START_STEP" -le 4 ]; then
  echo
  echo "동행 경합 데이터를 초기화한 뒤 계속하세요."
  read -r -p "초기화 완료 후 Enter를 누르세요: "
fi

run_step_if 5 "5/8 택시팟 경합" \
  k6real -e MODE=taxi -e LEVELS=4,20,50 -e ROUNDS=3 real/hot-row.js

run_step_if 6 "6/8 행사 혼합 부하 180 RPS" \
  k6real -e PROFILE=event -e PEAK_RPS=180 -e WS_CONNECTIONS="$MIXED_WS_CONNECTIONS" real/mixed.js

run_step_if 7 "7/8 행사 혼합 부하 226 RPS" \
  k6real -e PROFILE=event -e PEAK_RPS=226 -e WS_CONNECTIONS="$MIXED_WS_CONNECTIONS" real/mixed.js

run_step_if 8 "8/8 사용자 여정" \
  k6real -e JOURNEY=all -e JOURNEY_RATE=1 -e DURATION=10m real/cuj.js

echo
if [ "${#FAILED_STEPS[@]}" -gt 0 ]; then
  echo "전체 시나리오는 끝까지 실행했지만 실패한 단계가 있습니다:"
  printf ' - %s\n' "${FAILED_STEPS[@]}"
  exit 1
fi

if [ "$ONLY_STEP" -eq 0 ]; then
  echo "전체 시나리오 완료"
else
  echo "$ONLY_STEP/8 시나리오 완료"
fi
