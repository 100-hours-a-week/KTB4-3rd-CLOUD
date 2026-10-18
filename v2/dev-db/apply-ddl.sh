#!/usr/bin/env bash
# dev MySQL(dev EC2 호스트의 mysql 컨테이너)에 DDL 파일을 SSM Run Command로 바로 적용한다.
#   사용: ./apply-ddl.sh <ddl.sql> [instance-id]
#   - 호스트에 파일을 복사하거나 세션에 붙여넣을 필요 없음 (DDL을 base64로 실어 보냄)
#   - DB 계정·비밀번호는 컨테이너 환경변수(MYSQL_USER 등)를 쓰므로 Run Command 이력에 비밀값이 남지 않는다
#   - 실행 결과로 적용 후 테이블 목록을 출력한다
set -euo pipefail

DDL=${1:?usage: ./apply-ddl.sh <ddl.sql> [instance-id]}
HOST=${2:-$(aws ec2 describe-instances \
  --filters Name=tag:Name,Values=moyeota-v2-dev Name=instance-state-name,Values=running \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)}
[[ -f "$DDL" ]] || { echo "DDL 파일 없음: $DDL" >&2; exit 1; }
[[ "$HOST" == i-* ]] || { echo "dev 호스트를 찾지 못함: $HOST" >&2; exit 1; }

# 호스트에서 실행될 스크립트 (DDL 본문을 그대로 포함)
REMOTE=$(cat <<EOF
set -euo pipefail
cat > /tmp/moyeota-ddl.sql <<'__MOYEOTA_DDL__'
$(cat "$DDL")
__MOYEOTA_DDL__
docker exec -i mysql sh -c 'mysql -u"\$MYSQL_USER" -p"\$MYSQL_PASSWORD" "\$MYSQL_DATABASE"' < /tmp/moyeota-ddl.sql
rm -f /tmp/moyeota-ddl.sql
echo "== tables"
docker exec mysql sh -c 'mysql -N -u"\$MYSQL_USER" -p"\$MYSQL_PASSWORD" "\$MYSQL_DATABASE" -e "SHOW TABLES"' 2>/dev/null
EOF
)

B64=$(printf '%s\n' "$REMOTE" | base64 | tr -d '\n')
echo "host=$HOST  ddl=$(wc -c < "$DDL" | tr -d ' ')B  payload=${#B64}B"

CMD_ID=$(aws ssm send-command --instance-ids "$HOST" --document-name AWS-RunShellScript \
  --comment "apply dev DDL $(basename "$DDL")" \
  --parameters "{\"commands\":[\"echo $B64 | base64 -d | bash\"]}" \
  --query Command.CommandId --output text)
echo "command=$CMD_ID (실행 대기 중)"

aws ssm wait command-executed --command-id "$CMD_ID" --instance-id "$HOST" || true
aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$HOST" \
  --query '[Status,StandardOutputContent,StandardErrorContent]' --output text \
  | grep -v "Using a password on the command line"
