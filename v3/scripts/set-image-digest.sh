#!/usr/bin/env bash
# 스테이지의 앱 이미지 digest를 values 파일에 기록한다. CI의 gitops-deploy action이 호출한다.
# 사용법: set-image-digest.sh <dev|stg|prod> <be|fe|ai> <sha256:...>
# 출력: 변경 대상 파일의 저장소 기준 경로
set -euo pipefail

stage="${1:-}"
app="${2:-}"
digest="${3:-}"

case "$stage" in
  dev | stg | prod) ;;
  *)
    echo "지원하는 스테이지는 dev, stg, prod입니다: '$stage'" >&2
    exit 1
    ;;
esac

case "$app" in
  be) file_name="backend-common.yaml" ;;
  fe) file_name="frontend.yaml" ;;
  ai) file_name="fastapi.yaml" ;;
  *)
    echo "지원하는 앱은 be, fe, ai입니다: '$app'" >&2
    exit 1
    ;;
esac

if ! [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "digest 형식이 올바르지 않습니다: '$digest'" >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
relative_path="v3/helm/app-values/$stage/$file_name"
target="$repo_root/$relative_path"

# 한 파일에 image.digest가 정확히 하나일 때만 바꾼다.
count="$(grep -c '^  digest: ' "$target" || true)"
if [ "$count" != "1" ]; then
  echo "$relative_path 의 digest 줄이 1개가 아닙니다: $count" >&2
  exit 1
fi

updated="$(mktemp)"
trap 'rm -f "$updated"' EXIT
sed -E "s|^  digest: .*$|  digest: $digest|" "$target" >"$updated"
cat "$updated" >"$target"

echo "$relative_path"
