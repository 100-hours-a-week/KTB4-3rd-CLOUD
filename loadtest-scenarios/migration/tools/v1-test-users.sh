#!/usr/bin/env bash
# [PC] T0 — V1 Prod에 테스트 전용 사용자를 넣고 토큰을 발급한 뒤 시드·fixture를 만든다.
#
# runbook 4.4.1 예외 (2026-10-24 결정): V1 Prod JWT_SECRET으로 테스트 전용 사용자(id 900001~) 토큰만 짧은 TTL로 발급한다.
# JWT_SECRET은 V1 밖으로 나오지 않는다. V1에서 서명한 토큰만 SSM 명령 출력으로 받아 온다.
# 정리: real/data/cleanup.sql 형식의 out/v1-lt-cleanup.sql을 [V1] MySQL에서 실행 (id 범위로 삭제).
set -euo pipefail

export AWS_PROFILE="${AWS_PROFILE:-moyeota-terraform}" AWS_REGION="${AWS_REGION:-ap-northeast-2}"
V1_ID="${V1_ID:-i-008aaad6bd675baa0}"
V1_API_HOST="${V1_API_HOST:-v1.moyeota.com}"
COUNT="${COUNT:-100}" START_ID="${START_ID:-900001}" TTL_HOURS="${TTL_HOURS:-6}"
export POOL_CHAT="${POOL_CHAT:-40}" POOL_HOTROW="${POOL_HOTROW:-10}" POOL_TAXI="${POOL_TAXI:-20}" \
  POOL_CUJ="${POOL_CUJ:-10}" POOL_WRITER="${POOL_WRITER:-20}"
BUCKET="${MIG_BUCKET:-moyeota-v2-migration-$(aws sts get-caller-identity --query Account --output text)}"
LT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$LT/out"

ts() { date '+%H:%M:%S'; }
step() { printf '\n[%s] ▶ %s\n' "$(ts)" "$1"; }
ok() { printf '[%s]   PASS  %s\n' "$(ts)" "$1"; }
die() { printf '[%s]   FAIL  %s\n' "$(ts)" "$1"; exit 1; }

mkdir -p "$OUT" && chmod 700 "$OUT"

step "U1 make-users.py → s3://$BUCKET/config/tools/"
aws s3 cp "$LT/real/tools/make-users.py" "s3://$BUCKET/config/tools/make-users.py" --only-show-errors
ok "업로드"

# [V1]에서 도는 부분. 로그는 "[hh:mm:ss] ..." 줄, 결과 파일은 BEGIN/END 사이 gzip+base64.
REMOTE=$(cat <<'EOF'
set -euo pipefail
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
log() { echo "[$(date +%H:%M:%S)] $*"; }
q() { docker exec -i moyeota-mysql-1 sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot -N moyeota'; }
END_ID=$((START_ID + COUNT - 1))
aws s3 cp "s3://$MIG_BUCKET/config/tools/make-users.py" "$W/" --only-show-errors --region "$AWS_REGION"
log "  PASS  make-users.py 다운로드"
S=$(docker exec moyeota-backend-1 printenv JWT_SECRET)
[ -n "$S" ] || { log "  FAIL  backend 컨테이너에 JWT_SECRET 없음"; exit 1; }
log "  PASS  JWT_SECRET 읽음 (출력하지 않음)"
existing=$(echo "SELECT COUNT(*) FROM users WHERE id BETWEEN $START_ID AND $END_ID" | q)
log "  INFO  id $START_ID..$END_ID 기존 행: $existing"
if [ "$existing" -eq 0 ]; then
  JWT_SECRET="$S" python3 "$W/make-users.py" --count "$COUNT" --start-id "$START_ID" --ttl-hours "$TTL_HOURS" --out-dir "$W" >/dev/null
  q < "$W/seed-users.sql"
  log "  PASS  테스트 사용자 $COUNT명 INSERT"
elif [ "$existing" -eq "$COUNT" ]; then
  JWT_SECRET="$S" python3 "$W/make-users.py" --count "$COUNT" --start-id "$START_ID" --ttl-hours "$TTL_HOURS" --out-dir "$W" --tokens-only >/dev/null
  log "  PASS  이미 있음 → 토큰만 재발급"
else
  log "  FAIL  id 범위에 일부만 존재 ($existing/$COUNT). 정리 후 다시 실행"; exit 1
fi
unset S
cnt=$(echo "SELECT COUNT(*) FROM users WHERE id BETWEEN $START_ID AND $END_ID" | q)
[ "$cnt" -eq "$COUNT" ] || { log "  FAIL  사용자 수 $cnt/$COUNT"; exit 1; }
log "  PASS  V1 users 테이블 확인 $cnt명"
echo BEGIN_USERS; gzip -c "$W/users.json" | base64 -w0; echo; echo END_USERS
[ -f "$W/cleanup.sql" ] && { echo BEGIN_CLEANUP; gzip -c "$W/cleanup.sql" | base64 -w0; echo; echo END_CLEANUP; }
EOF
)

step "U2 [V1] 테스트 사용자 INSERT · 토큰 발급 (SSM send-command)"
params=$(python3 -c 'import json,sys; print(json.dumps({"commands":[sys.argv[1]],"executionTimeout":["300"]}))' \
  "export MIG_BUCKET=$BUCKET AWS_REGION=$AWS_REGION COUNT=$COUNT START_ID=$START_ID TTL_HOURS=$TTL_HOURS; echo $(printf '%s' "$REMOTE" | base64 | tr -d '\n') | base64 -d | bash")
cid=$(aws ssm send-command --instance-ids "$V1_ID" --document-name AWS-RunShellScript \
  --comment "migration rehearsal T0 test users" --parameters "$params" --query Command.CommandId --output text)
printf '          command-id %s\n' "$cid"
status=Pending
while [[ "$status" =~ ^(Pending|InProgress|Delayed)$ ]]; do
  sleep 3
  status=$(aws ssm get-command-invocation --command-id "$cid" --instance-id "$V1_ID" --query Status --output text 2>/dev/null || echo Pending)
  printf '          ... %s\n' "$status"
done
res=$(aws ssm get-command-invocation --command-id "$cid" --instance-id "$V1_ID" --output json)
stdout=$(jq -r .StandardOutputContent <<<"$res")
grep -E '^\[' <<<"$stdout" | sed 's/^/          /'
[[ "$status" == Success ]] || { jq -r .StandardErrorContent <<<"$res" | tail -5 | sed 's/^/          /'; die "V1 단계 실패 ($status)"; }

step "U3 토큰 파일 저장"
umask 077
awk '/^BEGIN_USERS$/{f=1;next}/^END_USERS$/{f=0}f' <<<"$stdout" | base64 -d | gunzip > "$OUT/v1-lt-users.json"
awk '/^BEGIN_CLEANUP$/{f=1;next}/^END_CLEANUP$/{f=0}f' <<<"$stdout" | base64 -d 2>/dev/null | gunzip > "$OUT/v1-lt-cleanup.sql" 2>/dev/null || true
n=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(len(d["users"]) if isinstance(d,dict) else len(d))' "$OUT/v1-lt-users.json")
[[ "$n" -eq "$COUNT" ]] || die "토큰 $n/$COUNT개"
ok "out/v1-lt-users.json (${n}명, TTL ${TTL_HOURS}h)"

step "F1 시드 데이터 생성 (k6 real/seed.js → https://$V1_API_HOST)"
cd "$LT"
k6 run --quiet -e BASE_URL="https://$V1_API_HOST" -e CONFIRM_TARGET_HOST="$V1_API_HOST" \
  -e USERS_FILE=out/v1-lt-users.json -e FIXTURE_OUT=out/seed-fixture.json real/seed.js 2>&1 | tail -15 | sed 's/^/          /'
[[ -s out/seed-fixture.json ]] || die "seed-fixture.json 없음"
ok "out/seed-fixture.json"

step "F2 fixture 생성 (build-fixture.py)"
python3 migration/tools/build-fixture.py --seed-fixture out/seed-fixture.json --users out/v1-lt-users.json \
  --base-url "https://$V1_API_HOST" --fixture-out out/prod-test-fixture.json --users-out out/prod-test-users.json |
  sed 's/^/          /'
ok "out/prod-test-fixture.json, out/prod-test-users.json"

printf '\n[%s] ■ T0 시드·fixture 완료. 토큰 만료: %s시간 뒤. 정리 SQL: out/v1-lt-cleanup.sql\n' "$(ts)" "$TTL_HOURS"
