#!/usr/bin/env bash
# 1차 리허설 T0·T1 게이트 점검 (읽기 전용)
set -u
export AWS_PROFILE=moyeota-terraform AWS_REGION=ap-northeast-2
ROOT="$1"
V1_ID=i-008aaad6bd675baa0 STG_RDS=moyeota-v2-stg V1_API_HOST=v1.moyeota.com
fail=0
ts() { date '+%H:%M:%S'; }
step() { printf '\n[%s] ▶ %s\n' "$(ts)" "$1"; }
ok()   { printf '[%s]   PASS  %s\n' "$(ts)" "$1"; }
ng()   { printf '[%s]   FAIL  %s\n' "$(ts)" "$1"; fail=$((fail+1)); }

step "T0-1 stg 스냅샷"
snap=$(aws rds describe-db-snapshots --db-instance-identifier "$STG_RDS" --snapshot-type manual \
  --query 'sort_by(DBSnapshots,&SnapshotCreateTime)[-1].[DBSnapshotIdentifier,Status]' --output text)
[[ "$snap" == *available ]] && ok "$snap" || ng "${snap:-없음}"

step "T0-2 stg RDS 상태·백업 보존"
read -r st ret < <(aws rds describe-db-instances --db-instance-identifier "$STG_RDS" \
  --query 'DBInstances[0].[DBInstanceStatus,BackupRetentionPeriod]' --output text)
[[ "$st" == available && "$ret" -ge 1 ]] && ok "$STG_RDS $st, 백업 ${ret}일" || ng "$STG_RDS $st, 백업 ${ret}일"

step "T0-3 V1 HTTPS endpoint ($V1_API_HOST)"
if out=$(curl -fsS --max-time 10 -o /dev/null -w '%{http_code}' "https://$V1_API_HOST/nginx-health" 2>&1); then
  ok "HTTP $out, 인증서 검증 통과"
else
  ng "$(echo "$out" | head -1)"
  san=$(echo | openssl s_client -connect "$V1_API_HOST:443" -servername "$V1_API_HOST" 2>/dev/null \
    | openssl x509 -noout -text 2>/dev/null | grep -o 'DNS:[^,]*' | tr '\n' ' ')
  printf '          제시된 인증서 SAN: %s\n' "${san:-확인 불가}"
fi

step "T0-4 fixture 파일"
for f in prod-test-fixture.json prod-test-users.json; do
  [[ -s "$ROOT/loadtest-scenarios/out/$f" ]] && ok "$f" || ng "$f 없음 (real/seed.js → build-fixture.py 필요)"
done

step "T1-1 리허설 Terraform"
grep -qE '^migration_rehearsal_enabled *= *true' "$ROOT/v2/terraform.tfvars" && ok "migration_rehearsal_enabled = true" || ng "migration_rehearsal_enabled != true"
n=$(cd "$ROOT/v2" && terraform state list 2>/dev/null | grep -c 'migration')
[[ "$n" -gt 0 ]] && ok "state 내 migration 리소스 ${n}개" || ng "state에 migration 리소스 없음"

step "T1-2 V1 Prod EC2 · SSM"
v1=$(aws ec2 describe-instances --instance-ids "$V1_ID" --query 'Reservations[0].Instances[0].State.Name' --output text)
ping=$(aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$V1_ID" --query 'InstanceInformationList[0].PingStatus' --output text)
[[ "$v1" == running && "$ping" == Online ]] && ok "$V1_ID $v1, SSM $ping" || ng "$V1_ID $v1, SSM $ping"

step "T1-3 [V1] mig check · binlog · repl-smoke"
printf '[%s]   SKIP  V1 SSM 세션에서 실행 (sudo mig check)\n' "$(ts)"

printf '\n[%s] ■ 결과: FAIL %d건 → ' "$(ts)" "$fail"
(( fail == 0 )) && echo "T2(S1 적재)로 진행 가능" || echo "T0 게이트에서 정지, T2 이후 진행 불가"
