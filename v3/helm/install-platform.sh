#!/usr/bin/env bash
# V3 EKS 플랫폼 컴포넌트를 순서대로 설치한다. 다시 실행해도 된다.
# 전제: terraform apply 완료, aws eks update-kubeconfig 실행, system 노드 Ready.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

CLUSTER_NAME="moyeota-v3-eks"
LB_CONTROLLER_CHART_VERSION="3.6.2"
METRICS_SERVER_CHART_VERSION="3.14.0"
EXTERNAL_SECRETS_CHART_VERSION="2.14.0"
ALLOY_CHART_VERSION="1.15.0"
KUBE_STATE_METRICS_CHART_VERSION="9.0.0"
ARGOCD_CHART_VERSION="10.17.1"

# 다른 클러스터에 설치하지 않도록 현재 컨텍스트를 확인한다.
context="$(kubectl config current-context)"
case "$context" in
  *"/$CLUSTER_NAME") ;;
  *)
    echo "현재 컨텍스트가 $CLUSTER_NAME 이 아닙니다: $context" >&2
    exit 1
    ;;
esac

helm repo add eks https://aws.github.io/eks-charts --force-update
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server --force-update
helm repo add external-secrets https://charts.external-secrets.io --force-update
helm repo add grafana https://grafana.github.io/helm-charts --force-update
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
helm repo add argo https://argoproj.github.io/argo-helm --force-update
helm repo update eks metrics-server external-secrets grafana prometheus-community argo

helm upgrade --install platform-base ./platform-base \
  --namespace kube-system --wait

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --version "$LB_CONTROLLER_CHART_VERSION" \
  --namespace kube-system \
  --values values/aws-load-balancer-controller.yaml \
  --wait --timeout 5m

helm upgrade --install metrics-server metrics-server/metrics-server \
  --version "$METRICS_SERVER_CHART_VERSION" \
  --namespace kube-system \
  --values values/metrics-server.yaml \
  --wait --timeout 5m

helm upgrade --install external-secrets external-secrets/external-secrets \
  --version "$EXTERNAL_SECRETS_CHART_VERSION" \
  --namespace external-secrets \
  --values values/external-secrets.yaml \
  --wait --timeout 5m

# SecretStore CRD가 있어야 하므로 External Secrets 다음에 설치한다.
helm upgrade --install platform-secrets ./platform-secrets \
  --namespace kube-system --wait

helm upgrade --install kube-state-metrics prometheus-community/kube-state-metrics \
  --version "$KUBE_STATE_METRICS_CHART_VERSION" \
  --namespace monitoring \
  --values values/kube-state-metrics.yaml \
  --wait --timeout 5m

helm upgrade --install alloy grafana/alloy \
  --version "$ALLOY_CHART_VERSION" \
  --namespace monitoring \
  --values values/alloy.yaml \
  --wait --timeout 5m

helm upgrade --install argocd argo/argo-cd \
  --version "$ARGOCD_CHART_VERSION" \
  --namespace argocd --create-namespace \
  --values values/argocd.yaml \
  --wait --timeout 5m

echo "==> 플랫폼 설치 완료"
