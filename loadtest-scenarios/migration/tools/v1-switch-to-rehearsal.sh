#!/usr/bin/env bash
# [V1] V2 Prod 실이관용 ProxySQL·relay(moyeota-v2-prod-*)를 걷어내고 리허설(runbook 4.4) 경로로 바꾼다.
# 2026-10-24 결정: moyeota-v2-prod-proxysql은 V2 Prod 실이관과 끊어도 된다.
#
#   sudo MIG_BUCKET=moyeota-v2-migration-<account-id> bash v1-switch-to-rehearsal.sh
#
# B3에서 backend를 한 번 재생성한다(V1 원래 compose, DB_HOST=mysql). 나머지는 V1 MySQL·nginx·frontend를 건드리지 않는다.
# 제거한 컨테이너 설정은 /var/backups/moyeota-v2-prod-migration-<시각>/ 에 inspect JSON으로 남긴다.
set -euo pipefail

BUCKET="${MIG_BUCKET:?MIG_BUCKET 필요 (moyeota-v2-migration-<account-id>)}"
REGION="${AWS_REGION:-ap-northeast-2}"
OLD=(moyeota-v2-prod-proxysql moyeota-v2-prod-migration-relay)
BACKEND=moyeota-backend-1
BACKUP="/var/backups/moyeota-v2-prod-migration-$(date +%Y%m%d%H%M%S)"

ts() { date '+%H:%M:%S'; }
step() { printf '\n[%s] ▶ %s\n' "$(ts)" "$1"; }
ok() { printf '[%s]   PASS  %s\n' "$(ts)" "$1"; }
die() { printf '[%s]   FAIL  %s\n' "$(ts)" "$1"; exit 1; }
indent() { sed 's/^/          /'; }
health() { curl -fsS -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1/nginx-health || echo 000; }

[ "$(id -u)" -eq 0 ] || die "sudo로 실행한다"

step "B1 현재 상태 기록"
docker exec "$BACKEND" printenv DB_HOST DB_PORT DB_NAME DB_USERNAME | paste -sd' ' | indent
docker ps --format '{{.Names}}\t{{.Status}}' | indent
docker exec moyeota-mysql-1 sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot -N -e "SELECT @@read_only, @@super_read_only, @@log_bin, @@binlog_format, @@gtid_mode"' | indent
printf '          nginx-health %s\n' "$(health)"

step "B2 mig 설치 (runbook 4.4)"
install -d -m 0700 /etc/moyeota-migration
printf 'MIG_BUCKET=%s\nAWS_REGION=%s\n' "$BUCKET" "$REGION" > /etc/moyeota-migration/bootstrap.env
aws s3 cp "s3://$BUCKET/config/bin/mig" /usr/local/bin/mig --region "$REGION" --only-show-errors
chmod 0755 /usr/local/bin/mig
ok "/usr/local/bin/mig"

step "B3 backend를 V1 원래 설정으로 재생성 (mig endpoint mysql, 순단 발생)"
if [ "$(docker exec "$BACKEND" printenv DB_HOST)" = mysql ]; then
  ok "이미 DB_HOST=mysql — 건너뜀"
else
  mig endpoint mysql 2>&1 | indent
  [ "$(docker exec "$BACKEND" printenv DB_HOST)" = mysql ] || die "DB_HOST가 mysql로 돌아오지 않음 — V1 compose/.env에 proxysql이 직접 들어 있는지 확인"
  ok "DB_HOST=mysql, DB_NAME=$(docker exec "$BACKEND" printenv DB_NAME)"
fi
[ "$(health)" = 200 ] && ok "nginx-health 200" || die "nginx-health $(health)"

step "B4 V2 Prod 실이관용 컨테이너 제거 (설정 백업: $BACKUP)"
mkdir -p "$BACKUP" && chmod 700 "$BACKUP"
for c in "${OLD[@]}"; do
  if docker inspect "$c" >/dev/null 2>&1; then
    docker inspect "$c" > "$BACKUP/$c.json"
    docker cp "$c:/etc/proxysql.cnf" "$BACKUP/$c.proxysql.cnf" 2>/dev/null || true
    docker rm -f "$c" >/dev/null && ok "$c 제거"
  else
    ok "$c 없음"
  fi
done
[ "$(health)" = 200 ] && ok "nginx-health 200" || die "nginx-health $(health)"

step "B5 리허설 사이드카 기동 (mig render)"
mig render 2>&1 | indent
ok "render"

step "B6 이관 계정 (mig users)"
mig users 2>&1 | indent
ok "users"

step "B7 연결 점검 (mig check)"
if mig check 2>&1 | indent; then ok "mig check 전 항목 PASS"; else die "mig check 실패 — T2로 가지 않는다"; fi

printf '\n[%s] ■ 완료. 다음: sudo mig repl-smoke forward && sudo mig repl-smoke reverse, 그 뒤 [PC] v1-test-users.sh\n' "$(ts)"
