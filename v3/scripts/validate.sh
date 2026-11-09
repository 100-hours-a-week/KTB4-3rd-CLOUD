#!/usr/bin/env bash
# V3 Terraform·Helm 코드를 검증한다. CI(.github/workflows/v3-check.yml)와 로컬에서 같은 명령을 쓴다.
# AWS 자격 증명이 필요 없다. backend를 초기화하지 않고 plan도 실행하지 않는다.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# 로컬의 .terraform을 쓰면 이미 초기화된 S3 backend의 자격 증명을 찾으므로 임시 폴더에서 검증한다.
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

echo "==> terraform fmt"
terraform fmt -check -recursive -diff .

tf_dirs="$(find . -name '*.tf' -not -path '*/.terraform/*' -exec dirname {} \; | sort -u)"
for dir in $tf_dirs; do
  echo "==> terraform validate: $dir"
  export TF_DATA_DIR="$work_dir/$dir"
  terraform -chdir="$dir" init -backend=false -input=false -lockfile=readonly -no-color
  terraform -chdir="$dir" validate -no-color
done

chart_dirs="$(find . -name Chart.yaml -not -path '*/.terraform/*' -exec dirname {} \; | sort -u)"
for dir in $chart_dirs; do
  echo "==> helm lint: $dir"
  helm lint "$dir"
  helm template "$dir" >/dev/null
done

echo "==> V3 check passed"
