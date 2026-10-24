#!/usr/bin/env bash
# =============================================================================
# mig — V1 Prod 이관 리허설 사이드카 운영 도구 (migration.tf가 이관 버킷 config/bin/mig 로 올린다)
#
#   sudo mig render [--reset-proxysql]   설정 받기 → proxysql.cnf·.env 생성 → 사이드카(proxysql·relay·migcli) up
#   sudo mig users                       V1·stg RDS에 stg 앱 계정·repl·mig_mon 생성/비밀번호 맞춤 (V1 쪽은 binlog에 남기지 않음)
#   sudo mig check                       연결 경로 점검 (V1·relay·RDS·ProxySQL·exporter·backend endpoint)
#   sudo mig status                      컨테이너·ProxySQL 서버 상태·양쪽 복제 상태
#   sudo mig sql v1|rds|admin [mysql 옵션]   V1 root / RDS master / ProxySQL radmin 셸 (예: -e "SELECT 1")
#   sudo mig endpoint proxysql|mysql     V1 backend만 재생성 (S0: proxysql:6033 + stg 앱 계정 / 복귀: V1 원래 설정)
#   sudo mig schema-diff <label>         V1·RDS 테이블 정의(뷰·트리거·루틴 제외)를 덤프해 비교 → state/schema/<label>.diff (차이 있으면 종료 코드 1)
#   sudo mig repl-smoke forward|reverse  복제 연결만 시험하고 되돌린다 (forward: RDS → relay, reverse: V1 → RDS, 둘 다 TLS)
#   sudo mig teardown [--drop-users]     사이드카·edge 연결·S1 덤프 제거 (V1 Compose 프로젝트 moyeota는 건드리지 않는다)
#
#   V1 Compose 프로젝트(moyeota)에 대해서는 `up -d --no-deps --force-recreate backend` 외의 명령을 쓰지 않는다
#   비밀번호는 SSM·Secrets Manager·V1 MySQL 컨테이너 환경변수에서 그때그때 읽는다 (파일·셸 기록에 남기지 않는다)
#   주의: S3(쓰기 보류)~S9(관찰 창) 사이에는 render를 다시 돌리지 않는다 (ProxySQL이 재생성될 수 있다)
# =============================================================================
set -Eeuo pipefail
shopt -u patsub_replacement 2>/dev/null || true

BOOT=/etc/moyeota-migration/bootstrap.env
BASE=/opt/moyeota-migration
CONF="$BASE/config"
STATE="$BASE/state"
PROJECT=moyeota-migration
CLI=moyeota-migcli
PROXYSQL_CONTAINER=moyeota-proxysql
EDGE_NETWORK=moyeota-migration-edge

die() { echo "mig: $*" >&2; exit 1; }
need_root() { [ "$(id -u)" -eq 0 ] || die "sudo로 실행한다"; }

[ -f "$BOOT" ] || die "$BOOT 없음 — 런북의 V1 Prod 부트스트랩을 먼저 한다"
# shellcheck disable=SC1090
source "$BOOT"
: "${MIG_BUCKET:?}" "${AWS_REGION:?}"

load_conf() {
  [ -f "$CONF/migration.env" ] || die "$CONF/migration.env 없음 — sudo mig render 먼저"
  set -a
  # shellcheck disable=SC1091
  source "$CONF/migration.env"
  set +a
  V1_MYSQL_HOST="$V1_MYSQL_CONTAINER"
  # shellcheck disable=SC2034
  MYSQL_SERVER_VERSION="${MYSQL_IMAGE##*:}"
  resolve_v1_networks
}

# 컨테이너가 붙은 네트워크 (이관용 네트워크 제외)
container_networks() {
  docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{println $k}}{{end}}' "$1" 2>/dev/null |
    grep -v -e '^$' -e 'migration' || true
}

# migration.env의 V1 네트워크 이름이 호스트에 없으면 실행 중인 컨테이너 기준으로 정한다.
# DB: V1 MySQL이 붙은 네트워크 (여러 개면 internal). 앱: backend 네트워크 중 DB가 아닌 것 (여러 개면 nginx와 공유하는 것).
resolve_v1_networks() {
  local n nets
  if ! docker network inspect "$V1_DB_NETWORK" >/dev/null 2>&1; then
    mapfile -t nets < <(container_networks "$V1_MYSQL_CONTAINER")
    if (( ${#nets[@]} > 1 )); then
      mapfile -t nets < <(for n in "${nets[@]}"; do
        [ "$(docker network inspect -f '{{.Internal}}' "$n")" = true ] && echo "$n"; done)
    fi
    (( ${#nets[@]} == 1 )) || die "V1 DB 네트워크를 정할 수 없다 ($V1_MYSQL_CONTAINER: ${nets[*]:-없음}) — migration_v1_compose.db_network를 지정한다"
    echo "mig: V1_DB_NETWORK $V1_DB_NETWORK 없음 → $V1_MYSQL_CONTAINER 기준 ${nets[0]}" >&2
    V1_DB_NETWORK="${nets[0]}"
  fi
  if ! docker network inspect "$V1_APP_NETWORK" >/dev/null 2>&1; then
    mapfile -t nets < <(container_networks "$V1_BACKEND_CONTAINER" | grep -vxF "$V1_DB_NETWORK" || true)
    if (( ${#nets[@]} > 1 )); then
      mapfile -t nets < <(for n in "${nets[@]}"; do
        container_networks "${V1_NGINX_CONTAINER:-moyeota-nginx-1}" | grep -qxF "$n" && echo "$n"; done)
    fi
    (( ${#nets[@]} == 1 )) || die "V1 앱 네트워크를 정할 수 없다 ($V1_BACKEND_CONTAINER: ${nets[*]:-없음}) — migration_v1_compose.app_network를 지정한다"
    echo "mig: V1_APP_NETWORK $V1_APP_NETWORK 없음 → $V1_BACKEND_CONTAINER 기준 ${nets[0]}" >&2
    V1_APP_NETWORK="${nets[0]}"
  fi
}

param() {
  aws ssm get-parameter --with-decryption --name "$1" --query Parameter.Value --output text --region "$AWS_REGION"
}

load_secrets() {
  REPL_PASSWORD="$(param "$SSM_PATH/REPL_PASSWORD")"
  PROXYSQL_ADMIN_PASSWORD="$(param "$SSM_PATH/PROXYSQL_ADMIN_PASSWORD")"
  MON_PASSWORD="$(param "$MON_PASSWORD_PARAM")"
  APP_DB_NAME="$(param "$STG_DB_PARAM_PATH/DB_NAME")"
  APP_DB_USER="$(param "$STG_DB_PARAM_PATH/DB_USERNAME")"
  APP_DB_PASSWORD="$(param "$STG_DB_PARAM_PATH/DB_PASSWORD")"

  local v bad=()
  for v in REPL_PASSWORD PROXYSQL_ADMIN_PASSWORD MON_PASSWORD APP_DB_NAME APP_DB_USER APP_DB_PASSWORD; do
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

# migration.env의 V1 Prod 사설 IP와 지금 호스트가 같아야 한다 (다른 호스트에서 실행 방지)
check_host() {
  local ip
  ip="$(host_ip)"
  [ "$ip" = "$V1_PRIVATE_IP" ] || die "이 호스트($ip)는 migration.env의 V1 Prod($V1_PRIVATE_IP)가 아니다"
}

tty_flag() { if [ -t 0 ] && [ -t 1 ]; then echo "-it"; else echo "-i"; fi; }

running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ]; }

compose() {
  docker compose -p "$PROJECT" --project-directory "$BASE" -f "$BASE/compose.yaml" --env-file "$BASE/.env" "$@"
}

v1_compose_file() {
  local f
  for f in compose.yaml compose.yml docker-compose.yml docker-compose.yaml; do
    [ -f "$V1_DEPLOY_PATH/$f" ] && { echo "$V1_DEPLOY_PATH/$f"; return; }
  done
  die "$V1_DEPLOY_PATH에 V1 compose 파일이 없다"
}

v1_db_name() { docker exec "$V1_BACKEND_CONTAINER" printenv DB_NAME; }
v1_db_host() { docker exec "$V1_BACKEND_CONTAINER" printenv DB_HOST; }

v1_preflight() {
  local c
  for c in "$V1_MYSQL_CONTAINER" "$V1_BACKEND_CONTAINER"; do
    running "$c" || die "V1 컨테이너 $c 가 실행 중이 아니다"
  done
  docker network inspect "$V1_APP_NETWORK" "$V1_DB_NETWORK" >/dev/null || die "V1 네트워크($V1_APP_NETWORK, $V1_DB_NETWORK)가 없다"
  local v1db
  v1db="$(v1_db_name)"
  [ "$v1db" = "$APP_DB_NAME" ] || die "V1 DB_NAME($v1db)과 stg DB_NAME($APP_DB_NAME)이 다르다 — 복제 대상 스키마 이름이 같아야 한다"
}

render_tpl() {
  local tpl v
  tpl="$(cat "$1")"
  for v in PROXYSQL_ADMIN_PASSWORD MON_PASSWORD RDS_HOST RDS_PORT APP_DB_USER APP_DB_PASSWORD MYSQL_SERVER_VERSION V1_MYSQL_HOST; do
    tpl="${tpl//\$\{$v\}/${!v}}"
  done
  printf '%s\n' "$tpl"
}

write_compose_env() {
  umask 077
  cat > "$BASE/.env" <<ENV
MYSQL_IMAGE=$MYSQL_IMAGE
PROXYSQL_IMAGE=$PROXYSQL_IMAGE
SOCAT_IMAGE=$SOCAT_IMAGE
HOST_PRIVATE_IP=$V1_PRIVATE_IP
RELAY_PORT=$RELAY_PORT
V1_MYSQL_HOST=$V1_MYSQL_HOST
V1_APP_NETWORK=$V1_APP_NETWORK
V1_DB_NETWORK=$V1_DB_NETWORK
ENV
  umask 022
}

# --- SQL 클라이언트 ------------------------------------------------------------

sql_v1() {
  # shellcheck disable=SC2016,SC2046
  docker exec $(tty_flag) "$V1_MYSQL_CONTAINER" \
    sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -uroot --default-character-set=utf8mb4 "$@"' sh "$@"
}

sql_rds() {
  rds_master
  # shellcheck disable=SC2046
  docker exec $(tty_flag) -e MYSQL_PWD="$RDS_MASTER_PASSWORD" "$CLI" \
    mysql -h "$RDS_HOST" -P "$RDS_PORT" -u "$RDS_MASTER_USER" --ssl-mode=REQUIRED --default-character-set=utf8mb4 "$@"
}

sql_admin() {
  # shellcheck disable=SC2046
  docker exec $(tty_flag) -e MYSQL_PWD="$PROXYSQL_ADMIN_PASSWORD" "$CLI" \
    mysql -h 127.0.0.1 -P 6032 -u radmin --prompt='proxysql> ' "$@"
}

# host 네트워크 클라이언트 (relay·RDS 직접)
mysql_host() {
  local host="$1" port="$2" user="$3" pw="$4"; shift 4
  docker exec -i -e MYSQL_PWD="$pw" "$CLI" mysql -h "$host" -P "$port" -u "$user" -N "$@"
}

# V1 app 네트워크 클라이언트 (backend와 같은 경로로 proxysql:6033)
mysql_app_net() {
  local user="$1" pw="$2"; shift 2
  docker run --rm -i --network "$V1_APP_NETWORK" -e MYSQL_PWD="$pw" "$MYSQL_IMAGE" \
    mysql -h proxysql -P 6033 -u "$user" -N "$@"
}

# --- 명령 ----------------------------------------------------------------------

cmd_render() {
  need_root
  local reset=false
  [ "${1:-}" = "--reset-proxysql" ] && reset=true

  install -d -m 0750 "$BASE" "$CONF" "$BASE/proxysql" "$STATE"
  aws s3 sync "s3://$MIG_BUCKET/config/" "$CONF/" --delete --only-show-errors --region "$AWS_REGION"
  install -m 0755 "$CONF/bin/mig" /usr/local/bin/mig
  install -m 0755 "$CONF/bin/cutover-switch" /usr/local/bin/cutover-switch

  load_conf
  check_host
  load_secrets
  v1_preflight

  render_tpl "$CONF/proxysql.cnf.tpl" > "$BASE/proxysql/proxysql.cnf"
  chmod 0644 "$BASE/proxysql/proxysql.cnf"
  install -m 0644 "$CONF/compose.yaml" "$BASE/compose.yaml"
  write_compose_env

  if $reset; then
    compose rm -sf proxysql || true
    docker volume rm moyeota-migration-proxysql 2>/dev/null || true
    echo "proxysql datadir 초기화 — proxysql.cnf 값으로 다시 시작한다"
  fi

  compose up -d
  compose ps
}

cmd_users() {
  need_root; load_conf; check_host; load_secrets
  local sql
  read -r -d '' sql <<SQL || true
CREATE USER IF NOT EXISTS '$APP_DB_USER'@'%' IDENTIFIED BY '$APP_DB_PASSWORD';
ALTER USER '$APP_DB_USER'@'%' IDENTIFIED BY '$APP_DB_PASSWORD';
GRANT ALL PRIVILEGES ON \`$APP_DB_NAME\`.* TO '$APP_DB_USER'@'%';
CREATE USER IF NOT EXISTS 'repl'@'%' IDENTIFIED BY '$REPL_PASSWORD';
ALTER USER 'repl'@'%' IDENTIFIED BY '$REPL_PASSWORD';
GRANT REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO 'repl'@'%';
CREATE USER IF NOT EXISTS 'mig_mon'@'%' IDENTIFIED BY '$MON_PASSWORD';
ALTER USER 'mig_mon'@'%' IDENTIFIED BY '$MON_PASSWORD';
GRANT PROCESS, REPLICATION CLIENT ON *.* TO 'mig_mon'@'%';
GRANT SELECT ON performance_schema.* TO 'mig_mon'@'%';
GRANT SELECT, EXECUTE ON sys.* TO 'mig_mon'@'%';
GRANT SELECT ON \`$APP_DB_NAME\`.* TO 'mig_mon'@'%';
SQL

  echo "== V1 Prod — sql_log_bin=0 (계정 변경이 binlog를 타고 RDS로 복제되지 않게)"
  { echo "SET SESSION sql_log_bin = 0;"; echo "$sql"; echo "SELECT user, host, plugin FROM mysql.user WHERE user IN ('$APP_DB_USER','repl','mig_mon');"; } | sql_v1 -t
  echo "== stg RDS"
  { echo "$sql"; echo "SELECT user, host, plugin FROM mysql.user WHERE user IN ('$APP_DB_USER','repl','mig_mon');"; } | sql_rds -t
}

check() {
  local name="$1"; shift
  local out
  if out="$("$@" 2>&1)"; then
    printf 'PASS  %-40s %s\n' "$name" "$(tr '\n' ' ' <<<"$out" | cut -c1-90)"
  else
    CHECK_FAILURES=$((CHECK_FAILURES + 1))
    printf 'FAIL  %-40s %s\n' "$name" "$(tr '\n' ' ' <<<"$out" | cut -c1-160)"
  fi
}

cmd_check() {
  need_root; load_conf; check_host; load_secrets; rds_master
  local CHECK_FAILURES=0 expected_db_host=mysql
  local ip="$V1_PRIVATE_IP"
  [ ! -f "$STATE/endpoint" ] || read -r expected_db_host < "$STATE/endpoint"
  check "도구 (aws·jq·docker compose)"            bash -c "command -v aws && command -v jq && docker compose version --short"
  check "V1 컨테이너·네트워크·DB_NAME"              v1_preflight
  check "V1 backend DB_HOST=$expected_db_host"      test "$(v1_db_host)" = "$expected_db_host"
  check "V1 mysql binlog (root, 컨테이너)"          sql_v1 -N -e "SELECT CONCAT(VERSION(), ' server_id=', @@server_id, ' log_bin=', @@log_bin, ' fmt=', @@binlog_format, ' gtid=', @@gtid_mode, ' ro=', @@read_only, '/', @@super_read_only)"
  check "V1 binlog 보존 (expire_logs_seconds)"     sql_v1 -N -e "SELECT @@binlog_expire_logs_seconds"
  check "사이드카 컨테이너"                         bash -c "for c in $PROXYSQL_CONTAINER moyeota-relay $CLI; do docker inspect -f '{{.Name}} {{.State.Status}}' \$c; done"
  check "relay $ip:$RELAY_PORT → V1 (mig_mon)"     mysql_host "$ip" "$RELAY_PORT" mig_mon "$MON_PASSWORD" -e "SELECT CONCAT('server_id=', @@server_id)"
  check "RDS (master, TLS)"                        mysql_host "$RDS_HOST" "$RDS_PORT" "$RDS_MASTER_USER" "$RDS_MASTER_PASSWORD" --ssl-mode=REQUIRED -e "SELECT CONCAT(VERSION(), ' server_id=', @@server_id, ' log_bin=', @@log_bin, ' fmt=', @@binlog_format, ' ps=', @@performance_schema, ' ro=', @@read_only)"
  check "RDS binlog retention hours"               mysql_host "$RDS_HOST" "$RDS_PORT" "$RDS_MASTER_USER" "$RDS_MASTER_PASSWORD" --ssl-mode=REQUIRED -e "CALL mysql.rds_show_configuration"
  check "RDS (stg 앱 계정, TLS)"                   mysql_host "$RDS_HOST" "$RDS_PORT" "$APP_DB_USER" "$APP_DB_PASSWORD" --ssl-mode=REQUIRED -e "SELECT CURRENT_USER()"
  check "RDS (mig_mon)"                            mysql_host "$RDS_HOST" "$RDS_PORT" mig_mon "$MON_PASSWORD" -e "SELECT COUNT(*) FROM performance_schema.threads"
  check "ProxySQL 6033 → hg10 (stg 앱 계정)"        mysql_app_net "$APP_DB_USER" "$APP_DB_PASSWORD" -e "SELECT CONCAT('server_id=', @@server_id, ' host=', @@hostname)"
  check "ProxySQL 서버 상태 (runtime)"              sql_admin -N -e "SELECT hostgroup_id || ':' || hostname || ':' || status || ':ssl' || use_ssl FROM runtime_mysql_servers"
  check "ProxySQL monitor 최근 ping 오류"           sql_admin -N -e "SELECT hostname || ' ' || IFNULL(ping_error, 'ok') FROM monitor.mysql_server_ping_log ORDER BY time_start_us DESC LIMIT 2"
  check "ProxySQL exporter $ip:6070/metrics"       bash -c "curl -fsS -m 5 http://$ip:6070/metrics | grep -c '^proxysql_'"
  [ "$CHECK_FAILURES" -eq 0 ] || die "$CHECK_FAILURES preflight check(s) failed — T2로 진행하지 않는다"
  echo "ALL CHECKS PASSED (backend DB_HOST=$expected_db_host)"
}

cmd_status() {
  need_root; load_conf; check_host; load_secrets
  echo "== 사이드카 (V1 backend DB_HOST: $(v1_db_host))"
  compose ps
  echo "== ProxySQL"
  sql_admin -t -e "SELECT hostgroup_id AS hg, hostname, port, status, use_ssl, max_connections, comment FROM runtime_mysql_servers ORDER BY hostgroup_id, hostname;
SELECT hostgroup AS hg, srv_host, status, ConnUsed, ConnFree, ConnOK, ConnERR, Queries, Latency_us FROM stats_mysql_connection_pool;"
  echo "== V1 Prod"
  sql_v1 -t -e "SELECT @@server_id, @@read_only, @@super_read_only; SHOW BINARY LOG STATUS;"
  sql_v1 -e "SHOW REPLICA STATUS\G" | grep -E 'Replica_IO_Running|Replica_SQL_Running|Seconds_Behind_Source|Last_.*Error:|Source_Host|Relay_Source_Log_File|Exec_Source_Log_Pos' || echo "(복제 없음)"
  echo "== stg RDS"
  sql_rds -t -e "SELECT @@server_id, @@read_only, @@log_bin, @@binlog_format; SHOW BINARY LOG STATUS;"
  sql_rds -e "SHOW REPLICA STATUS\G" | grep -E 'Replica_IO_Running|Replica_SQL_Running|Seconds_Behind_Source|Last_.*Error:|Source_Host|Relay_Source_Log_File|Exec_Source_Log_Pos' || echo "(복제 없음)"
}

# V1 backend만 재생성한다. 이미지 digest는 V1 배포 기록(.deploy/backend.env)과 지금 실행 중인 이미지가 같을 때만 진행한다
cmd_endpoint() {
  need_root; load_conf; check_host
  local target="${1:-}"
  case "$target" in
    mysql|proxysql) ;;
    *) die "사용법: mig endpoint proxysql|mysql" ;;
  esac

  local release="$V1_DEPLOY_PATH/.deploy/backend.env" ref running_img
  [ -f "$release" ] || die "$release 없음 — V1 backend 이미지 digest를 알 수 없다"
  # shellcheck disable=SC1090
  ref="$(set -a; source "$release"; set +a; echo "${BACKEND_IMAGE_REF:-}")"
  [ -n "$ref" ] || die "$release에 BACKEND_IMAGE_REF가 없다"
  running_img="$(docker inspect -f '{{.Config.Image}}' "$V1_BACKEND_CONTAINER")"
  [ "$running_img" = "$ref" ] || die "실행 중 이미지($running_img)와 배포 기록($ref)이 다르다 — 재생성하면 이미지가 바뀐다"

  local files=(-f "$(v1_compose_file)")
  if [ "$target" = proxysql ]; then
    load_secrets
    running "$PROXYSQL_CONTAINER" || die "ProxySQL이 실행 중이 아니다 — sudo mig render"
    mysql_app_net "$APP_DB_USER" "$APP_DB_PASSWORD" -e "SELECT 1" >/dev/null || die "proxysql:6033 (stg 앱 계정) 접속 실패 — sudo mig users, sudo mig check"
    umask 077
    cat > "$BASE/backend.override.yaml" <<YAML
services:
  backend:
    environment:
      DB_HOST: proxysql
      DB_PORT: "6033"
      DB_USERNAME: "$APP_DB_USER"
      DB_PASSWORD: "$APP_DB_PASSWORD"
YAML
    umask 022
    files+=(-f "$BASE/backend.override.yaml")
  fi

  local t0
  t0="$(date +%s)"
  (
    cd "$V1_DEPLOY_PATH"
    BACKEND_IMAGE_REF="$ref" docker compose --env-file .env "${files[@]}" up -d --no-deps --force-recreate backend
  )
  until [ "$(docker inspect -f '{{.State.Health.Status}}' "$V1_BACKEND_CONTAINER" 2>/dev/null)" = healthy ]; do
    sleep 1
    [ $(( $(date +%s) - t0 )) -lt 180 ] || die "backend가 180초 안에 healthy가 되지 않았다 — sudo mig endpoint mysql 로 되돌린다"
  done
  [ "$target" = proxysql ] || rm -f "$BASE/backend.override.yaml"
  echo "$target" > "$STATE/endpoint"
  echo "backend DB_HOST=$(v1_db_host), 재생성~healthy $(( $(date +%s) - t0 ))초"
}

replica_configured() { "$@" -e "SHOW REPLICA STATUS\G" | grep -q 'Source_Host'; }

edge_connect() {
  if ! docker inspect -f '{{json .NetworkSettings.Networks}}' "$V1_MYSQL_CONTAINER" | grep -q "\"$EDGE_NETWORK\""; then
    docker network connect "$EDGE_NETWORK" "$V1_MYSQL_CONTAINER"
    return 0
  fi
  return 1
}

edge_disconnect() {
  if docker inspect -f '{{json .NetworkSettings.Networks}}' "$V1_MYSQL_CONTAINER" | grep -q "\"$EDGE_NETWORK\""; then
    docker network disconnect "$EDGE_NETWORK" "$V1_MYSQL_CONTAINER"
  fi
}

cmd_repl_smoke() {
  need_root; load_conf; check_host; load_secrets
  local file pos rest
  case "${1:-}" in
    forward)
      ! replica_configured sql_rds || die "RDS에 이미 복제 설정이 있다 — 리허설 중이면 시험하지 않는다 (sudo mig status)"
      read -r file pos rest < <(sql_v1 -N -e "SHOW BINARY LOG STATUS") || true
      [ -n "${file:-}" ] || die "V1 binlog 위치를 읽지 못했다"
      echo "RDS → $V1_PRIVATE_IP:$RELAY_PORT (repl, TLS) from $file:$pos"
      sql_rds -e "CALL mysql.rds_set_external_source('$V1_PRIVATE_IP', $RELAY_PORT, 'repl', '$REPL_PASSWORD', '$file', $pos, 1); CALL mysql.rds_start_replication;"
      sleep 8
      sql_rds -e "SHOW REPLICA STATUS\G" | grep -E 'Replica_IO_Running:|Replica_SQL_Running:|Last_IO_Error:|Last_SQL_Error:' || true
      sql_rds -e "CALL mysql.rds_stop_replication; CALL mysql.rds_reset_external_source;" >/dev/null
      echo "정리 완료 (rds_reset_external_source)"
      ;;
    reverse)
      ! replica_configured sql_v1 || die "V1에 이미 복제 설정이 있다 — 리허설 중이면 시험하지 않는다 (sudo mig status)"
      read -r file pos rest < <(sql_rds -N -e "SHOW BINARY LOG STATUS") || true
      [ -n "${file:-}" ] || die "RDS binlog가 꺼져 있다 — 백업 보존 기간 1일 이상"
      local connected=false
      edge_connect && connected=true
      echo "V1 → $RDS_HOST:$RDS_PORT (repl, TLS) from $file:$pos"
      sql_v1 -e "CHANGE REPLICATION SOURCE TO SOURCE_HOST='$RDS_HOST', SOURCE_PORT=$RDS_PORT, SOURCE_USER='repl', SOURCE_PASSWORD='$REPL_PASSWORD', SOURCE_LOG_FILE='$file', SOURCE_LOG_POS=$pos, SOURCE_SSL=1; START REPLICA IO_THREAD;"
      sleep 8
      sql_v1 -e "SHOW REPLICA STATUS\G" | grep -E 'Replica_IO_Running:|Last_IO_Error:' || true
      sql_v1 -e "STOP REPLICA; RESET REPLICA ALL;"
      if $connected; then edge_disconnect; fi
      echo "정리 완료 (RESET REPLICA ALL$($connected && echo ', edge 네트워크 분리'))"
      ;;
    *) die "사용법: mig repl-smoke forward|reverse" ;;
  esac
}

schema_norm() {
  sed -E -e 's/ AUTO_INCREMENT=[0-9]+//' -e '/^\/\*![0-9]+ .*\*\/;$/d' -e '/^--/d' -e '/^$/d'
}

cmd_schema_diff() {
  need_root; load_conf; check_host; load_secrets; rds_master
  local label="${1:-}" dir="$STATE/schema"
  [[ "$label" =~ ^[A-Za-z0-9_-]+$ ]] || die "사용법: mig schema-diff <label> (예: s1, s7)"
  local opts=(--no-data --single-transaction --skip-lock-tables --skip-comments --skip-triggers
    --no-tablespaces --set-gtid-purged=OFF --skip-add-drop-table --skip-set-charset)
  install -d -m 0700 "$dir"
  # shellcheck disable=SC2016
  docker exec "$V1_MYSQL_CONTAINER" sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysqldump -uroot "$@"' sh "${opts[@]}" "$APP_DB_NAME" \
    | schema_norm > "$dir/$label-v1.sql"
  docker exec -e MYSQL_PWD="$RDS_MASTER_PASSWORD" "$CLI" \
    mysqldump -h "$RDS_HOST" -P "$RDS_PORT" -u "$RDS_MASTER_USER" --ssl-mode=REQUIRED "${opts[@]}" "$APP_DB_NAME" \
    | schema_norm > "$dir/$label-rds.sql"
  echo "V1 CREATE TABLE $(grep -c '^CREATE TABLE' "$dir/$label-v1.sql") / RDS CREATE TABLE $(grep -c '^CREATE TABLE' "$dir/$label-rds.sql")"
  if diff -u --label "v1/$APP_DB_NAME" --label "rds/$APP_DB_NAME" "$dir/$label-v1.sql" "$dir/$label-rds.sql" > "$dir/$label.diff"; then
    echo "SCHEMA_MATCH ($label)"
  else
    echo "SCHEMA_DIFF ($label) → $dir/$label.diff"
    grep -E '^[-+](CREATE TABLE|  `|\) ENGINE)' "$dir/$label.diff" | head -60
    return 1
  fi
}

cmd_teardown() {
  need_root; load_conf; check_host
  local drop_users=false
  [ "${1:-}" = "--drop-users" ] && drop_users=true

  [ "$(v1_db_host)" != proxysql ] || die "V1 backend가 아직 proxysql을 쓴다 — sudo mig endpoint mysql (S10 결정에 맞춰) 먼저"
  ! replica_configured sql_v1 || die "V1에 복제 설정이 남아 있다 — sudo mig sql v1 -e 'STOP REPLICA; RESET REPLICA ALL' 먼저"

  if $drop_users; then
    load_secrets
    sql_v1 -e "SET SESSION sql_log_bin = 0; DROP USER IF EXISTS '$APP_DB_USER'@'%', 'repl'@'%', 'mig_mon'@'%';"
    echo "V1 Prod 이관 계정 삭제 ($APP_DB_USER, repl, mig_mon)"
  fi

  edge_disconnect
  compose down --volumes
  rm -f "$BASE/backend.override.yaml" "$BASE/proxysql/proxysql.cnf" "$BASE/.env"
  rm -rf /var/tmp/moyeota-migration
  echo "== V1 Prod 최종 상태 (read_only는 바꾸지 않는다)"
  sql_v1 -t -e "SELECT @@read_only, @@super_read_only; SHOW BINARY LOG STATUS;"
  echo "backend DB_HOST=$(v1_db_host)"
}

case "${1:-}" in
  render)     shift; cmd_render "$@" ;;
  users)      shift; cmd_users ;;
  check)      shift; cmd_check ;;
  status)     shift; cmd_status ;;
  endpoint)   shift; cmd_endpoint "$@" ;;
  repl-smoke) shift; cmd_repl_smoke "$@" ;;
  schema-diff) shift; cmd_schema_diff "$@" ;;
  teardown)   shift; cmd_teardown "$@" ;;
  sql)
    shift
    need_root; load_conf; check_host; load_secrets
    target="${1:-}"; shift || true
    case "$target" in
      v1)    sql_v1 "$@" ;;
      rds)   sql_rds "$@" ;;
      admin) sql_admin "$@" ;;
      *) die "사용법: mig sql v1|rds|admin [mysql 옵션]" ;;
    esac
    ;;
  *)
    sed -n '3,16p' "$0"
    exit 1
    ;;
esac
