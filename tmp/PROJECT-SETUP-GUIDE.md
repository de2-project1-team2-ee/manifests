# 컨테이너 인프라 프로젝트 — 전체 작업 순서

## 프로젝트 정보

| 항목 | 값 |
|---|---|
| 리전 | eu-central-1 (프랑크푸르트) |
| GitHub 조직 | de2-project1-team2-ee |
| app 레포 | de2-project1-team2-ee/app |
| manifests 레포 | de2-project1-team2-ee/manifests |
| ECR 레포 | project-app |
| EKS 클러스터 | project-eks |
| K8s 네임스페이스 | project |

---

## 1단계: 네트워크 인프라 (CloudFormation)

### 파일: infra/project-network.yaml

VPC, 서브넷, IGW, NAT GW, ALB, 보안그룹을 생성합니다.

```bash
# AWS 콘솔 → CloudFormation → 스택 생성
# 스택 이름: network-project
# 템플릿: infra/project-network.yaml 업로드
# 파라미터 없음
```

### Outputs 확인 (4단계 스크립트가 자동 조회)

| Output | 용도 |
|---|---|
| VpcId | EKS 클러스터 VPC |
| PublicSubnet1Id | EKS Public Subnet (AZ-a) |
| PublicSubnet2Id | EKS Public Subnet (AZ-b) |
| PrivateSubnet1Id | EKS 워커노드 (AZ-a) |
| PrivateSubnet2Id | EKS 워커노드 (AZ-b) |

---

## 2단계: 관리 서버 (CloudFormation)

### 파일: infra/eks-management.yaml

eksctl, kubectl, helm, docker, git이 자동 설치된 EC2를 생성합니다.

```bash
# AWS 콘솔 → CloudFormation → 스택 생성
# 스택 이름: eks-management
# 템플릿: infra/eks-management.yaml 업로드
# 파라미터:
#   NetworkStackName: network-project
#   KeyName: <프랑크푸르트 리전 키페어>
#   InstanceType: t3.micro
# ※ IAM 리소스 생성 체크 필수
```

### SSH 접속

```bash
ssh -i <키페어>.pem ec2-user@<Public IP>

# 도구 설치 확인
cat setup-log.txt

# 리전 설정
aws configure set region eu-central-1
```

---

## 3단계: EKS 클러스터 생성

### 파일: infra/project-eks-cluster.yaml + infra/create-eks-cluster.sh

스크립트가 network-project 스택에서 VPC/Subnet ID를 자동 조회하여 클러스터를 생성합니다.

```bash
# 관리 서버에서 manifests 레포 클론
git clone https://github.com/de2-project1-team2-ee/manifests.git
cd manifests

# 자동화 스크립트로 EKS 생성 (약 15~20분)
cd infra
bash create-eks-cluster.sh

# 확인
kubectl get nodes
# 2개 노드 Ready 면 성공
```

---

## 4단계: ArgoCD 설치

```bash
# ArgoCD 설치
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 외부 접속용 NLB 생성
cd ~/manifests
kubectl apply -f cicd/argocd-install.yaml

# Pod 준비 대기
kubectl get pods -n argocd -w
# 전부 Running 되면 완료

# 접속 정보 확인
kubectl get svc argocd-server-lb -n argocd    # EXTERNAL-IP 확인
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath="{.data.password}" | base64 -d && echo    # 비밀번호 (ID: admin)
```

브라우저에서 `http://<EXTERNAL-IP>` 로 접속하여 로그인 확인.

---

## 5단계: ALB Ingress Controller 설치

```bash
# IAM Policy 생성
curl -o iam_policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.1/docs/install/iam_policy.json
aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam_policy.json

# Service Account 생성 (IRSA)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
eksctl create iamserviceaccount \
  --cluster=project-eks \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --attach-policy-arn=arn:aws:iam::${ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy \
  --approve --region=eu-central-1

# Helm으로 Controller 설치
helm repo add eks https://aws.github.io/eks-charts
helm repo update
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=project-eks \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region=eu-central-1

# 확인
kubectl get pods -n kube-system | grep load-balancer
# Running 이면 성공
```

---

## 6단계: ECR 레포 생성 + 이미지 빌드

```bash
# ECR 레포 생성
aws ecr create-repository --repository-name project-app --region eu-central-1

# ECR 로그인
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws ecr get-login-password --region eu-central-1 | \
  docker login --username AWS --password-stdin ${ACCOUNT_ID}.dkr.ecr.eu-central-1.amazonaws.com

# app 레포 클론 + 빌드 + push
git clone https://github.com/de2-project1-team2-ee/app.git
cd ~/app
docker build -t project-app .
docker tag project-app:latest ${ACCOUNT_ID}.dkr.ecr.eu-central-1.amazonaws.com/project-app:latest
docker push ${ACCOUNT_ID}.dkr.ecr.eu-central-1.amazonaws.com/project-app:latest
```

---

## 7단계: 앱 배포 (ArgoCD)

```bash
cd ~/manifests

# deployment.yaml에 ECR 이미지 URL 자동 세팅
bash cicd/init-deployment.sh

# 확인
grep "image:" k8s/deployment.yaml

# Git push (PAT 필요)
git add k8s/deployment.yaml
git commit -m "chore: set ECR image URL"
git push

# ArgoCD Application 등록
kubectl apply -f cicd/argocd-app.yaml

# 확인
kubectl get applications -n argocd
# Synced + Healthy 면 성공

# 앱 접속 확인
kubectl get ingress -n project
# ADDRESS의 ALB 주소로 브라우저 접속
```

---

## 8단계: CI/CD 파이프라인 설정 (OIDC)

### 8-1. GitHub OIDC Provider 등록

```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
```

### 8-2. GitHub Actions IAM Role 생성

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

cat > trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:de2-project1-team2-ee/app:*"
        }
      }
    }
  ]
}
EOF

aws iam create-role \
  --role-name github-actions-role \
  --assume-role-policy-document file://trust-policy.json

aws iam attach-role-policy \
  --role-name github-actions-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser
```

> **주의**: trust policy의 `repo:` 뒤에 org/repo 이름이 정확해야 함. 틀리면 OIDC 인증 실패.

### 8-3. GitHub Secrets 등록

app 레포 → Settings → Secrets and variables → Actions:

| Secret | 값 | 확인 방법 |
|---|---|---|
| AWS_ACCOUNT_ID | 12자리 계정 ID | `aws sts get-caller-identity` |
| AWS_REGION | eu-central-1 | |
| ECR_REPOSITORY | project-app | |
| MANIFESTS_REPO | de2-project1-team2-ee/manifests | |
| MANIFESTS_TOKEN | GitHub PAT (repo 권한) | GitHub → Settings → Developer settings → PAT |

### 8-4. CI/CD 테스트

```bash
cd ~/app
echo "# CI/CD test" >> README.md
git add README.md
git commit -m "test: CI/CD pipeline test"
git push origin main
```

확인 순서:
1. GitHub → Actions 탭 → 워크플로우 성공
2. manifests 레포 → deployment.yaml image 태그 변경 확인
3. ArgoCD 대시보드 → Synced + Healthy
4. ALB 주소로 접속 → 앱 정상 동작

---

## 리소스 삭제 순서 (비용 절약)

역순으로 삭제합니다:

```bash
# 1. ArgoCD Application 삭제
kubectl delete -f cicd/argocd-app.yaml

# 2. ArgoCD 삭제
kubectl delete -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 3. ALB Controller 삭제
helm uninstall aws-load-balancer-controller -n kube-system

# 4. EKS 클러스터 삭제 (약 10분)
eksctl delete cluster --name project-eks --region eu-central-1

# 5. CloudFormation 스택 삭제 (AWS 콘솔)
# eks-management 스택 삭제 → network-project 스택 삭제

# 6. ECR 이미지 삭제
aws ecr delete-repository --repository-name project-app --region eu-central-1 --force

# 7. IAM 리소스 삭제
aws iam detach-role-policy --role-name github-actions-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser
aws iam delete-role --role-name github-actions-role
```

---

## 파일 목록

### app 레포

```
├── .github/workflows/ci.yaml    # GitHub Actions CI
├── .gitignore
├── .env                          # 로컬 환경변수
├── main.py                       # FastAPI 앱
├── database.py                   # DB 커넥션 풀
├── config.py                     # 환경변수 설정
├── Dockerfile
├── requirements.txt
├── docker-compose.yaml           # 로컬 실행용
├── locustfile.py                 # 부하 테스트
├── README.md
├── templates/index.html          # 쿠폰 페이지
└── static/style.css
```

### manifests 레포

```
├── k8s/                          # K8s 배포 매니페스트 (ArgoCD 감시 대상)
│   ├── deployment.yaml
│   ├── service.yaml
│   └── postgres.yaml
├── infra/                        # 인프라 구축용
│   ├── project-network.yaml
│   ├── project-eks-cluster.yaml
│   ├── eks-management.yaml
│   └── create-eks-cluster.sh
├── cicd/                         # CI/CD 관련
│   ├── argocd-app.yaml
│   ├── argocd-install.yaml
│   └── init-deployment.sh
├── docs/                         # 다이어그램
│   ├── architecture.svg
│   ├── network-architecture.svg
│   └── cicd-pipeline.svg
├── README.md
├── CICD-GUIDE.md
├── CICD-SETUP.md
├── CONCEPTS.md
└── PROJECT-SETUP-GUIDE.md
```
