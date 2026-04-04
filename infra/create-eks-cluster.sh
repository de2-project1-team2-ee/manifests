#!/bin/bash
# ──────────────────────────────────────────────
# EKS 클러스터 생성 스크립트
# network-project 스택에서 VPC/Subnet ID를 자동 조회하여
# project-eks-cluster.yaml에 치환 후 eksctl 실행
#
# 사용법: cd infra && bash create-eks-cluster.sh
# 사전 조건: network-project CloudFormation 스택 배포 완료
# ──────────────────────────────────────────────
set -euo pipefail

STACK_NAME="network-project"
TEMPLATE="project-eks-cluster.yaml"
CONFIG="/tmp/eks-cluster-config.yaml"

echo ">> $STACK_NAME 스택에서 네트워크 정보 조회 중..."

VPC_ID=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='VpcId'].OutputValue" --output text)
PUBLIC_SUBNET_1=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='PublicSubnet1Id'].OutputValue" --output text)
PUBLIC_SUBNET_2=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='PublicSubnet2Id'].OutputValue" --output text)
PRIVATE_SUBNET_1=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='PrivateSubnet1Id'].OutputValue" --output text)
PRIVATE_SUBNET_2=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='PrivateSubnet2Id'].OutputValue" --output text)

echo "   VPC:        $VPC_ID"
echo "   Public-1:   $PUBLIC_SUBNET_1"
echo "   Public-2:   $PUBLIC_SUBNET_2"
echo "   Private-1:  $PRIVATE_SUBNET_1"
echo "   Private-2:  $PRIVATE_SUBNET_2"

# 플레이스홀더 치환
sed -e "s|__VPC_ID__|$VPC_ID|" \
    -e "s|__PUBLIC_SUBNET_1__|$PUBLIC_SUBNET_1|" \
    -e "s|__PUBLIC_SUBNET_2__|$PUBLIC_SUBNET_2|" \
    -e "s|__PRIVATE_SUBNET_1__|$PRIVATE_SUBNET_1|" \
    -e "s|__PRIVATE_SUBNET_2__|$PRIVATE_SUBNET_2|" \
    "$TEMPLATE" > "$CONFIG"

echo ""
echo ">> 생성된 설정 파일: $CONFIG"
echo ">> EKS 클러스터 생성 시작..."
echo ""

eksctl create cluster -f "$CONFIG"
