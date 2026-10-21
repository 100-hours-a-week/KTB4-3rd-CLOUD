#!/usr/bin/env bash
# =============================================================================
# mig — 이관 리허설 v1-sim 운영 도구 (migration.tf가 이관 버킷 config/bin/mig 로 올린다)
#
#   sudo mig render [--reset-proxysql]   설정 받기 → 비밀값으로 env·proxysql.cnf 생성 → docker compose up
#   sudo mig users                       V1(sim)·stg RDS에 앱·repl·mig_mon 계정 생성/비밀번호 맞춤
#   sudo mig check                       연결 경로 점검 (V1·relay·RDS·ProxySQL·exporter)
#   sudo mig status                      컨테이너·ProxySQL 서버 상태·양쪽 복제 상태
#   sudo mig sql v1|rds|admin [mysql 옵션]   V1 root / RDS master / ProxySQL radmin 셸 (예: -e "SELECT 1")
#   sudo mig endpoint mysql|proxysql     V1 backend DB 연결 대상 변경 + backend 재생성 (S0)
#   sudo mig load-dump <s3 key>          이관 버킷의 덤프(.sql 또는 .sql.gz)를 V1(sim) MySQL에 적재
#   sudo mig repl-smoke forward|reverse  복제 연결만 시험하고 되돌린다 (forward: RDS → relay 3307, reverse: V1 → RDS 3306, 둘 다 TLS)
#
#   비밀번호는 SSM·Secrets Manager에서 그때그때 읽는다 (파일·셸 기록에 남기지 않는다)
#   주의: S3(쓰기 보류)~S9(관찰 창) 사이에는 render를 다시 돌리지 않는다 (컨테이너가 재생성될 수 있다)
# =============================================================================
set -Eeuo pipefail

BASE=/opt/moyeota-v1sim
CONF="$BASE/config"
STATE="$BASE/state"
V1_CONTAINER=moyeota-mysql-1
APP_NETWORK=moyeota-app-prod

# shellcheck disable=SC1091
source /etc/moyeota-v1sim.env

die() { echo "mig: $*" >&2; exit 1; }
need_root() { [ "$(id -u)" -eq 0 ] || die "sudo로 실행한다"; }

load_conf() {
  [ -f "$CONF/v1sim.env" ] || die "$CONF/v1sim.env 없음 — sudo mig render 먼저"
  set -a
  # shellcheck disable=SC1091
  source "$CONF/v1sim.env"
  set +a
  MYSQL_SERVER_VERSION="${MYSQL_IMAGE##*:}"
}

param() {
  aws ssm get-parameter --with-decryption --name "$1" --query Parameter.Value --output text --region "$AWS_REGION"
}

load_secrets() {
  MYSQL_ROOT_PASSWORD="$(param "$SSM_PATH/MYSQL_ROOT_PASSWORD")"
  REPL_PASSWORD="$(param "$SSM_PATH/REPL_PASSWORD")"
  PROXYSQL_ADMIN_PASSWORD="$(param "$SSM_PATH/PROXYSQL_ADMIN_PASSWORD")"
  MON_PASSWORD="$(param "$MON_PASSWORD_PARAM")"
  APP_DB_NAME="$(param "$STG_DB_PARAM_PATH/DB_NAME")"
  APP_DB_USER="$(param "$STG_DB_PARAM_PATH/DB_USERNAME")"
  APP_DB_PASSWORD="$(param "$STG_DB_PARAM_PATH/DB_PASSWORD")"

  local v bad=()
  for v in MYSQL_ROOT_PASSWORD REPL_PASSWORD PROXYSQL_ADMIN_PASSWORD MON_PASSWORD APP_DB_NAME APP_DB_USER APP_DB_PASSWORD; do
    if [ "${!v}" = CHANGE_ME ]; then
      bad+=("$v(CHANGE_ME)")
    elif ! [[ "${!v}" =~ ^[A-Za-z0-9._-]+$ ]]; then
      bad+=("$v(영숫자 . _ - 만 허용: proxysql.cnf·SQL 문자열에 그대로 들어간다)")
    fi
  done
  [ "${#bad[@]}" -eq 0 ] || die "SSM 값 확인 필요: ${bad[*]}"
  [[ "$APP_DB_NAME" =~ ^[A-Za-z0-9_]+$ ]] || die "DB_NAME은 영숫자·_만"
}

rds_master() {
  [ "$RDS_SECRET_ARN" != NONE ] || die "stg RDS가 관리형 master 비밀번호(Secrets Manager)가 아니다"
  local s
  s="$(aws secretsmanager get-secret-value --secret-id "$RDS_SECRET_ARN" --query SecretString --output text --region "$AWS_REGION")"
  RDS_MASTER_USER="$(jq -r .username <<<"$s")"
  RDS_MASTER_PASSWORD="$(jq -r .password <<<"$s")"
}

host_ip() {
  local token
  token="$(curl -fsS -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')"
  curl -fsS -H "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/local-ipv4
}

tty_flag() { if [ -t 0 ] && [ -t 1 ]; then echo "-it"; else echo "-i"; fi; }

compose() {
  local profiles=""
  [ "${V1_BACKEND_IMAGE:-NONE}" = NONE ] || profiles=app
  COMPOSE_PROFILES="$profiles" docker compose --project-directory "$BASE" -f "$BASE/compose.yaml" --env-file "$BASE/.env" "$@"
}

endpoint_state() { cat "$STATE/endpoint" 2>/dev/null || echo mysql; }

write_compose_env() {
  local ep db_host db_port
  ep="$(endpoint_state)"
  case "$ep" in
    mysql)    db_host=mysql;    db_port=3306 ;;
    proxysql) db_host=proxysql; db_port=6033 ;;
    *) die "알 수 없는 endpoint: $ep" ;;
  esac
  umask 077
  cat > "$BASE/.env" <<ENV
MYSQL_IMAGE=$MYSQL_IMAGE
PROXYSQL_IMAGE=$PROXYSQL_IMAGE
SOCAT_IMAGE=$SOCAT_IMAGE
NGINX_IMAGE=$NGINX_IMAGE
V1_BACKEND_IMAGE=$([ "$V1_BACKEND_IMAGE" = NONE ] && echo none || echo "$V1_BACKEND_IMAGE")
HOST_PRIVATE_IP=$(host_ip)
V1_DB_HOST=$db_host
V1_DB_PORT=$db_port
ENV
}

# --- SQL 클라이언트 ------------------------------------------------------------

sql_v1() {
  docker exec "$(tty_flag)" -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$V1_CONTAINER" \
    mysql -uroot --default-character-set=utf8mb4 "$@"
}

sql_rds() {
  rds_master
  docker run --rm "$(tty_flag)" --network host -e MYSQL_PWD="$RDS_MASTER_PASSWORD" "$MYSQL_IMAGE" \
    mysql -h "$RDS_HOST" -P "$RDS_PORT" -u "$RDS_MASTER_USER" --ssl-mode=REQUIRED --default-character-set=utf8mb4 "$@"
}

sql_admin() {
  docker run --rm "$(tty_flag)" --network host -e MYSQL_PWD="$PROXYSQL_ADMIN_PASSWORD" "$MYSQL_IMAGE" \
    mysql -h 127.0.0.1 -P 6032 -u radmin --prompt='proxysql> ' "$@"
}

# --- 명령 ----------------------------------------------------------------------

cmd_render() {
  need_root
  local reset=false
  [ "${1:-}" = "--reset-proxysql" ] && reset=true

  install -d -m 0750 "$BASE" "$CONF" "$BASE/env" "$BASE/proxysql" "$BASE/nginx" "$STATE"
  aws s3 sync "s3://$MIG_BUCKET/config/" "$CONF/" --delete --only-show-errors --region "$AWS_REGION"
  install -m 0755 "$CONF/bin/mig" /usr/local/bin/mig

  load_conf
  load_secrets

  umask 077
  cat > "$BASE/env/mysql.env" <<ENV
MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD
MYSQL_DATABASE=$APP_DB_NAME
MYSQL_USER=$APP_DB_USER
MYSQL_PASSWORD=$APP_DB_PASSWORD
ENV

  if [ "$V1_BACKEND_IMAGE" != NONE ]; then
    local v1_env
    v1_env="$(param "$SSM_PATH/V1_BACKEND_ENV")"
    [ "$v1_env" != CHANGE_ME ] || die "SSM $SSM_PATH/V1_BACKEND_ENV 가 CHANGE_ME (V1 backend 이미지를 쓰려면 V1 backend.env 내용을 넣는다)"
    {
      grep -Ev '^[[:space:]]*(DB_HOST|DB_PORT|DB_NAME|DB_USERNAME|DB_PASSWORD)[[:space:]]*=' <<<"$v1_env" || true
      printf 'DB_NAME=%s\nDB_USERNAME=%s\nDB_PASSWORD=%s\n' "$APP_DB_NAME" "$APP_DB_USER" "$APP_DB_PASSWORD"
    } > "$BASE/env/backend.env"
  else
    : > "$BASE/env/backend.env"
  fi

  export PROXYSQL_ADMIN_PASSWORD MON_PASSWORD RDS_HOST RDS_PORT APP_DB_USER APP_DB_PASSWORD MYSQL_SERVER_VERSION
  # shellcheck disable=SC2016
  envsubst '${PROXYSQL_ADMIN_PASSWORD} ${MON_PASSWORD} ${RDS_HOST} ${RDS_PORT} ${APP_DB_USER} ${APP_DB_PASSWORD} ${MYSQL_SERVER_VERSION}' \
    < "$CONF/proxysql.cnf.tpl" > "$BASE/proxysql/proxysql.cnf"
  chmod 0644 "$BASE/proxysql/proxysql.cnf"
  umask 022

  install -m 0644 "$CONF/nginx.conf" "$BASE/nginx/nginx.conf"
  install -m 0644 "$CONF/compose.yaml" "$BASE/compose.yaml"
  write_compose_env

  if [ "$V1_BACKEND_IMAGE" != NONE ]; then
    aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "${V1_BACKEND_IMAGE%%/*}" >/dev/null
  fi

  if $reset; then
    compose rm -sf proxysql || true
    docker volume rm moyeota-proxysql 2>/dev/null || true
    echo "proxysql datadir 초기화 — proxysql.cnf 값으로 다시 시작한다"
  fi

  compose up -d --remove-orphans
  compose ps
}

cmd_users() {
  need_root; load_conf; load_secrets
  local common_v1 common_rds
  read -r -d '' common_v1 <<SQL || true
CREATE USER IF NOT EXISTS '$APP_DB_USER'@'%' IDENTIFIED BY '$APP_DB_PASSWORD';
ALTER USER '$APP_DB_USER'@'%' IDENTIFIED BY '$APP_DB_PASSWORD';
GRANT ALL PRIVILEGES ON $APP_DB_NAME.* TO '$APP_DB_USER'@'%';
CREATE USER IF NOT EXISTS 'repl'@'%' IDENTIFIED BY '$REPL_PASSWORD';
ALTER USER 'repl'@'%' IDENTIFIED BY '$REPL_PASSWORD';
GRANT REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO 'repl'@'%';
CREATE USER IF NOT EXISTS 'mig_mon'@'%' IDENTIFIED BY '$MON_PASSWORD';
ALTER USER 'mig_mon'@'%' IDENTIFIED BY '$MON_PASSWORD';
GRANT PROCESS, REPLICATION CLIENT ON *.* TO 'mig_mon'@'%';
GRANT SELECT ON performance_schema.* TO 'mig_mon'@'%';
GRANT SELECT, EXECUTE ON sys.* TO 'mig_mon'@'%';
GRANT SELECT ON $APP_DB_NAME.* TO 'mig_mon'@'%';
SQL
  common_rds="$common_v1"

  echo "== V1(sim) — sql_log_bin=0 (계정 변경이 binlog를 타고 RDS로 복제되지 않게)"
  { echo "SET SESSION sql_log_bin = 0;"; echo "$common_v1"; echo "SELECT user, host, plugin FROM mysql.user WHERE user IN ('$APP_DB_USER','repl','mig_mon');"; } | sql_v1 -t
  echo "== stg RDS"
  { echo "$common_rds"; echo "SELECT user, host, plugin FROM mysql.user WHERE user IN ('$APP_DB_USER','repl','mig_mon');"; } | sql_rds -t
}

check() {
  local name="$1"; shift
  if out="$("$@" 2>&1)"; then
    printf 'PASS  %-38s %s\n' "$name" "$(tr '\n' ' ' <<<"$out" | cut -c1-90)"
  else
    printf 'FAIL  %-38s %s\n' "$name" "$(tr '\n' ' ' <<<"$out" | cut -c1-160)"
  fi
}

mysql_client() {
  local network="$1" host="$2" port="$3" user="$4" pw="$5"; shift 5
  docker run --rm -i --network "$network" -e MYSQL_PWD="$pw" "$MYSQL_IMAGE" \
    mysql -h "$host" -P "$port" -u "$user" -N "$@"
}

cmd_check() {
  need_root; load_conf; load_secrets; rds_master
  local ip
  ip="$(host_ip)"
  check "V1 mysql (root, 컨테이너)"           sql_v1 -N -e "SELECT CONCAT('server_id=', @@server_id, ' log_bin=', @@log_bin, ' fmt=', @@binlog_format, ' gtid=', @@gtid_mode)"
  check "relay $ip:3307 → V1 (mig_mon)"       mysql_client host "$ip" 3307 mig_mon "$MON_PASSWORD" -e "SELECT CONCAT('server_id=', @@server_id)"
  check "RDS (master, TLS)"                   mysql_client host "$RDS_HOST" "$RDS_PORT" "$RDS_MASTER_USER" "$RDS_MASTER_PASSWORD" --ssl-mode=REQUIRED -e "SELECT CONCAT(VERSION(), ' log_bin=', @@log_bin, ' fmt=', @@binlog_format, ' ps=', @@performance_schema, ' ro=', @@read_only)"
  check "RDS binlog retention hours"          mysql_client host "$RDS_HOST" "$RDS_PORT" "$RDS_MASTER_USER" "$RDS_MASTER_PASSWORD" --ssl-mode=REQUIRED -e "CALL mysql.rds_show_configuration"
  check "RDS (앱 계정, TLS)"                   mysql_client host "$RDS_HOST" "$RDS_PORT" "$APP_DB_USER" "$APP_DB_PASSWORD" --ssl-mode=REQUIRED -e "SELECT CURRENT_USER()"
  check "RDS (mig_mon)"                       mysql_client host "$RDS_HOST" "$RDS_PORT" mig_mon "$MON_PASSWORD" -e "SELECT COUNT(*) FROM performance_schema.threads"
  check "ProxySQL 6033 → hg10 (앱 계정)"       mysql_client "$APP_NETWORK" proxysql 6033 "$APP_DB_USER" "$APP_DB_PASSWORD" -e "SELECT CONCAT('server_id=', @@server_id, ' host=', @@hostname)"
  check "ProxySQL 서버 상태 (runtime)"         sql_admin -N -e "SELECT CONCAT(hostgroup_id, ':', hostname, ':', status, ':ssl', use_ssl) FROM runtime_mysql_servers"
  check "ProxySQL monitor 최근 ping 오류"      sql_admin -N -e "SELECT CONCAT(hostname, ' ', IFNULL(ping_error, 'ok')) FROM monitor.mysql_server_ping_log ORDER BY time_start_us DESC LIMIT 2"
  check "ProxySQL exporter $ip:6070/metrics"   bash -c "curl -fsS -m 5 http://$ip:6070/metrics | grep -c '^proxysql_'"
}

cmd_status() {
  need_root; load_conf; load_secrets
  echo "== 컨테이너 (backend endpoint: $(endpoint_state))"
  compose ps
  echo "== ProxySQL"
  sql_admin -t -e "SELECT hostgroup_id AS hg, hostname, port, status, use_ssl, max_connections, comment FROM runtime_mysql_servers ORDER BY hostgroup_id, hostname;
SELECT hostgroup AS hg, srv_host, status, ConnUsed, ConnFree, ConnOK, ConnERR, Queries, Latency_us FROM stats_mysql_connection_pool;"
  echo "== V1(sim)"
  sql_v1 -t -e "SELECT @@server_id, @@read_only, @@super_read_only; SHOW BINARY LOG STATUS;"
  sql_v1 -e "SHOW REPLICA STATUS\G" | grep -E 'Replica_IO_Running|Replica_SQL_Running|Seconds_Behind_Source|Last_.*Error:|Source_Host|Relay_Source_Log_File|Exec_Source_Log_Pos' || echo "(복제 없음)"
  echo "== stg RDS"
  sql_rds -t -e "SELECT @@server_id, @@read_only, @@log_bin, @@binlog_format; SHOW BINARY LOG STATUS;"
  sql_rds -e "SHOW REPLICA STATUS\G" | grep -E 'Replica_IO_Running|Replica_SQL_Running|Seconds_Behind_Source|Last_.*Error:|Source_Host|Relay_Source_Log_File|Exec_Source_Log_Pos' || echo "(복제 없음)"
}

cmd_endpoint() {
  need_root; load_conf
  case "${1:-}" in
    mysql|proxysql) ;;
    *) die "사용법: mig endpoint mysql|proxysql" ;;
  esac
  [ "$V1_BACKEND_IMAGE" != NONE ] || die "V1 backend 이미지가 없다 (migration_v1_backend_image)"
  echo "$1" > "$STATE/endpoint"
  write_compose_env
  local t0
  t0="$(date +%s)"
  compose up -d --no-deps backend
  until [ "$(docker inspect -f '{{.State.Health.Status}}' moyeota-backend-1 2>/dev/null)" = healthy ]; do
    sleep 1
    [ $(( $(date +%s) - t0 )) -lt 180 ] || die "backend가 180초 안에 healthy가 되지 않았다"
  done
  echo "backend DB endpoint=$1, 재생성~healthy $(( $(date +%s) - t0 ))초"
}

cmd_load_dump() {
  need_root; load_conf; load_secrets
  local key="${1:-}"
  [ -n "$key" ] || die "사용법: mig load-dump <s3 key> (예: dumps/d0/v1-prod-20261020.sql.gz)"
  local reader=(cat)
  [[ "$key" == *.gz ]] && reader=(gunzip -c)
  local t0
  t0="$(date +%s)"
  aws s3 cp "s3://$MIG_BUCKET/$key" - --region "$AWS_REGION" --only-show-errors | "${reader[@]}" \
    | docker exec -i -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$V1_CONTAINER" mysql -uroot --default-character-set=utf8mb4
  echo "적재 완료 $(( $(date +%s) - t0 ))초"
  sql_v1 -t -e "SELECT table_name, table_rows FROM information_schema.tables WHERE table_schema = '$APP_DB_NAME' ORDER BY table_name"
}

replica_configured() { "$@" -e "SHOW REPLICA STATUS\G" | grep -q 'Source_Host'; }

cmd_repl_smoke() {
  need_root; load_conf; load_secrets
  local file pos rest ip
  case "${1:-}" in
    forward)
      ! replica_configured sql_rds || die "RDS에 이미 복제 설정이 있다 — 리허설 중이면 시험하지 않는다 (sudo mig status)"
      ip="$(host_ip)"
      read -r file pos rest < <(sql_v1 -N -e "SHOW BINARY LOG STATUS") || true
      [ -n "${file:-}" ] || die "V1 binlog 위치를 읽지 못했다"
      echo "RDS → $ip:3307 (repl, TLS) from $file:$pos"
      sql_rds -e "CALL mysql.rds_set_external_source('$ip', 3307, 'repl', '$REPL_PASSWORD', '$file', $pos, 1); CALL mysql.rds_start_replication;"
      sleep 8
      sql_rds -e "SHOW REPLICA STATUS\G" | grep -E 'Replica_IO_Running:|Replica_SQL_Running:|Last_IO_Error:|Last_SQL_Error:' || true
      sql_rds -e "CALL mysql.rds_stop_replication; CALL mysql.rds_reset_external_source;" >/dev/null
      echo "정리 완료 (rds_reset_external_source)"
      ;;
    reverse)
      ! replica_configured sql_v1 || die "V1에 이미 복제 설정이 있다 — 리허설 중이면 시험하지 않는다 (sudo mig status)"
      read -r file pos rest < <(sql_rds -N -e "SHOW BINARY LOG STATUS") || true
      [ -n "${file:-}" ] || die "RDS binlog가 꺼져 있다 — 백업 보존 기간 1일 이상 (런북 E-3)"
      local connected=false
      if ! docker inspect -f '{{json .NetworkSettings.Networks}}' "$V1_CONTAINER" | grep -q "\"$APP_NETWORK\""; then
        docker network connect "$APP_NETWORK" "$V1_CONTAINER"
        connected=true
      fi
      echo "V1 → $RDS_HOST:$RDS_PORT (repl, TLS) from $file:$pos"
      sql_v1 -e "CHANGE REPLICATION SOURCE TO SOURCE_HOST='$RDS_HOST', SOURCE_PORT=$RDS_PORT, SOURCE_USER='repl', SOURCE_PASSWORD='$REPL_PASSWORD', SOURCE_LOG_FILE='$file', SOURCE_LOG_POS=$pos, SOURCE_SSL=1; START REPLICA IO_THREAD;"
      sleep 8
      sql_v1 -e "SHOW REPLICA STATUS\G" | grep -E 'Replica_IO_Running:|Last_IO_Error:' || true
      sql_v1 -e "STOP REPLICA; RESET REPLICA ALL;"
      if $connected; then docker network disconnect "$APP_NETWORK" "$V1_CONTAINER"; fi
      echo "정리 완료 (RESET REPLICA ALL$($connected && echo ', app 네트워크 분리'))"
      ;;
    *) die "사용법: mig repl-smoke forward|reverse" ;;
  esac
}

case "${1:-}" in
  render)    shift; cmd_render "$@" ;;
  users)     shift; cmd_users ;;
  check)     shift; cmd_check ;;
  status)    shift; cmd_status ;;
  endpoint)  shift; cmd_endpoint "$@" ;;
  load-dump) shift; cmd_load_dump "$@" ;;
  repl-smoke) shift; cmd_repl_smoke "$@" ;;
  sql)
    shift
    need_root; load_conf; load_secrets
    target="${1:-}"; shift || true
    case "$target" in
      v1)    sql_v1 "$@" ;;
      rds)   sql_rds "$@" ;;
      admin) sql_admin "$@" ;;
      *) die "사용법: mig sql v1|rds|admin [mysql 옵션]" ;;
    esac
    ;;
  *)
    sed -n '3,15p' "$0"
    exit 1
    ;;
esac
