#!/usr/bin/env bash
# =============================================================================
# cutover-switch — 이관 리허설 S1~S6·롤백을 V1 Prod EC2에서 실행한다
#   migration.tf가 이관 버킷 config/bin/cutover-switch 로 올리고 `sudo mig render`가 /usr/local/bin에 설치한다
#
#   sudo cutover-switch s1-load          stg RDS DB 재생성 → V1 Prod 전체 덤프(--source-data=2) → RDS 적재
#   sudo cutover-switch s2-forward       정방향 복제 V1 → RDS 시작 (S1 덤프 위치부터, relay 경유, TLS)
#   sudo cutover-switch lag              양방향 복제 상태·위치 요약
#   sudo cutover-switch switch           S3~S5 쓰기 보류 → 게이트 → RDS로 전환 (HOLD_LIMIT 초 넘으면 R-a 자동)
#   sudo cutover-switch s6-reverse       역방향 복제 RDS → V1 시작 (switch가 기록한 위치부터)
#   sudo cutover-switch rollback-b       R-b: RDS 보류 → 역방향 따라잡기 → V1로 되돌림 (V2 stg desired 0 먼저)
#   sudo cutover-switch abort            R-a: S5 이전 중단 (V1 super_read_only OFF, V1 ONLINE)
#   sudo cutover-switch revert           역방향 없이 V1으로 되돌림 (S5 뒤, 1회차): RDS 보류 → V1 쓰기 허용 → V1 ONLINE
#                                        S5 이후 RDS가 받은 쓰기는 V1에 없다. 버린 RDS binlog 구간을 switch.log에 남긴다
#   sudo cutover-switch hg               ProxySQL hg10 상태·연결 풀
#
#   보류 구간에서 호출이 빨라야 하므로 상주 클라이언트 컨테이너(moyeota-migcli, host 네트워크)에 docker exec로 붙는다.
#   V1 root는 V1 MySQL 컨테이너 안의 MYSQL_ROOT_PASSWORD로, 나머지 비밀번호는 SSM·Secrets Manager에서 읽는다.
#   환경: HOLD_LIMIT(기본 7초)
# =============================================================================
set -Eeuo pipefail

BOOT=/etc/moyeota-migration/bootstrap.env
BASE=/opt/moyeota-migration
STATE="$BASE/state"
DUMP_DIR=/var/tmp/moyeota-migration
CLI=moyeota-migcli
PROXYSQL_CONTAINER=moyeota-proxysql
EDGE_NETWORK=moyeota-migration-edge
HOLD_LIMIT="${HOLD_LIMIT:-7}"

die() { echo "cutover: $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "sudo로 실행한다"
[ -f "$BOOT" ] && [ -f "$BASE/config/migration.env" ] || die "부트스트랩·sudo mig render 먼저"

# shellcheck disable=SC1090
source "$BOOT"
set -a
# shellcheck disable=SC1091
source "$BASE/config/migration.env"
set +a

V1C="$V1_MYSQL_CONTAINER"
install -d -m 0750 "$STATE"

param() { aws ssm get-parameter --with-decryption --name "$1" --query Parameter.Value --output text --region "$AWS_REGION"; }

host_ip() {
  local t
  t="$(curl -fsS -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')"
  curl -fsS -H "X-aws-ec2-metadata-token: $t" http://169.254.169.254/latest/meta-data/local-ipv4
}

[ "$(host_ip)" = "$V1_PRIVATE_IP" ] || die "이 호스트는 migration.env의 V1 Prod($V1_PRIVATE_IP)가 아니다"

load_secrets() {
  REPL_PW="$(param "$SSM_PATH/REPL_PASSWORD")"
  ADMIN_PW="$(param "$SSM_PATH/PROXYSQL_ADMIN_PASSWORD")"
  DB="$(param "$STG_DB_PARAM_PATH/DB_NAME")"
  local s
  s="$(aws secretsmanager get-secret-value --secret-id "$RDS_SECRET_ARN" --query SecretString --output text --region "$AWS_REGION")"
  RDS_USER="$(jq -r .username <<<"$s")"
  RDS_PW="$(jq -r .password <<<"$s")"
}

cli_up() {
  [ "$(docker inspect -f '{{.State.Running}}' "$CLI" 2>/dev/null)" = true ] || die "$CLI 가 실행 중이 아니다 — sudo mig render"
  [ "$(docker inspect -f '{{.State.Running}}' "$PROXYSQL_CONTAINER" 2>/dev/null)" = true ] || die "$PROXYSQL_CONTAINER 가 실행 중이 아니다 — sudo mig render"
}

# shellcheck disable=SC2016
v1()  { docker exec -i "$V1C" sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -uroot -N --default-character-set=utf8mb4 "$@"' sh "$@"; }
rds() { docker exec -i -e MYSQL_PWD="$RDS_PW" "$CLI" mysql -h "$RDS_HOST" -P "$RDS_PORT" -u "$RDS_USER" --ssl-mode=REQUIRED -N --default-character-set=utf8mb4 "$@"; }
adm() { docker exec -i -e MYSQL_PWD="$ADMIN_PW" "$CLI" mysql -h 127.0.0.1 -P 6032 -u radmin -N "$@"; }

now_ms() { date +%s%3N; }
stamp() { echo "[$(date '+%H:%M:%S.%3N')] $*"; }

# v1()/rds()는 -N이라 \G 출력에서 필드 이름이 빠진다 — --column-names로 되돌린다
replica_status() { "$1" --column-names -e "SHOW REPLICA STATUS\G"; }

replica_field() {
  replica_status "$1" | awk -v f="$2" -F': ' '$1 ~ "^ *"f"$" {print $2}'
}

set_servers() {
  adm -e "UPDATE mysql_servers SET status='$1' WHERE hostgroup_id=10 AND hostname='$V1C';
UPDATE mysql_servers SET status='$2' WHERE hostgroup_id=10 AND hostname='$RDS_HOST';
LOAD MYSQL SERVERS TO RUNTIME; SAVE MYSQL SERVERS TO DISK;"
}

conn_used() {
  adm -e "SELECT IFNULL(SUM(ConnUsed),0) FROM stats_mysql_connection_pool WHERE hostgroup=10 AND srv_host='$1'"
}

# V1에서 진행 중인 일: ProxySQL 경유 실행 중 쿼리 + InnoDB 열린 트랜잭션.
# ConnUsed는 쓰지 않는다 — Connector/J 세션 문장으로 멀티플렉싱이 꺼진 백엔드 연결은 쉬고 있어도 ConnUsed로 남는다.
v1_active() {
  local q t
  q="$(adm -e "SELECT COUNT(*) FROM stats_mysql_processlist WHERE hostgroup=10 AND srv_host='$V1C' AND command <> 'Sleep'")"
  t="$(v1 -e "SELECT COUNT(*) FROM information_schema.innodb_trx")"
  echo $(( q + t ))
}

show_hg() {
  adm -t -e "SELECT hostgroup_id hg, hostname, status, use_ssl FROM runtime_mysql_servers ORDER BY hostname;
SELECT srv_host, status, ConnUsed, ConnFree, ConnOK, ConnERR, Queries FROM stats_mysql_connection_pool WHERE hostgroup=10;"
}

cmd_s1_load() {
  load_secrets; cli_up
  [ -z "$(replica_field rds Source_Host)" ] || die "RDS에 복제 설정이 남아 있다 (lag로 확인 → 필요하면 rds_reset_external_source)"
  local v1db
  v1db="$(docker exec "$V1_BACKEND_CONTAINER" printenv DB_NAME)"
  [ "$v1db" = "$DB" ] || die "V1 DB_NAME($v1db)과 stg DB_NAME($DB)이 다르다"
  read -r -p "stg RDS의 $DB DB를 지우고 V1 Prod 데이터로 다시 만든다. stg 스냅샷 available을 확인했으면 yes: " ans
  [ "$ans" = yes ] || die "중단"

  install -d -m 0700 "$DUMP_DIR"
  local dump t0
  dump="$DUMP_DIR/s1-v1-prod-$(date +%Y%m%d%H%M%S).sql"
  t0="$(now_ms)"
  stamp "덤프 시작 (V1 Prod, --single-transaction --source-data=2) → $dump"
  ( umask 077
    # shellcheck disable=SC2016
    docker exec "$V1C" sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysqldump -uroot --single-transaction --source-data=2 --set-gtid-purged=OFF --hex-blob --no-tablespaces --databases "$1"' sh "$DB" > "$dump" )
  local pos_line file pos
  # 파일을 grep이 직접 읽는다. head | grep -m1은 grep이 먼저 끝나 head가 SIGPIPE(141)를 받고, pipefail에서 실패로 잡힌다.
  [ -s "$dump" ] || die "덤프 파일이 비었다 ($dump) — mysqldump 오류 확인"
  pos_line="$(grep -m1 -E "CHANGE (REPLICATION SOURCE|MASTER) TO" "$dump")" || die "덤프에서 binlog 위치를 찾지 못했다"
  file="$(sed -E "s/.*(SOURCE|MASTER)_LOG_FILE='([^']+)'.*/\2/" <<<"$pos_line")"
  pos="$(sed -E "s/.*(SOURCE|MASTER)_LOG_POS=([0-9]+).*/\2/" <<<"$pos_line")"
  echo "$file $pos" > "$STATE/s1-coords"
  sha256sum "$dump" > "$STATE/s1-dump.sha256"
  stamp "덤프 $(du -h "$dump" | cut -f1), 위치 $file:$pos → RDS 적재"
  rds -e "DROP DATABASE IF EXISTS \`$DB\`"
  rds < "$dump"
  stamp "S1 완료 $(( ($(now_ms) - t0) / 1000 ))초 (덤프는 teardown 때 지운다: $dump)"
  rds -t -e "SELECT table_name, table_rows FROM information_schema.tables WHERE table_schema='$DB' ORDER BY table_name"
}

cmd_s2_forward() {
  load_secrets; cli_up
  [ -s "$STATE/s1-coords" ] || die "s1-load 먼저"
  local file pos
  read -r file pos < "$STATE/s1-coords"
  rds -e "CALL mysql.rds_set_external_source('$V1_PRIVATE_IP', $RELAY_PORT, 'repl', '$REPL_PW', '$file', $pos, 1); CALL mysql.rds_start_replication;" >/dev/null
  sleep 3
  cmd_lag
}

cmd_lag() {
  load_secrets; cli_up
  echo "== V1 Prod binlog: $(v1 -e 'SHOW BINARY LOG STATUS' | awk '{print $1":"$2}')  super_read_only=$(v1 -e 'SELECT @@super_read_only')"
  echo "== 정방향 (RDS 복제본)"
  replica_status rds | grep -E ' (Replica_IO_Running|Replica_SQL_Running|Seconds_Behind_Source|Relay_Source_Log_File|Exec_Source_Log_Pos|Last_IO_Error|Last_SQL_Error):' || echo "  (없음)"
  echo "== RDS binlog: $(rds -e 'SHOW BINARY LOG STATUS' | awk '{print $1":"$2}')"
  echo "== 역방향 (V1 복제본)"
  replica_status v1 | grep -E ' (Replica_IO_Running|Replica_SQL_Running|Seconds_Behind_Source|Relay_Source_Log_File|Exec_Source_Log_Pos|Last_IO_Error|Last_SQL_Error|Replicate_Do_DB):' || echo "  (없음)"
}

abort_ra() {
  stamp "R-a: V1 super_read_only OFF → V1 ONLINE"
  v1 -e "SET GLOBAL super_read_only = OFF; SET GLOBAL read_only = OFF;"
  set_servers ONLINE OFFLINE_HARD
  stamp "R-a 완료. 정방향 복제를 해제했다면 s1-load부터 다시 한다 (lag로 확인)"
}

cmd_abort() { load_secrets; cli_up; abort_ra; show_hg; }

cmd_switch() {
  load_secrets; cli_up
  [ "$(replica_field rds Replica_SQL_Running)" = Yes ] || die "정방향 복제가 돌고 있지 않다 (s2-forward, lag)"
  [ "$(docker exec "$V1_BACKEND_CONTAINER" printenv DB_HOST)" = proxysql ] || die "V1 backend가 ProxySQL을 거치지 않는다 — sudo mig endpoint proxysql (S0) 먼저"
  local long
  long="$(v1 -e "SELECT COUNT(*) FROM information_schema.innodb_trx WHERE TIMESTAMPDIFF(SECOND, trx_started, NOW()) > 5")"
  [ "$long" = 0 ] || die "5초 넘은 트랜잭션 ${long}개 — 보류 연기"
  local lagv
  lagv="$(replica_field rds Seconds_Behind_Source)"
  [ "$lagv" = 0 ] || die "정방향 지연 ${lagv}s — 0일 때 시작"
  local t0 deadline file pos rfile rpos
  t0="$(now_ms)"; deadline=$(( t0 + HOLD_LIMIT * 1000 ))
  over() { [ "$(now_ms)" -gt "$deadline" ]; }

  stamp "S3 보류 시작: V1 → OFFLINE_SOFT"
  set_servers OFFLINE_SOFT OFFLINE_HARD
  until [ "$(v1_active)" = 0 ]; do
    over && { stamp "진행 중 쿼리·트랜잭션이 ${HOLD_LIMIT}s 안에 끝나지 않음 (고정 연결 $(conn_used "$V1C")개)"; abort_ra; exit 1; }
    sleep 0.1
  done
  # 쉬는 고정 연결은 OFFLINE_HARD로 끊는다. 이후 쿼리는 ONLINE 서버가 생길 때까지 ProxySQL에서 대기한다 (connect_timeout_server_max).
  stamp "S4 진행 중 쿼리·트랜잭션 없음 (고정 연결 $(conn_used "$V1C")개) → V1 OFFLINE_HARD · super_read_only ON"
  set_servers OFFLINE_HARD OFFLINE_HARD
  v1 -e "SET GLOBAL super_read_only = ON"
  read -r file pos _ < <(v1 -e "SHOW BINARY LOG STATUS")
  until rfile="$(replica_field rds Relay_Source_Log_File)"; rpos="$(replica_field rds Exec_Source_Log_Pos)"; [ "$rfile" = "$file" ] && [ "$rpos" = "$pos" ]; do
    over && { stamp "복제 위치 불일치 V1 $file:$pos / RDS $rfile:$rpos"; abort_ra; exit 1; }
    sleep 0.1
  done
  stamp "S4 위치 일치 $file:$pos → 정방향 해제"
  rds -e "CALL mysql.rds_stop_replication; CALL mysql.rds_reset_external_source;" >/dev/null
  read -r rfile rpos _ < <(rds -e "SHOW BINARY LOG STATUS")
  echo "$rfile $rpos" > "$STATE/rds-coords"
  over && { stamp "보류 예산 초과 (S5 전)"; abort_ra; exit 1; }
  stamp "S5 쓰기 재개: RDS → ONLINE, V1 → OFFLINE_HARD"
  set_servers OFFLINE_HARD ONLINE
  local held=$(( $(now_ms) - t0 ))
  stamp "보류 ${held} ms (목표 ≤ 5000) · RDS 시작 위치 $rfile:$rpos → $STATE/rds-coords"
  echo "$(date -Iseconds) held_ms=$held v1=$file:$pos rds=$rfile:$rpos" >> "$STATE/switch.log"
  show_hg
}

cmd_s6_reverse() {
  load_secrets; cli_up
  [ -s "$STATE/rds-coords" ] || die "switch 먼저"
  local file pos
  read -r file pos < "$STATE/rds-coords"
  if ! docker inspect -f '{{json .NetworkSettings.Networks}}' "$V1C" | grep -q "\"$EDGE_NETWORK\""; then
    docker network connect "$EDGE_NETWORK" "$V1C"
  fi
  v1 -e "CHANGE REPLICATION SOURCE TO SOURCE_HOST='$RDS_HOST', SOURCE_PORT=$RDS_PORT, SOURCE_USER='repl', SOURCE_PASSWORD='$REPL_PW', SOURCE_LOG_FILE='$file', SOURCE_LOG_POS=$pos, SOURCE_SSL=1;
CHANGE REPLICATION FILTER REPLICATE_DO_DB = ($DB);
START REPLICA;"
  sleep 3
  cmd_lag
}

cmd_rollback_b() {
  load_secrets; cli_up
  [ "$(replica_field v1 Replica_SQL_Running)" = Yes ] || die "역방향 복제가 돌고 있지 않다 — R-b 불가 (lag)"
  read -r -p "V2 stg rest·websocket desired 0을 확인했는가? (yes): " ans
  [ "$ans" = yes ] || die "중단"
  local t0 file pos vf vp
  t0="$(now_ms)"
  stamp "R-b 보류: RDS → OFFLINE_SOFT"
  set_servers OFFLINE_HARD OFFLINE_SOFT
  until [ "$(conn_used "$RDS_HOST")" = 0 ]; do sleep 0.1; done
  read -r file pos _ < <(rds -e "SHOW BINARY LOG STATUS")
  until vf="$(replica_field v1 Relay_Source_Log_File)"; vp="$(replica_field v1 Exec_Source_Log_Pos)"; \
        [ "$vf" \> "$file" ] || { [ "$vf" = "$file" ] && [ "$vp" -ge "$pos" ]; }; do
    [ $(( $(now_ms) - t0 )) -lt 30000 ] || { stamp "역방향이 30초 안에 따라오지 못함 — RDS ONLINE으로 복구"; set_servers OFFLINE_HARD ONLINE; exit 1; }
    sleep 0.1
  done
  stamp "역방향 따라잡음 $vf:$vp ≥ $file:$pos → V1 STOP REPLICA, 쓰기 허용"
  v1 -e "STOP REPLICA; SET GLOBAL super_read_only = OFF; SET GLOBAL read_only = OFF;"
  set_servers ONLINE OFFLINE_HARD
  stamp "R-b 완료 $(( $(now_ms) - t0 )) ms"
  show_hg
}

cmd_revert() {
  load_secrets; cli_up
  [ -z "$(replica_field v1 Source_Host)" ] || die "V1에 역방향 복제가 있다 — rollback-b를 쓴다"
  [ -z "$(replica_field rds Source_Host)" ] || die "RDS에 정방향 복제가 남아 있다 (S5 전) — abort를 쓴다"
  [ -s "$STATE/rds-coords" ] || die "switch 기록(rds-coords)이 없다 — S5까지 간 상태가 아니다"
  [ "$(adm -e "SELECT status FROM runtime_mysql_servers WHERE hostgroup_id=10 AND hostname='$RDS_HOST'")" = ONLINE ] || die "RDS가 ONLINE writer가 아니다 (hg)"
  echo "S5 이후 RDS가 받은 쓰기는 V1으로 돌아가지 않는다 (역방향 복제 없음)."
  read -r -p "V2 stg rest·websocket desired 0, V1에 테스트 외 쓰기 없음을 확인했는가? (yes): " ans
  [ "$ans" = yes ] || die "중단"
  local t0 start file pos
  t0="$(now_ms)"
  read -r start < "$STATE/rds-coords"
  stamp "되돌림 보류: RDS → OFFLINE_SOFT"
  set_servers OFFLINE_HARD OFFLINE_SOFT
  until [ "$(conn_used "$RDS_HOST")" = 0 ]; do
    [ $(( $(now_ms) - t0 )) -lt 30000 ] || { stamp "RDS 연결이 30초 안에 끝나지 않음 — RDS ONLINE으로 복구"; set_servers OFFLINE_HARD ONLINE; exit 1; }
    sleep 0.1
  done
  read -r file pos _ < <(rds -e "SHOW BINARY LOG STATUS")
  stamp "V1에 반영되지 않는 RDS 쓰기 구간: $start → $file:$pos"
  v1 -e "SET GLOBAL super_read_only = OFF; SET GLOBAL read_only = OFF;"
  set_servers ONLINE OFFLINE_HARD
  local held=$(( $(now_ms) - t0 ))
  echo "$(date -Iseconds) revert held_ms=$held rds_discarded=${start// /:}..$file:$pos" >> "$STATE/switch.log"
  stamp "되돌림 완료 ${held} ms"
  show_hg
}

case "${1:-}" in
  s1-load) cmd_s1_load ;;
  s2-forward) cmd_s2_forward ;;
  lag) cmd_lag ;;
  switch) cmd_switch ;;
  s6-reverse) cmd_s6_reverse ;;
  rollback-b) cmd_rollback_b ;;
  abort) cmd_abort ;;
  revert) cmd_revert ;;
  hg) load_secrets; cli_up; show_hg ;;
  *) sed -n '3,18p' "$0"; exit 1 ;;
esac
