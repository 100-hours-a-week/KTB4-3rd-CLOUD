#!/usr/bin/env bash
# =============================================================================
# moyeota-monitoring-sync (systemd timer, 1분 주기)
#   1) S3 설정 버킷(config/) → /opt/moyeota-monitoring/config 동기화
#   2) SSM 비밀값 → /opt/moyeota-monitoring/.env (Grafana admin 비밀번호, Discord 웹훅)
#   3) docker compose로 스택을 원하는 상태로 맞추고, 바뀐 컴포넌트만 reload/restart
#   4) 컴포넌트 상태·디스크·메모리를 CloudWatch(HEARTBEAT_NAMESPACE)로 보낸다
#      → 모니터링 스택과 독립된 CloudWatch Alarm이 이 지표(누락 포함)로 호스트·스택 장애를 잡는다
#   환경 변수: /etc/moyeota-monitoring.env (CONFIG_BUCKET, AWS_REGION, SSM_PATH, HEARTBEAT_NAMESPACE, DATA_DIR)
# =============================================================================
set -Euo pipefail

BASE=/opt/moyeota-monitoring
CONF="$BASE/config"
ENV_FILE="$BASE/.env"
COMPONENTS="compose.yaml prometheus loki grafana"

tree_hash() {
  if [ -e "$1" ]; then
    find "$1" -type f -print0 | sort -z | xargs -0 -r sha256sum | sha256sum | cut -d' ' -f1
  else
    echo none
  fi
}

declare -A BEFORE AFTER
for c in $COMPONENTS; do BEFORE[$c]="$(tree_hash "$CONF/$c")"; done
BEFORE[env]="$(tree_hash "$ENV_FILE")"

# 1) 설정 동기화 (실패해도 이전 설정으로 스택은 계속 돈다)
aws s3 sync "s3://$CONFIG_BUCKET/config/" "$CONF/" --delete --only-show-errors --region "$AWS_REGION" \
  || echo "WARN: config sync failed; keeping the previous config" >&2

# 2) 비밀값 → .env (값이 없거나 읽지 못하면 CHANGE_ME)
secret() {
  aws ssm get-parameter --with-decryption --name "$SSM_PATH/$1" \
    --query Parameter.Value --output text --region "$AWS_REGION" 2>/dev/null || echo CHANGE_ME
}
umask 077
{
  printf 'GF_SECURITY_ADMIN_PASSWORD=%s\n' "$(secret GRAFANA_ADMIN_PASSWORD)"
  printf 'DISCORD_WEBHOOK_INCIDENT=%s\n' "$(secret DISCORD_WEBHOOK_INCIDENT)"
  printf 'DISCORD_WEBHOOK_ALERTS=%s\n' "$(secret DISCORD_WEBHOOK_ALERTS)"
} > "$ENV_FILE.new"
if cmp -s "$ENV_FILE.new" "$ENV_FILE"; then rm -f "$ENV_FILE.new"; else mv "$ENV_FILE.new" "$ENV_FILE"; fi
umask 022

for c in $COMPONENTS; do AFTER[$c]="$(tree_hash "$CONF/$c")"; done
AFTER[env]="$(tree_hash "$ENV_FILE")"
changed() { [ "${BEFORE[$1]}" != "${AFTER[$1]}" ]; }

# 3) 스택 맞추기
compose() { docker compose --project-name monitoring --project-directory "$CONF" -f "$CONF/compose.yaml" "$@"; }
if [ -f "$CONF/compose.yaml" ]; then
  compose up -d --remove-orphans
  if changed prometheus; then
    curl -fsS -m 10 -X POST http://127.0.0.1:9090/-/reload >/dev/null || compose restart prometheus
  fi
  if changed loki; then compose restart loki; fi
  if changed grafana || changed env; then compose up -d --force-recreate grafana; fi
fi

# 4) 하트비트
probe() { curl -fsS -m 5 -o /dev/null "$1" && echo 1 || echo 0; }
PROM_OK="$(probe http://127.0.0.1:9090/-/healthy)"
LOKI_OK="$(probe http://127.0.0.1:3100/ready)"
GRAF_OK="$(probe http://127.0.0.1:3000/api/health)"
DISK_PCT="$(df --output=pcent "$DATA_DIR" | tail -1 | tr -dc '0-9')"
MEM_PCT="$(free | awk '/^Mem:/ {printf "%.1f", ($2 - $7) / $2 * 100}')"

aws cloudwatch put-metric-data --region "$AWS_REGION" --namespace "$HEARTBEAT_NAMESPACE" --metric-data \
  "MetricName=ComponentHealthy,Dimensions=[{Name=Component,Value=prometheus}],Value=$PROM_OK,Unit=Count" \
  "MetricName=ComponentHealthy,Dimensions=[{Name=Component,Value=loki}],Value=$LOKI_OK,Unit=Count" \
  "MetricName=ComponentHealthy,Dimensions=[{Name=Component,Value=grafana}],Value=$GRAF_OK,Unit=Count" \
  "MetricName=DataDiskUsedPercent,Dimensions=[{Name=Component,Value=host}],Value=${DISK_PCT:-0},Unit=Percent" \
  "MetricName=MemoryUsedPercent,Dimensions=[{Name=Component,Value=host}],Value=${MEM_PCT:-0},Unit=Percent" \
  || echo "WARN: heartbeat publish failed" >&2
