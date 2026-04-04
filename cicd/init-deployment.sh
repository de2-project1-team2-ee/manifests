#!/bin/bash
# ──────────────────────────────────────────────
# deployment.yaml 초기 설정 스크립트
# AWS Account ID / Region을 자동 조회하여 이미지 URL 세팅
#
# 사용법: 레포 루트에서 bash cicd/init-deployment.sh
# ──────────────────────────────────────────────
set -euo pipefail

DEPLOYMENT="k8s/deployment.yaml"

echo ">> AWS 계정 정보 조회 중..."

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
AWS_REGION=$(aws configure get region)

echo "   Account ID: $AWS_ACCOUNT_ID"
echo "   Region:     $AWS_REGION"

sed -i -e "s|__AWS_ACCOUNT_ID__|$AWS_ACCOUNT_ID|" \
       -e "s|__AWS_REGION__|$AWS_REGION|" \
       "$DEPLOYMENT"

echo ">> $DEPLOYMENT 업데이트 완료"
grep "image:" "$DEPLOYMENT" | head -1
