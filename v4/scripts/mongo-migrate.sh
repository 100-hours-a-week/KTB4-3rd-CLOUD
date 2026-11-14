#!/usr/bin/env bash
# V3 prod MongoDB(replica set rs0) → v4 데이터 호스트 MongoDB 이관 (v4/MONGODB_MIGRATION.md)
#
#   mongo-migrate.sh precheck        양쪽 접속, replica set 상태, 컬렉션별 문서 수, 데이터 디스크 확인 (읽기 전용)
#   mongo-migrate.sh count           양쪽 컬렉션별 문서 수 출력 (읽기 전용)
#   mongo-migrate.sh migrate [--yes] mongodump | mongorestore --drop. v4 moyeota DB를 V3 내용으로 덮어쓴다
#   mongo-migrate.sh verify          양쪽 문서 수를 비교한다. 다르면 종료 코드 1
#
# 운영자 PC에서 실행한다. SSM Run Command로 v4 데이터 호스트에서 작업한다.
#   - 비밀번호는 데이터 호스트가 SSM에서 직접 읽는다. 명령 기록(SSM 파라미터)과 이 화면에 남지 않는다
#   - 전제: v4 tfvars mongo_migration_enabled = true로 apply (V3 SG 인바운드, V3 SSM 읽기 권한)
#   - 필요 권한: ec2:DescribeInstances, ssm:SendCommand, ssm:GetCommandInvocation
#   - 이관은 moyeota DB만 대상이다. 사용자·역할은 옮기지 않는다 (양쪽 앱 계정은 각 호스트가 만든다)
#
# 환경 변수: AWS_REGION(기본 ap-northeast-2), DATA_HOST_NAME(기본 moyeota-v4-prod-data-host)
set -euo pipefail

REGION="${AWS_REGION:-ap-northeast-2}"
DATA_HOST_NAME="${DATA_HOST_NAME:-moyeota-v4-prod-data-host}"
V3_URI_PARAM="/moyeota/v2/prod/backend/MONGODB_URI"
V3_ROOT_PARAM="/moyeota/v2/prod/mongo/ROOT_PASSWORD"
V4_ROOT_PARAM="/moyeota/v4/prod/mongo/ROOT_PASSWORD"

command="${1:-}"
assume_yes=0
[ "${2:-}" = "--yes" ] && assume_yes=1

die() {
  echo "오류: $*" >&2
  exit 1
}

case "$command" in
  precheck | count | migrate | verify) ;;
  *) die "명령은 precheck, count, migrate, verify입니다: '$command'" ;;
esac

for tool in aws jq; do
  command -v "$tool" >/dev/null || die "$tool이 필요합니다."
done

instance_id="$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Name,Values=${DATA_HOST_NAME}" Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].InstanceId | [0]' --output text)"
[ -n "$instance_id" ] && [ "$instance_id" != "None" ] || die "실행 중인 데이터 호스트(${DATA_HOST_NAME})를 찾지 못했습니다."

# ---------------------------------------------------------------------------
# 데이터 호스트에서 실행할 스크립트 조각. 여기서는 확장하지 않고 그대로 보낸다 (작은따옴표 heredoc).
# ---------------------------------------------------------------------------

read -r -d '' REMOTE_PRELUDE <<'REMOTE' || true
set -euo pipefail
export AWS_DEFAULT_REGION="__REGION__"
param() { aws ssm get-parameter --name "$1" --with-decryption --query Parameter.Value --output text; }
enc() { python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }

v3_uri="$(param "__V3_URI_PARAM__")"
v3_hosts="$(printf '%s' "$v3_uri" | sed -E 's#^mongodb://[^@]*@([^/?]+).*#\1#')"
[ -n "$v3_hosts" ] && [ "$v3_hosts" != "$v3_uri" ] || { echo "V3 URI에서 호스트를 읽지 못했습니다" >&2; exit 1; }
SRC="mongodb://root:$(enc "$(param "__V3_ROOT_PARAM__")")@${v3_hosts}/?replicaSet=rs0&authSource=admin"
DST="mongodb://root:$(enc "$(param "__V4_ROOT_PARAM__")")@127.0.0.1:27017/?authSource=admin"
export SRC DST

IMAGE="$(docker inspect -f '{{.Config.Image}}' mongo)"
# 비밀번호가 든 URI는 환경 변수로만 넘긴다 (docker run 인자에 남기지 않는다)
in_mongo() { docker run --rm --network host -e SRC -e DST -e JS "$IMAGE" bash -o pipefail -c "$1"; }

export JS='
const d = db.getSiblingDB("moyeota");
const out = {};
d.getCollectionInfos()
  .filter(c => !c.name.startsWith("system."))
  .sort((a, b) => (a.name < b.name ? -1 : 1))
  .forEach(c => { out[c.name] = d.getCollection(c.name).countDocuments({}); });
print(JSON.stringify(out));
'
counts() {
  echo "SOURCE $(in_mongo 'mongosh "$SRC" --quiet --eval "$JS"')"
  echo "TARGET $(in_mongo 'mongosh "$DST" --quiet --eval "$JS"')"
}
REMOTE

read -r -d '' REMOTE_PRECHECK <<'REMOTE' || true
echo "== 데이터 호스트 컨테이너"
docker ps --format '{{.Names}} {{.Status}}'
echo "== 데이터 디스크"
df -h /mnt/data | tail -1
echo "== 도구 (mongo 이미지)"
in_mongo 'mongodump --version | head -1; mongorestore --version | head -1'
echo "== V3 replica set"
in_mongo 'mongosh "$SRC" --quiet --eval "const h = db.hello(); print(JSON.stringify({setName: h.setName, primary: h.primary, hosts: h.hosts}))"'
echo "== V3 moyeota DB 크기"
in_mongo 'mongosh "$SRC" --quiet --eval "const s = db.getSiblingDB(\"moyeota\").stats(); print(JSON.stringify({collections: Number(s.collections), dataSizeKB: Math.round(Number(s.dataSize) / 1024), storageSizeKB: Math.round(Number(s.storageSize) / 1024)}))"'
echo "== v4 MongoDB"
in_mongo 'mongosh "$DST" --quiet --eval "print(JSON.stringify(db.adminCommand({ping: 1})))"'
echo "== 문서 수"
counts
REMOTE

read -r -d '' REMOTE_MIGRATE <<'REMOTE' || true
echo "== 이관 시작 $(date '+%F %T')"
start="$(date +%s)"
in_mongo 'mongodump --uri="$SRC" --db=moyeota --readPreference=primary --archive --gzip \
  | mongorestore --uri="$DST" --archive --gzip --drop --nsInclude="moyeota.*" --stopOnError'
echo "== 이관 완료 $(date '+%F %T') ($(( $(date +%s) - start ))초)"
counts
REMOTE

# ---------------------------------------------------------------------------
# SSM Run Command
# ---------------------------------------------------------------------------

render() {
  local body="$1"
  body="${body//__REGION__/$REGION}"
  body="${body//__V3_URI_PARAM__/$V3_URI_PARAM}"
  body="${body//__V3_ROOT_PARAM__/$V3_ROOT_PARAM}"
  body="${body//__V4_ROOT_PARAM__/$V4_ROOT_PARAM}"
  printf '%s\n' "$body"
}

# 데이터 호스트에서 스크립트를 실행하고 출력을 표준 출력으로 낸다. 실패하면 종료 코드 1.
run_remote() {
  local body="$1" timeout="$2" params command_id status
  params="$(jq -nc --arg script "$(render "$REMOTE_PRELUDE"; render "$body")" --arg timeout "$timeout" \
    '{commands: [$script], executionTimeout: [$timeout]}')"
  command_id="$(aws ssm send-command --region "$REGION" \
    --instance-ids "$instance_id" \
    --document-name AWS-RunShellScript \
    --comment "mongo-migrate ${command}" \
    --parameters "$params" \
    --query 'Command.CommandId' --output text)"
  echo "SSM command ${command_id} → ${instance_id}" >&2

  while true; do
    sleep 5
    status="$(aws ssm get-command-invocation --region "$REGION" --command-id "$command_id" --instance-id "$instance_id" \
      --query 'Status' --output text 2>/dev/null || echo Pending)"
    case "$status" in
      Pending | InProgress | Delayed) continue ;;
    esac
    break
  done

  aws ssm get-command-invocation --region "$REGION" --command-id "$command_id" --instance-id "$instance_id" \
    --query 'StandardOutputContent' --output text
  local err
  err="$(aws ssm get-command-invocation --region "$REGION" --command-id "$command_id" --instance-id "$instance_id" \
    --query 'StandardErrorContent' --output text)"
  [ -n "$err" ] && [ "$err" != "None" ] && printf '%s\n' "$err" >&2
  [ "$status" = "Success" ] || { echo "원격 실행 결과: ${status}" >&2; return 1; }
}

# SOURCE/TARGET 줄을 비교한다. 같으면 0, 다르면 1.
compare_counts() {
  local output="$1" source target
  source="$(sed -n 's/^SOURCE //p' <<<"$output" | tail -1)"
  target="$(sed -n 's/^TARGET //p' <<<"$output" | tail -1)"
  [ -n "$source" ] && [ -n "$target" ] || die "문서 수를 읽지 못했습니다."
  jq -rn --argjson s "$source" --argjson t "$target" '
    ($s + $t | keys_unsorted | unique) as $names
    | ["컬렉션", "V3", "v4", "결과"], ($names[] | [., ($s[.] // "-"), ($t[.] // "-"), (if $s[.] == $t[.] then "OK" else "DIFF" end)])
    | @tsv' | column -t -s $'\t'
  jq -en --argjson s "$source" --argjson t "$target" '$s == $t' >/dev/null
}

case "$command" in
  precheck)
    run_remote "$REMOTE_PRECHECK" 600
    ;;

  count)
    output="$(run_remote "counts" 600)"
    compare_counts "$output" || true
    ;;

  migrate)
    if [ "$assume_yes" -ne 1 ]; then
      cat >&2 <<'NOTICE'
v4 데이터 호스트의 moyeota DB를 V3 prod 내용으로 덮어씁니다 (컬렉션별 drop 후 복원).
확인했는지 점검합니다:
  - EKS prod worker·matching이 0개다 (kubectl -n prod get deploy worker matching)
  - Kafka consumer lag이 0이다
  - v4 rest가 APP_ROLE=rest다 (v4에서 혼잡도 쓰기가 아직 없다)
NOTICE
      printf '진행하려면 migrate 입력: ' >&2
      read -r answer
      [ "$answer" = "migrate" ] || die "취소했습니다."
    fi
    output="$(run_remote "$REMOTE_MIGRATE" 3600)"
    printf '%s\n' "$output"
    echo
    compare_counts "$output" && echo "검증: 문서 수 일치" || die "검증: 문서 수가 다릅니다. 다시 실행하거나 원인을 확인합니다."
    ;;

  verify)
    output="$(run_remote "counts" 600)"
    compare_counts "$output" && echo "검증: 문서 수 일치" || die "검증: 문서 수가 다릅니다."
    ;;
esac
