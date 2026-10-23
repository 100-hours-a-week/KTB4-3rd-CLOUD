# =============================================================================
# 이관 리허설 ProxySQL 초기 설정 — mig render가 ${VAR} 자리를 채워 /opt/moyeota-migration/proxysql/proxysql.cnf 로 쓴다
#   시작 상태 : hg10 app-writer = V1 Prod MySQL(ONLINE) + stg RDS(OFFLINE_HARD)
#
#   - datadir(moyeota-migration-proxysql 볼륨)에 proxysql.db가 있으면 이 파일은 읽지 않는다.
#     전환(S3~S5)·롤백 뒤에는 LOAD ... TO RUNTIME 다음에 SAVE ... TO DISK까지 해야 컨테이너 재시작 때 상태가 유지된다.
#     이 파일 값으로 처음부터 다시 시작하려면 `sudo mig render --reset-proxysql`
#   - mysql_replication_hostgroups는 두지 않는다 (read_only 값으로 writer를 자동 판정하면 RDS가 read_only=0이 되는 순간 writer가 둘이 된다)
#   - 백엔드 연결은 TLS(use_ssl=1). MySQL 8.4 기본 인증(caching_sha2_password)의 전체 인증을 평문에서 하지 않는다
#   - monitor 계정(mig_mon)이 틀리면 ping 실패가 쌓여 서버가 SHUNNED될 수 있다 → 두 DB에 같은 비밀번호로 만든다 (mig users)
#   - 앱 계정은 stg 앱 계정이다. S0에서 V1 backend가 이 계정으로 proxysql:6033에 붙는다 (mig endpoint proxysql)
#   - radmin : 호스트에서 127.0.0.1:6032로 접속하는 관리 계정 (admin 계정은 컨테이너 안 루프백 전용)
# =============================================================================
datadir="/var/lib/proxysql"

admin_variables=
{
    admin_credentials="admin:admin;radmin:${PROXYSQL_ADMIN_PASSWORD}"
    mysql_ifaces="0.0.0.0:6032"
    restapi_enabled=true
    restapi_port=6070
    prometheus_memory_metrics_interval=60
}

mysql_variables=
{
    threads=2
    max_connections=512
    interfaces="0.0.0.0:6033"
    server_version="${MYSQL_SERVER_VERSION}"
    default_charset="utf8mb4"
    default_collation_connection="utf8mb4_0900_ai_ci"
    monitor_username="mig_mon"
    monitor_password="${MON_PASSWORD}"
    connect_timeout_server=3000
    connect_timeout_server_max=10000
    commands_stats=true
    sessions_sort=true
}

mysql_servers=
(
    { address="${V1_MYSQL_HOST}", port=3306, hostgroup=10, status="ONLINE", max_connections=20, use_ssl=1, comment="v1-writer" },
    { address="${RDS_HOST}", port=${RDS_PORT}, hostgroup=10, status="OFFLINE_HARD", max_connections=20, use_ssl=1, comment="rds-writer" }
)

mysql_users=
(
    { username="${APP_DB_USER}", password="${APP_DB_PASSWORD}", default_hostgroup=10, transaction_persistent=1, active=1 }
)
