#!/usr/bin/env bash
# [V1] 이관 버킷 config/tls/의 인증서를 V1 nginx가 쓰는 인증서 경로에 설치하고 reload한다.
# nginx 컨테이너를 재생성·재시작하지 않는다(nginx -s reload). nginx -t 실패 시 백업으로 되돌린다.
set -euo pipefail

BUCKET="${MIG_BUCKET:?MIG_BUCKET 필요 (moyeota-migration-<account-id>)}"
NGINX="${NGINX_CONTAINER:-moyeota-nginx-1}"
HOST=v1.moyeota.com
WORK="$(mktemp -d)"
BACKUP="/var/backups/moyeota-cert-$(date +%Y%m%d%H%M%S)"
trap 'rm -rf "$WORK"' EXIT

ts() { date '+%H:%M:%S'; }
step() { printf '\n[%s] ▶ %s\n' "$(ts)" "$1"; }
ok() { printf '[%s]   PASS  %s\n' "$(ts)" "$1"; }
die() { printf '[%s]   FAIL  %s\n' "$(ts)" "$1"; exit 1; }

# 컨테이너 안 경로 → 호스트 bind mount 경로
host_path() {
  docker inspect "$NGINX" --format '{{range .Mounts}}{{.Destination}} {{.Source}}{{println}}{{end}}' |
    while read -r dst src; do
      [[ -n "$dst" && "$1" == "$dst"* ]] && { echo "${src}${1#"$dst"}"; return; }
    done
}

step "INST-1 nginx 인증서 경로"
mapfile -t certs < <(docker exec "$NGINX" nginx -T 2>/dev/null | awk '$1=="ssl_certificate"{gsub(";","",$2);print $2}' | sort -u)
mapfile -t keys < <(docker exec "$NGINX" nginx -T 2>/dev/null | awk '$1=="ssl_certificate_key"{gsub(";","",$2);print $2}' | sort -u)
(( ${#certs[@]} == 1 && ${#keys[@]} == 1 )) || die "인증서 경로가 1개가 아님: ${certs[*]:-없음} / ${keys[*]:-없음}"
CERT="$(host_path "${certs[0]}")"; KEY="$(host_path "${keys[0]}")"
[[ -n "$CERT" && -n "$KEY" ]] || die "bind mount가 아님 (${certs[0]}). 수동 설치 필요"
ok "컨테이너 ${certs[0]} → 호스트 $CERT"
ok "컨테이너 ${keys[0]} → 호스트 $KEY"

step "INST-2 새 인증서 다운로드·검증"
aws s3 cp "s3://$BUCKET/config/tls/fullchain.pem" "$WORK/fullchain.pem" --only-show-errors
aws s3 cp "s3://$BUCKET/config/tls/privkey.pem" "$WORK/privkey.pem" --only-show-errors
san="$(openssl x509 -in "$WORK/fullchain.pem" -noout -text | grep -o 'DNS:[^,]*' | tr '\n' ' ')"
printf '          SAN: %s\n' "$san"
[[ "$san" == *"DNS:$HOST"* ]] || die "SAN에 $HOST 없음"
[[ "$(openssl x509 -in "$WORK/fullchain.pem" -noout -pubkey)" == "$(openssl pkey -in "$WORK/privkey.pem" -pubout)" ]] || die "인증서와 키 불일치"
ok "SAN·키 일치"

step "INST-3 기존 인증서 백업 ($BACKUP)"
mkdir -p "$BACKUP" && cp -L "$CERT" "$BACKUP/fullchain.pem" && cp -L "$KEY" "$BACKUP/privkey.pem"
ok "백업 완료"

step "INST-4 설치 · nginx -t"
cp "$WORK/fullchain.pem" "$CERT" && cp "$WORK/privkey.pem" "$KEY" && chmod 600 "$KEY"
if ! docker exec "$NGINX" nginx -t 2>&1 | sed 's/^/          /'; then
  cp "$BACKUP/fullchain.pem" "$CERT"; cp "$BACKUP/privkey.pem" "$KEY"
  die "nginx -t 실패 → 기존 인증서로 복구함"
fi
ok "nginx -t"

step "INST-5 nginx reload (재시작 없음)"
docker exec "$NGINX" nginx -s reload && sleep 2 && ok "reload"

step "INST-6 SNI $HOST 확인"
served="$(echo | openssl s_client -connect 127.0.0.1:443 -servername "$HOST" 2>/dev/null | openssl x509 -noout -text | grep -o 'DNS:[^,]*' | tr '\n' ' ')"
printf '          제공 SAN: %s\n' "$served"
[[ "$served" == *"DNS:$HOST"* ]] && ok "$HOST 인증서 제공 중" || die "아직 이전 인증서. 백업: $BACKUP"

printf '\n[%s] ■ 완료. 되돌리기: cp %s/{fullchain,privkey}.pem 를 %s, %s 로 복사 후 docker exec %s nginx -s reload\n' \
  "$(ts)" "$BACKUP" "$CERT" "$KEY" "$NGINX"
