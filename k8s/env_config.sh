#!/bin/bash

# 1. 체크 로직: 필수 변수가 이미 로드되어 있는지 확인 [cite: 2026-04-05]
if [ -n "$CLUSTER_NAME" ] && [ -n "$VPC_ID" ]; then
    echo "ℹ️  환경 변수가 이미 로드되어 있습니다. (Cluster: $CLUSTER_NAME)" [cite: 2026-04-05]
else
    echo "🌐 환경 변수를 새로 로드합니다..." [cite: 2026-04-05]

    # [기존 로드 로직 시작]
    export NET_STACK_NAME="nat-stack"
    
    # 1. 리전 입력 받기 (한 번도 안 받았을 때만) [cite: 2026-02-14]
    if [ -z "$INPUT_REGION" ]; then
        read -p "📍 리전을 입력해주세요 (예: ap-northeast-2): " INPUT_REGION
        export INPUT_REGION
    fi

    # ... (리전 입력 로직 이후)
    export AWS_REGION=$INPUT_REGION # 변수 통합 [cite: 2026-04-05]

    # 1번 스택에서 모든 정보 추출 (변수명 일치화) [cite: 2026-04-05]
    export VPC_ID=$(aws cloudformation describe-stacks --stack-name $NET_STACK_NAME --query "Stacks[0].Outputs[?OutputKey=='ExportVpcId'].OutputValue" --output text)
    export SERVICE_NAME=$(aws cloudformation describe-stacks --stack-name $NET_STACK_NAME --query "Stacks[0].Outputs[?OutputKey=='ExportServiceName'].OutputValue" --output text)
    export TEAM_NUMBER=$(aws cloudformation describe-stacks --stack-name $NET_STACK_NAME --query "Stacks[0].Outputs[?OutputKey=='ExportTeamNumber'].OutputValue" --output text)

    # Public Subnets (03번 필수) [cite: 2026-04-05]
    export PUB_SUBNET_A=$(aws cloudformation describe-stacks --stack-name $NET_STACK_NAME --query "Stacks[0].Outputs[?OutputKey=='ExportPublicSubnetA'].OutputValue" --output text)
    export PUB_SUBNET_B=$(aws cloudformation describe-stacks --stack-name $NET_STACK_NAME --query "Stacks[0].Outputs[?OutputKey=='ExportPublicSubnetB'].OutputValue" --output text)

    # App Subnets (03번 필수) [cite: 2026-04-05]
    export APP_SUBNET_1=$(aws cloudformation describe-stacks --stack-name $NET_STACK_NAME --query "Stacks[0].Outputs[?OutputKey=='ExportAppSubnetA'].OutputValue" --output text)
    export APP_SUBNET_2=$(aws cloudformation describe-stacks --stack-name $NET_STACK_NAME --query "Stacks[0].Outputs[?OutputKey=='ExportAppSubnetB'].OutputValue" --output text)

    # DB Subnets (05번 필수) [cite: 2026-04-05]
    export DB_SUBNET_1=$(aws cloudformation describe-stacks --stack-name $NET_STACK_NAME --query "Stacks[0].Outputs[?OutputKey=='ExportDBSubnetA'].OutputValue" --output text)
    export DB_SUBNET_2=$(aws cloudformation describe-stacks --stack-name $NET_STACK_NAME --query "Stacks[0].Outputs[?OutputKey=='ExportDBSubnetB'].OutputValue" --output text)

    # 5. 기타 클러스터 정보 [cite: 2026-04-04]
    export CLUSTER_NAME="${SERVICE_NAME}-team-${TEAM_NUMBER}-cluster"
    export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)

    # 6. 쿠폰 총 수량 입력
    if [ -z "$COUPON_TOTAL" ]; then
        read -p "🎫 쿠폰 총 수량을 입력해주세요 (기본값: 30000): " COUPON_TOTAL
        export COUPON_TOTAL=${COUPON_TOTAL:-30000}
    fi
    # [기존 로드 로직 끝]

    # ✅ 최종 검증: 로드 후에도 값이 없으면 에러 처리 [cite: 2026-04-05]
    if [ -z "$VPC_ID" ] || [ "$VPC_ID" == "None" ]; then
        echo "❌ 에러: 스택($NET_STACK_NAME)에서 정보를 가져오지 못했습니다." [cite: 2026-04-05]
        return 1 2>/dev/null || exit 1
    fi
    echo "✅ 환경 변수 로드 완료!" [cite: 2026-04-05]
    echo "--------------------------------------------------------"
    echo "✅ CloudFormation Stack($NET_STACK_NAME)에서 변수를 자동 로드했습니다."
    echo "🏢 VPC: $VPC_ID"
    echo "🚀 App Subnets: $APP_SUBNET_1, $APP_SUBNET_2"
    echo "💎 DB Subnets: $DB_SUBNET_1, $DB_SUBNET_2"
    echo "--------------------------------------------------------"
fi

