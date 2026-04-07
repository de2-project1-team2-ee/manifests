#!/bin/bash

# 1. 리전 변수($AWS_REGION)가 없을 때만 env_config.sh 로드 [cite: 2026-04-04]
source ./env_config.sh || exit 1

echo "📊 Grafana Ingress 재적용 중..."
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring --reuse-values \
  --set grafana.ingress.enabled=true \
  --set grafana.ingress.ingressClassName=alb \
  --set grafana.ingress.annotations."alb\.ingress\.kubernetes\.io/scheme"=internet-facing \
  --set grafana.ingress.annotations."alb\.ingress\.kubernetes\.io/target-type"=ip

