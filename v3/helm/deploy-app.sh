#!/usr/bin/env bash
# 앱 하나를 EKS에 배포한다.
# 사용법: deploy-app.sh <stg|prod> <rest-api|websocket|fastapi|frontend|worker|matching> [--kafka]
#   --kafka: Kafka 도입 이후 이미지와 설정을 쓴다. worker, matching은 항상 적용되며 stg 전용이다.
#   prod: CONFIRM_PROD_DEPLOY=yes가 필요하고, ALB 규칙에 EKS Target Group이 먼저 연결되어 있어야 한다.
# 전제: terraform apply 완료, install-platform.sh 완료.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

CLUSTER_NAME="moyeota-v3-eks"
PLACEHOLDER_DIGEST="sha256:0000000000000000000000000000000000000000000000000000000000000000"
stage="${1:-}"
service="${2:-}"
kafka=0
if [ "${3:-}" = "--kafka" ]; then
  kafka=1
elif [ -n "${3:-}" ]; then
  echo "알 수 없는 옵션입니다: '$3'" >&2
  exit 1
fi

if [ "$stage" != "stg" ] && [ "$stage" != "prod" ]; then
  echo "지원하는 스테이지는 stg, prod입니다: '$stage'" >&2
  exit 1
fi

kafka_client=0
case "$service" in
  rest-api) target_group_key="$stage-rest"; backend=1; kafka_client=1 ;;
  websocket) target_group_key="$stage-websocket"; backend=1 ;;
  fastapi) target_group_key=""; backend=0 ;;
  frontend) target_group_key="$stage-frontend"; backend=0 ;;
  worker | matching) target_group_key=""; backend=1; kafka_client=1; kafka=1 ;;
  *)
    echo "알 수 없는 서비스입니다: '$service'" >&2
    exit 1
    ;;
esac

if [ "$kafka" -eq 1 ] && [ "$service" = "frontend" ]; then
  echo "frontend에는 Kafka 설정이 없습니다." >&2
  exit 1
fi

context="$(kubectl config current-context)"
case "$context" in
  *"/$CLUSTER_NAME") ;;
  *)
    echo "현재 컨텍스트가 $CLUSTER_NAME 이 아닙니다: $context" >&2
    exit 1
    ;;
esac

if [ "$stage" = "prod" ]; then
  if [ "$kafka" -eq 1 ]; then
    echo "prod에는 Kafka 설정을 배포하지 않습니다." >&2
    exit 1
  fi
  if [ "${CONFIRM_PROD_DEPLOY:-}" != "yes" ]; then
    echo "prod 배포는 CONFIRM_PROD_DEPLOY=yes가 필요합니다." >&2
    exit 1
  fi
  # Target Group이 ALB에 연결되어야 대상이 healthy가 되고 readiness gate가 통과한다.
  if [ -n "$target_group_key" ]; then
    ../scripts/alb-weight.sh prod assert-attached
  fi
fi

# 뒤의 파일이 앞의 값을 덮어쓴다. map(env, secrets)은 병합된다.
args=()
if [ "$backend" -eq 1 ]; then
  args+=(--values app-values/services/backend-common.yaml)
fi
args+=(--values "app-values/services/$service.yaml")
if [ "$backend" -eq 1 ]; then
  args+=(--values "app-values/$stage/backend-common.yaml")
fi
args+=(--values "app-values/$stage/$service.yaml")

if [ "$kafka" -eq 1 ]; then
  if [ "$backend" -eq 1 ]; then
    overlay="app-values/$stage/kafka/backend-common.yaml"
    # MONGODB_URI 하나만 없어도 ExternalSecret 전체가 동기화되지 않는다.
    found="$(aws ssm describe-parameters \
      --parameter-filters "Key=Name,Values=/moyeota/v2/$stage/backend/MONGODB_URI" \
      --query 'length(Parameters)' --output text)"
    if [ "$found" != "1" ]; then
      echo "/moyeota/v2/$stage/backend/MONGODB_URI 가 없어 중단합니다." >&2
      exit 1
    fi
  else
    overlay="app-values/$stage/kafka/fastapi.yaml"
  fi
  if grep -q "$PLACEHOLDER_DIGEST" "$overlay"; then
    echo "$overlay 의 image.digest를 release 이미지로 바꿔야 합니다." >&2
    exit 1
  fi
  args+=(--values "$overlay")
  if [ "$kafka_client" -eq 1 ]; then
    args+=(--values "app-values/$stage/kafka/client.yaml")
  fi
fi

if [ -n "$target_group_key" ]; then
  arn="$(terraform -chdir=../eks output -json target_group_arns | jq -er --arg key "$target_group_key" '.[$key]')"
  args+=(--set-string "targetGroupBinding.targetGroupARN=$arn")
fi

helm upgrade --install "$service" ./app \
  --namespace "$stage" \
  "${args[@]}" \
  --wait --timeout 10m

kubectl --namespace "$stage" rollout status "deployment/$service" --timeout=5m
