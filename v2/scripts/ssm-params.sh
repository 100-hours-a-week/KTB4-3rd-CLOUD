#!/usr/bin/env bash
# 앱 환경 변수(SSM Parameter Store) 값 입력·점검 스크립트
#   파라미터 자체는 Terraform(v2/ssm.tf)이 CHANGE_ME로 만든다. 실제 값은 이 스크립트로 넣는다.
#
#   사용법:
#     v2/scripts/ssm-params.sh list     <stage>              # 키 목록과 입력 여부 (값은 출력하지 않음)
#     v2/scripts/ssm-params.sh check    <stage>              # CHANGE_ME가 남아 있으면 exit 1 (배포 전 점검용)
#     v2/scripts/ssm-params.sh set      <stage> <group/KEY>  # 값 입력 (화면·history에 남지 않음)
#     v2/scripts/ssm-params.sh redeploy <stage>              # 값 변경 후 해당 스테이지 서비스 재시작
#
#   예) v2/scripts/ssm-params.sh set dev backend/DB_PASSWORD
#   환경 변수: CONFIG_PREFIX(SSM 경로, 기본 moyeota/v2), PROJECT(클러스터 이름 접두어, 기본 moyeota-v2),
#             AWS_PROFILE / AWS_REGION
set -Eeuo pipefail

CONFIG_PREFIX="${CONFIG_PREFIX:-moyeota/v2}"   # terraform var.config_path_prefix 와 같아야 한다
PROJECT="${PROJECT:-moyeota-v2}"               # ECS 클러스터 이름 = <PROJECT>-<stage>
PLACEHOLDER="CHANGE_ME"

usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

stage_arg() {
  [[ "${1:-}" =~ ^(dev|stg|prod)$ ]] || { echo "stage는 dev|stg|prod 중 하나" >&2; exit 1; }
  echo "$1"
}

# "<name>\t<value>" 를 출력한다. 값은 내부 비교용으로만 쓴다.
fetch() {
  aws ssm get-parameters-by-path --path "/${CONFIG_PREFIX}/$1/" --recursive --with-decryption \
    --query 'Parameters[].[Name,Value]' --output text
}

list() {
  local stage; stage="$(stage_arg "${1:-}")"
  local missing=0
  while IFS=$'\t' read -r name value; do
    [[ -z "$name" ]] && continue
    if [[ "$value" == "$PLACEHOLDER" ]]; then
      printf '  [ 미입력 ] %s\n' "${name#/${CONFIG_PREFIX}/${stage}/}"; missing=$((missing + 1))
    else
      printf '  [  입력  ] %s\n' "${name#/${CONFIG_PREFIX}/${stage}/}"
    fi
  done < <(fetch "$stage" | sort)
  echo "미입력 ${missing}개 (/${CONFIG_PREFIX}/${stage}/)"
  (( missing == 0 ))
}

check() {
  if list "$@"; then echo "OK"; else echo "CHANGE_ME가 남아 있음 — set으로 값을 넣은 뒤 배포" >&2; exit 1; fi
}

set_value() {
  local stage; stage="$(stage_arg "${1:-}")"
  local key="${2:-}"
  [[ "$key" =~ ^[a-z0-9_-]+/[A-Z0-9_]+$ ]] || { echo "키 형식: <group>/<KEY> (예: backend/DB_PASSWORD)" >&2; exit 1; }
  local name="/${CONFIG_PREFIX}/${stage}/${key}"

  # Terraform이 만든 파라미터만 수정한다 (오타로 새 파라미터가 생기는 것 방지)
  aws ssm get-parameter --name "$name" --query 'Parameter.Name' --output text >/dev/null \
    || { echo "${name} 없음 — v2/ssm.tf에 키를 추가하고 terraform apply 먼저" >&2; exit 1; }

  local value
  read -rsp "${name} 값: " value; echo
  [[ -n "$value" ]] || { echo "빈 값은 넣지 않음" >&2; exit 1; }

  aws ssm put-parameter --name "$name" --type SecureString --value "$value" --overwrite \
    --query 'Version' --output text | sed "s#^#${name} → version #"
  echo "반영하려면: $0 redeploy ${stage}"
}

redeploy() {
  local stage; stage="$(stage_arg "${1:-}")"
  local cluster="${PROJECT}-${stage}"
  local svc
  for svc in $(aws ecs list-services --cluster "$cluster" --query 'serviceArns[]' --output text | tr '\t' '\n' | sed 's#.*/##'); do
    aws ecs update-service --cluster "$cluster" --service "$svc" --force-new-deployment \
      --query 'service.serviceName' --output text | sed 's#$# : 재배포 시작#'
  done
}

case "${1:-}" in
  list)     shift; list "$@" || true ;;
  check)    shift; check "$@" ;;
  set)      shift; set_value "$@" ;;
  redeploy) shift; redeploy "$@" ;;
  *)        usage ;;
esac
