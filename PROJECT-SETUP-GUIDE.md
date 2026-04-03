# 컨테이너 인프라 프로젝트 — 전체 작업 순서

## 프로젝트 정보

| 항목 | 값 |
|---|---|
| 리전 | eu-central-1 (프랑크푸르트) |
| GitHub 조직 | de2-project1-team2 |
| app 레포 | de2-project1-team2/app |
| manifests 레포 | de2-project1-team2/manifests |
| ECR 레포 | project-app |
| EKS 클러스터 | project-eks |
| K8s 네임스페이스 | project |

---

## 1단계: 네트워크 인프라 (CloudFormation)

### 파일: project-network.yaml

VPC, 서브넷, IGW, NAT GW, ALB, 보안그룹을 생성합니다.
ASG(웹서버 EC2)는 제거한 버전을 사용합니다.

```bash
# AWS 콘솔 → CloudFormation → 스택 생성
# 스택 이름: network-project
# 템플릿: project-network.yaml 업로드
# 파라미터 없음 (ASG 제거 버전)
```

### Outputs 확인 (2단계에서 사용)

| Output | 용도 |
|---|---|
| VpcId | EKS 클러스터 설정 |
| PublicSubnet1Id | EKS + 관리 서버 |
| PublicSubnet2Id | EKS |
| PrivateSubnet1Id | EKS 워커노드 |
| PrivateSubnet2Id | EKS 워커노드 |

---

## 2단계: 관리 서버 (CloudFormation)

### 파일: eks-management.yaml

eksctl, kubectl, helm, docker, git이 자동 설치된 EC2를 생성합니다.

```bash
# AWS 콘솔 → CloudFormation → 스택 생성
# 스택 이름: eks-management
# 템플릿: eks-management.yaml 업로드
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
```

---

## 3단계: ECR 레포 생성

EC2에서 실행:

```bash
aws ecr create-repository --repository-name project-app --region eu-central-1
```

---

## 4단계: EKS 클러스터 생성

### 파일: project-eks-cluster.yaml

Outputs 값으로 VPC/서브넷 ID를 채운 버전을 사용합니다.
리전은 eu-central-1, AZ는 eu-central-1a/b 입니다.

```bash
# project-eks-cluster.yaml을 EC2로 복사
scp -i <키페어>.pem project-eks-cluster.yaml ec2-user@<Public IP>:/home/ec2-user/

# EC2에서 클러스터 생성 (약 15분)
eksctl create cluster -f project-eks-cluster.yaml

# 확인
kubectl get nodes
```

---

## 5단계: 앱 이미지 빌드 + ECR Push

EC2에서 실행:

```bash
# ECR 로그인
aws ecr get-login-password --region eu-central-1 | docker login --username AWS --password-stdin $(aws sts get-caller-identity --query Account --output text).dkr.ecr.eu-central-1.amazonaws.com

# app 레포 클론
git clone https://github.com/de2-project1-team2/app.git
cd app

# 빌드 + push
docker build -t project-app .
docker tag project-app:latest $(aws sts get-caller-identity --query Account --output text).dkr.ecr.eu-central-1.amazonaws.com/project-app:latest
docker push $(aws sts get-caller-identity --query Account --output text).dkr.ecr.eu-central-1.amazonaws.com/project-app:latest
```

---

## 6단계: K8s 배포

EC2에서 실행:

```bash
# 네임스페이스 생성
kubectl create namespace project

# deployment.yaml의 이미지 주소 치환
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
sed -i "s|AWS_ACCOUNT_ID|$ACCOUNT_ID|" k8s/deployment.yaml
sed -i "s|ap-northeast-2|eu-central-1|" k8s/deployment.yaml

# DB 먼저 배포
kubectl apply -f k8s/postgres.yaml

# 앱 배포
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml

# 확인
kubectl get pods -n project
# 3개 모두 Running 이면 성공
```

---

## 7단계: CI 파이프라인 (GitHub Actions)

### 7-1. GitHub OIDC Provider 등록

EC2에서 실행:

```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
```

※ thumbprint가 안 맞으면 최신 값으로 업데이트:

```bash
# 최신 thumbprint 확인
echo | openssl s_client -servername token.actions.githubusercontent.com -connect token.actions.githubusercontent.com:443 2>/dev/null | openssl x509 -fingerprint -noout -sha1 | sed 's/://g' | cut -d= -f2 | tr '[:upper:]' '[:lower:]'

# 업데이트
aws iam update-open-id-connect-provider-thumbprint \
  --open-id-connect-provider-arn arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com \
  --thumbprint-list <위에서_나온_값>
```

### 7-2. GitHub Actions IAM Role 생성

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
          "token.actions.githubusercontent.com:sub": "repo:de2-project1-team2/app:*"
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

### 7-3. GitHub Secrets 등록

app 레포 → Settings → Secrets and variables → Actions:

| Secret | 값 |
|---|---|
| AWS_ACCOUNT_ID | <계정 ID> |
| AWS_REGION | eu-central-1 |
| ECR_REPOSITORY | project-app |
| MANIFESTS_REPO | de2-project1-team2/manifests |
| MANIFESTS_TOKEN | <GitHub PAT> |

### 7-4. CI workflow 파일

app 레포에 `.github/workflows/ci.yaml`이 있어야 합니다.
main 브랜치 push 시 자동 실행됩니다.

---

## 8단계: CD 파이프라인 (ArgoCD)

### 8-1. ArgoCD 설치

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

### 8-2. 외부 노출

```bash
kubectl patch svc argocd-server -n argocd -p '{"spec":{"type":"LoadBalancer"}}'
```

### 8-3. 접속 정보

```bash
# 주소 확인
kubectl get svc argocd-server -n argocd

# 비밀번호 확인 (ID: admin)
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

### 8-4. manifests 레포 인증 등록

```bash
kubectl create secret generic argocd-repo-manifests \
  -n argocd \
  --from-literal=url=https://github.com/de2-project1-team2/manifests.git \
  --from-literal=username=<GitHub아이디> \
  --from-literal=password=<GitHub PAT> \
  -l argocd.argoproj.io/secret-type=repository
```

### 8-5. ArgoCD Application 등록

```bash
cat > argocd-app.yaml << 'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: project-app
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/de2-project1-team2/manifests.git
    targetRevision: main
    path: k8s
  destination:
    server: https://kubernetes.default.svc
    namespace: project
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF

kubectl apply -f argocd-app.yaml
```

### 8-6. 확인

```bash
kubectl get applications -n argocd
# Synced + Healthy 면 성공
```

---

## 9단계: ALB Ingress Controller

### 9-1. IAM Policy

```bash
curl -o iam_policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.1/docs/install/iam_policy.json

aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam_policy.json
```

### 9-2. Service Account

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

eksctl create iamserviceaccount \
  --cluster=project-eks \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --attach-policy-arn=arn:aws:iam::${ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy \
  --approve \
  --region=eu-central-1
```

### 9-3. Helm 설치

```bash
helm repo add eks https://aws.github.io/eks-charts
helm repo update

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=project-eks \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region=eu-central-1
```

### 9-4. 확인

```bash
kubectl get deployment -n kube-system aws-load-balancer-controller
kubectl get ingress -n project
# ADDRESS에 ALB 주소가 나오면 성공
```

---

## 리소스 삭제 순서 (비용 절약)

역순으로 삭제합니다:

```bash
# 1. K8s 리소스 삭제
kubectl delete -f k8s/service.yaml
kubectl delete -f k8s/deployment.yaml
kubectl delete -f k8s/postgres.yaml

# 2. ArgoCD 삭제
kubectl delete -f argocd-app.yaml
kubectl delete -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 3. ALB Controller 삭제
helm uninstall aws-load-balancer-controller -n kube-system

# 4. EKS 클러스터 삭제 (약 10분)
eksctl delete cluster --name project-eks --region eu-central-1

# 5. CloudFormation 스택 삭제 (AWS 콘솔)
# eks-management 스택 삭제
# network-project 스택 삭제

# 6. ECR 이미지 삭제
aws ecr delete-repository --repository-name project-app --region eu-central-1 --force

# 7. IAM 리소스 삭제
aws iam detach-role-policy --role-name github-actions-role --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser
aws iam delete-role --role-name github-actions-role
```

---

## 미해결 이슈

1. **GitHub Actions OIDC 인증 실패** — thumbprint 업데이트 필요. 다음 작업 시 최신 thumbprint로 재등록
2. **모니터링 미설치** — Prometheus + Grafana (다음 작업)
3. **부하 테스트 미실행** — Locust로 500명 동시 접속 테스트 (다음 작업)

---

## 파일 목록

### app 레포

```
├── .github/workflows/ci.yaml  # GitHub Actions CI
├── .gitignore
├── .env.example
├── main.py                     # FastAPI 앱
├── database.py                 # DB 커넥션 풀
├── config.py                   # 환경변수 설정
├── Dockerfile
├── requirements.txt
├── docker-compose.yaml         # 로컬 실행용
├── locustfile.py               # 부하 테스트
├── README.md
├── templates/index.html        # 쿠폰 페이지
├── static/style.css
└── k8s/                        # 참고용 (실제 배포는 manifests 레포)
    ├── deployment.yaml
    ├── service.yaml
    └── postgres.yaml
```

### manifests 레포

```
├── CICD-SETUP.md               # CI/CD 설정 가이드
└── k8s/
    ├── deployment.yaml          # ← CI가 image 태그 자동 업데이트
    ├── service.yaml
    └── postgres.yaml
```

### 인프라 파일 (별도 보관)

```
├── project-network.yaml         # CloudFormation 네트워크
├── project-eks-cluster.yaml     # eksctl EKS 클러스터
├── eks-management.yaml          # CloudFormation 관리 서버
├── network-architecture.svg     # 아키텍처 다이어그램
└── cicd-pipeline.svg            # CI/CD 흐름도
```
