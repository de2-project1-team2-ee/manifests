# CI/CD 파이프라인 설정 가이드

## 개요

GitHub Actions(CI) + ArgoCD(CD)로 구성된 GitOps 파이프라인입니다.

```
코드 push (app 레포) → GitHub Actions → Docker 빌드 → ECR push
→ manifests 레포 image 태그 자동 업데이트 → ArgoCD 감지 → EKS 자동 배포
```

## 사전 준비

### 1. AWS CLI 설정 (EC2 관리 서버)

```bash
aws configure
# AWS Access Key ID: <액세스 키>
# AWS Secret Access Key: <시크릿 키>
# Default region name: eu-central-1
# Default output format: json
```

### 2. ECR 레포지토리 생성

```bash
aws ecr create-repository --repository-name project-app --region eu-central-1
```

### 3. GitHub OIDC Provider 등록

GitHub Actions가 액세스 키 없이 IAM Role로 AWS에 인증하기 위한 설정입니다.

```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
```

### 4. GitHub Actions IAM Role 생성

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

### 5. GitHub Secrets 등록

app 레포 → Settings → Secrets and variables → Actions에서 등록:

| Secret 이름 | 값 | 설명 |
|---|---|---|
| AWS_ACCOUNT_ID | `aws sts get-caller-identity`로 확인 | AWS 계정 ID |
| AWS_REGION | eu-central-1 | 리전 |
| ECR_REPOSITORY | project-app | ECR 레포 이름 |
| MANIFESTS_REPO | <GitHub-Org>/manifests | manifests 레포 경로 |
| MANIFESTS_TOKEN | ghp_xxxxx | GitHub PAT (repo 권한) |

### 6. GitHub PAT 발급 방법

1. GitHub → 우측 상단 프로필 → Settings
2. Developer settings → Personal access tokens → Tokens (classic)
3. Generate new token → `repo` 권한 체크
4. 생성된 토큰을 MANIFESTS_TOKEN에 등록

## ArgoCD 설치

### 1. ArgoCD 설치

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

### 2. ArgoCD 서버 외부 노출

```bash
kubectl patch svc argocd-server -n argocd -p '{"spec":{"type":"LoadBalancer"}}'
```

### 3. 접속 정보 확인

```bash
# 외부 주소
kubectl get svc argocd-server -n argocd

# 초기 비밀번호 (ID: admin)
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

### 4. manifests 레포 인증 등록

Private 레포인 경우 ArgoCD가 접근할 수 있도록 인증 정보를 등록합니다.

```bash
kubectl create secret generic argocd-repo-manifests \
  -n argocd \
  --from-literal=url=https://github.com/de2-project1-team2-ee/manifests.git \
  --from-literal=username=<GitHub아이디> \
  --from-literal=password=<GitHub PAT> \
  -l argocd.argoproj.io/secret-type=repository
```

### 5. ArgoCD Application 등록

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
    repoURL: https://github.com/de2-project1-team2-ee/manifests.git
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

### 6. 상태 확인

```bash
kubectl get applications -n argocd
# Synced + Healthy 면 성공
```

## ALB Ingress Controller 설치

### 1. IAM Policy 생성

```bash
curl -o iam_policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.1/docs/install/iam_policy.json

aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam_policy.json
```

### 2. Service Account 생성

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

### 3. Helm으로 Controller 설치

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

## ECR 이미지 수동 빌드 + Push

CI 없이 수동으로 이미지를 올릴 때 사용합니다.

```bash
# ECR 로그인
aws ecr get-login-password --region eu-central-1 | docker login --username AWS --password-stdin $(aws sts get-caller-identity --query Account --output text).dkr.ecr.eu-central-1.amazonaws.com

# 빌드 + push
cd app
docker build -t project-app .
docker tag project-app:latest $(aws sts get-caller-identity --query Account --output text).dkr.ecr.eu-central-1.amazonaws.com/project-app:latest
docker push $(aws sts get-caller-identity --query Account --output text).dkr.ecr.eu-central-1.amazonaws.com/project-app:latest
```

## CI/CD 테스트 방법

```bash
# 1. app 레포에서 코드 수정 후 push
cd app
git add .
git commit -m "test: CI/CD pipeline test"
git push origin main

# 2. 확인 순서
# GitHub → Actions 탭 → 워크플로우 실행 확인
# manifests 레포 → deployment.yaml image 태그 변경 확인
# kubectl get applications -n argocd → Synced 확인
# kubectl get pods -n project -w → Rolling Update 확인
```

## 트러블슈팅

| 증상 | 원인 | 해결 |
|---|---|---|
| OIDC AssumeRole 실패 | OIDC Provider 미등록 또는 Trust Policy 오류 | 3번, 4번 다시 실행 |
| ArgoCD Sync Unknown | manifests 레포 접근 불가 | 레포 인증 Secret 등록 |
| ArgoCD Progressing | Ingress ADDRESS 없음 | ALB Controller 설치 또는 Ingress 삭제 |
| InvalidImageName | deployment.yaml에 AWS_ACCOUNT_ID 미치환 | sed로 실제 계정 ID 치환 |
| ErrImagePull | 리전 불일치 | deployment.yaml 리전 확인 (eu-central-1) |

## 레포 구조

```
app 레포 (소스코드 + CI)          manifests 레포 (배포 전용)
├── main.py                      └── k8s/
├── database.py                      ├── deployment.yaml ← CI가 image 태그 자동 업데이트
├── config.py                        ├── service.yaml
├── Dockerfile                       └── postgres.yaml
├── .github/workflows/ci.yaml
└── ...
```
