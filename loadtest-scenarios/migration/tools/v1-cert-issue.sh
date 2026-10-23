#!/usr/bin/env bash
# [PC] v1.moyeota.com 인증서를 Route53 DNS-01로 발급하고 이관 버킷 config/tls/에 올린다.
# V1 서버는 건드리지 않는다. 설치는 [V1]에서 v1-cert-install.sh로 한다.
# moyeota.com은 V2 Prod ALB(ACM), stg.moyeota.com은 stg ALB(ACM)가 따로 맡으므로 V1 인증서에는 넣지 않는다.
set -euo pipefail

export AWS_PROFILE="${AWS_PROFILE:-moyeota-terraform}" AWS_REGION="${AWS_REGION:-ap-northeast-2}"
OUT="${OUT:-$HOME/.moyeota-v1-cert}"
IMAGE=certbot/dns-route53:v3.0.1
DOMAINS=(-d v1.moyeota.com)
BUCKET="moyeota-migration-$(aws sts get-caller-identity --query Account --output text)"

ts() { date '+%H:%M:%S'; }
step() { printf '\n[%s] ▶ %s\n' "$(ts)" "$1"; }
ok() { printf '[%s]   PASS  %s\n' "$(ts)" "$1"; }
die() { printf '[%s]   FAIL  %s\n' "$(ts)" "$1"; exit 1; }

certbot() {
  docker run --rm \
    -v "$HOME/.aws:/root/.aws:ro" -e AWS_PROFILE \
    -v "$OUT/etc:/etc/letsencrypt" -v "$OUT/lib:/var/lib/letsencrypt" \
    "$IMAGE" certonly --dns-route53 --non-interactive --agree-tos \
    --register-unsafely-without-email --cert-name v1.moyeota.com "${DOMAINS[@]}" "$@" 2>&1 |
    grep -vE '^\s*$|Saving debug' | sed 's/^/          /'
  return "${PIPESTATUS[0]}"
}

mkdir -p "$OUT" && chmod 700 "$OUT"

step "CERT-1 certbot 이미지 ($IMAGE)"
docker pull -q "$IMAGE" >/dev/null && ok "pull 완료"

step "CERT-2 staging dry-run (_acme-challenge TXT 생성 → 검증 → 삭제)"
certbot --dry-run && ok "dry-run" || die "dry-run 실패. Route53 권한·호스팅 영역 확인"

step "CERT-3 발급"
certbot --keep-until-expiring && ok "발급" || die "발급 실패"

LIVE="$OUT/etc/live/v1.moyeota.com"
step "CERT-4 발급 결과 확인"
san="$(openssl x509 -in "$LIVE/fullchain.pem" -noout -text | grep -o 'DNS:[^,]*' | tr '\n' ' ')"
printf '          SAN: %s\n' "$san"
openssl x509 -in "$LIVE/fullchain.pem" -noout -issuer -enddate | sed 's/^/          /'
[[ "$san" == *DNS:v1.moyeota.com* ]] && ok "v1.moyeota.com 포함" || die "SAN에 v1.moyeota.com 없음"

step "CERT-5 이관 버킷 업로드 (s3://$BUCKET/config/tls/)"
aws s3 cp "$LIVE/fullchain.pem" "s3://$BUCKET/config/tls/fullchain.pem" --sse AES256 --only-show-errors
aws s3 cp "$LIVE/privkey.pem" "s3://$BUCKET/config/tls/privkey.pem" --sse AES256 --only-show-errors
aws s3 cp "$(dirname "$0")/v1-cert-install.sh" "s3://$BUCKET/config/tls/v1-cert-install.sh" --only-show-errors
ok "업로드 완료 (fullchain.pem, privkey.pem, v1-cert-install.sh)"

printf '\n[%s] ■ 다음: [V1] SSM 세션에서\n' "$(ts)"
printf '          sudo aws s3 cp s3://%s/config/tls/v1-cert-install.sh /tmp/ --region %s\n' "$BUCKET" "$AWS_REGION"
printf '          sudo MIG_BUCKET=%s bash /tmp/v1-cert-install.sh\n' "$BUCKET"
printf '        설치 직후(mig render 전에) [PC]에서 키 사본 삭제 — mig render는 config/를 통째로 sync한다:\n'
printf '          aws s3 rm s3://%s/config/tls/ --recursive\n' "$BUCKET"
