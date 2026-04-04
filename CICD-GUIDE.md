# CI/CD 파이프라인 — 구축 + 사용 가이드

---

# Part 1. CI/CD 구축 작업 가이드

> 새 프로젝트에 CI/CD를 세팅할 때 이 순서대로 진행한다.

## 사전 조건

- EKS 클러스터 생성 완료 (kubectl 접근 가능)
- 앱에 Dockerfile이 있어야 함
- GitHub 레포 2개 준비: app 레포 (소스코드), manifests 레포 (K8s YAML)

---

## Step 1. ECR 레포지토리 생성

앱의 Docker 이미지를 저장할 ECR 레포를 만든다.

```bash
aws ecr create-repository --repository-name <앱이름> --region <리전>
```

---

## Step 2. CI 워크플로우 작성

app 레포에 `.github/workflows/ci.yaml` 파일을 생성한다.

```yaml
name: CI - Build and Push to ECR

on:
  push:
    branches: [ main ]

env:
  AWS_REGION: ${{ secrets.AWS_REGION }}
  ECR_REGISTRY: ${{ secrets.AWS_ACCOUNT_ID }}.dkr.ecr.${{ secrets.AWS_REGION }}.amazonaws.com
  ECR_REPOSITORY: ${{ secrets.ECR_REPOSITORY }}
  IMAGE_TAG: ${{ github.sha }}

jobs:
  build-and-push:
    runs-on: ubuntu-latest
    permissions:
      id-token: write    # OIDC 인증에 필요
      contents: read

    steps:
      - uses: actions/checkout@v4

      # AWS 인증 (OIDC — 액세스 키 불필요)
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::${{ secrets.AWS_ACCOUNT_ID }}:role/github-actions-role
          aws-region: ${{ env.AWS_REGION }}

      # ECR 로그인
      - uses: aws-actions/amazon-ecr-login@v2

      # Docker 빌드 + Push
      - name: Build and push
        run: |
          docker build -t $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG .
          docker push $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG
          docker tag $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG $ECR_REGISTRY/$ECR_REPOSITORY:latest
          docker push $ECR_REGISTRY/$ECR_REPOSITORY:latest
          echo "IMAGE=$ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG" >> $GITHUB_ENV

      # manifests 레포 image 태그 자동 업데이트
      - name: Update manifests
        run: |
          git clone https://x-access-token:${{ secrets.MANIFESTS_TOKEN }}@github.com/${{ secrets.MANIFESTS_REPO }}.git manifests
          cd manifests
          sed -i "s|image: .*$ECR_REPOSITORY.*|image: ${{ env.IMAGE }}|g" k8s/deployment.yaml
          git config user.name "github-actions"
          git config user.email "github-actions@github.com"
          git add k8s/deployment.yaml
          git commit -m "chore: update image tag to $IMAGE_TAG [skip ci]"
          git push
```

---

## Step 3. GitHub OIDC Provider 등록 (AWS)

GitHub Actions가 액세스 키 없이 IAM Role로 AWS에 인증하기 위한 설정.

```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
```

> 이미 등록되어 있으면 `EntityAlreadyExists` 에러 → 무시하고 진행

---

## Step 4. GitHub Actions IAM Role 생성

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
          "token.actions.githubusercontent.com:sub": "repo:<GitHub-Org>/<app-repo-name>:*"
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

> **주의**: `repo:<GitHub-Org>/<app-repo-name>:*` 부분을 실제 레포 경로로 변경!
> 이걸 틀리면 `Not authorized to perform sts:AssumeRoleWithWebIdentity` 에러 발생

---

## Step 5. GitHub Secrets 등록

app 레포 → Settings → Secrets and variables → Actions:

| Secret 이름 | 값 | 확인 방법 |
|---|---|---|
| `AWS_ACCOUNT_ID` | AWS 12자리 계정 ID | `aws sts get-caller-identity` |
| `AWS_REGION` | 리전 (예: `eu-central-1`) | |
| `ECR_REPOSITORY` | ECR 레포 이름 (예: `project-app`) | |
| `MANIFESTS_REPO` | manifests 레포 경로 (예: `org/manifests`) | |
| `MANIFESTS_TOKEN` | GitHub PAT (repo 권한) | GitHub → Settings → Developer settings → PAT |

---

## Step 6. K8s 매니페스트 준비 (manifests 레포)

manifests 레포에 `k8s/` 디렉토리를 만들고 배포 파일을 작성한다.

`k8s/deployment.yaml`의 image 필드는 CI가 자동으로 업데이트하므로, 초기값만 세팅:

```yaml
image: <ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/<앱이름>:latest
```

---

## Step 7. ArgoCD 설치 + Application 등록

```bash
# ArgoCD 설치
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 외부 접속 (LoadBalancer)
kubectl patch svc argocd-server -n argocd -p '{"spec":{"type":"LoadBalancer"}}'

# ArgoCD Application 등록
cat > argocd-app.yaml << EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: <앱이름>
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/<org>/manifests.git
    targetRevision: main
    path: k8s
  destination:
    server: https://kubernetes.default.svc
    namespace: <네임스페이스>
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF

kubectl apply -f argocd-app.yaml
```

---

## Step 8. ALB Ingress Controller 설치

앱을 외부에 노출할 Ingress(ALB)를 사용하려면 필요.

```bash
# IAM Policy
curl -o iam_policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.1/docs/install/iam_policy.json
aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam_policy.json

# Service Account
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
eksctl create iamserviceaccount \
  --cluster=<클러스터이름> \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --attach-policy-arn=arn:aws:iam::${ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy \
  --approve --region=<리전>

# Helm 설치
helm repo add eks https://aws.github.io/eks-charts
helm repo update
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=<클러스터이름> \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region=<리전>
```

---

## Step 9. 테스트

```bash
# app 레포에서 아무 변경 push
cd app
echo "# test" >> README.md
git add README.md
git commit -m "test: CI/CD pipeline test"
git push origin main
```

확인 순서:
1. GitHub Actions 탭 → 워크플로우 성공
2. manifests 레포 → deployment.yaml image 태그 변경 확인
3. ArgoCD 대시보드 → Synced + Healthy
4. ALB 주소로 접속 → 앱 정상 동작

---

## 자주 겪는 문제

| 문제 | 원인 | 해결 |
|---|---|---|
| OIDC AssumeRole 실패 | trust policy의 repo 이름 오타 | Step 4에서 `repo:org/app:*` 정확히 확인 |
| OIDC Provider 미등록 | Step 3 누락 | `aws iam list-open-id-connect-providers`로 확인 |
| ECR push 실패 | IAM Role에 ECR 권한 없음 | `AmazonEC2ContainerRegistryPowerUser` 정책 연결 확인 |
| manifests push 실패 | PAT 권한 부족 또는 만료 | GitHub PAT에 `repo` 권한 확인 |
| Ingress ADDRESS 없음 | ALB Controller 미설치 | Step 8 실행 |
| NLB Pending | `aws-load-balancer-type: external` 사용 시 ALB Controller 필요 | annotation 제거하거나 ALB Controller 먼저 설치 |

---
---

# Part 2. CI/CD 사용 가이드 (팀원용)

## 구조 요약

```
app 레포 (소스코드)                    manifests 레포 (배포 정의)
├── main.py                           ├── k8s/
├── Dockerfile                        │   ├── deployment.yaml  ← CI가 image 태그 자동 업데이트
├── .github/workflows/ci.yaml         │   ├── service.yaml
└── ...                               │   └── postgres.yaml
                                      └── argocd-app.yaml
```

- **app 레포**: 소스코드만 관리. 여기에 push하면 CI/CD가 자동 실행
- **manifests 레포**: K8s 배포 파일만 관리. ArgoCD가 이 레포를 감시

---

## 배포 흐름 (자동)

```
개발자가 app 레포 main 브랜치에 push
        ↓
① GitHub Actions 자동 실행
        ↓
② Docker 이미지 빌드 → ECR에 push
        ↓
③ manifests 레포의 deployment.yaml image 태그를 새 커밋 SHA로 업데이트
        ↓
④ ArgoCD가 변경 감지 → EKS 클러스터에 자동 배포 (Rolling Update)
```

**소요 시간**: push 후 약 3~5분이면 새 버전이 배포됩니다.

---

## 개발자가 할 일

### 평소 개발 시

app 레포에서 코드 수정 후 push하면 끝입니다.

```bash
cd app
# 코드 수정
git add .
git commit -m "feat: 기능 추가"
git push origin main
```

push 후 확인:
1. **GitHub → Actions 탭**: 빌드 성공 여부 확인
2. **ArgoCD 대시보드**: Synced + Healthy 확인
3. **ALB 주소로 접속**: 실제 반영 확인

### 배포 상태 확인

```bash
# Pod 상태
kubectl get pods -n project

# 배포 이미지 확인
kubectl get deploy project-app -n project -o jsonpath='{.spec.template.spec.containers[0].image}' && echo

# ArgoCD 상태
kubectl get applications -n argocd
```

---

## K8s 매니페스트 수정 시

DB 설정, 리소스 제한, 환경변수 등 **인프라/배포 설정**을 바꿀 때는 manifests 레포를 수정합니다.

```bash
cd manifests
# k8s/deployment.yaml 또는 k8s/postgres.yaml 수정
git add .
git commit -m "chore: 리소스 제한 변경"
git push origin main
```

ArgoCD가 자동으로 변경을 감지하여 클러스터에 반영합니다.

---

## 롤백

배포 후 문제가 생기면:

### 방법 1: Git 롤백 (권장)

```bash
cd manifests
git revert HEAD
git push origin main
# ArgoCD가 이전 상태로 자동 복구
```

### 방법 2: ArgoCD에서 수동 롤백

ArgoCD 대시보드 → project-app → History → 이전 버전 선택 → Rollback

---

## 주의사항

| 항목 | 설명 |
|---|---|
| **main 브랜치 push = 즉시 배포** | feature 브랜치에서 작업 후 PR로 머지 권장 |
| **kubectl로 직접 수정 금지** | ArgoCD가 Git 상태로 자동 되돌림 (selfHeal) |
| **manifests 레포 직접 수정 시 주의** | deployment.yaml의 image 태그는 CI가 관리하므로 수동 변경 불필요 |
| **Secrets 변경** | GitHub Secrets(app 레포 Settings)에서 관리 |

---

## 접속 정보

| 서비스 | 접속 방법 |
|---|---|
| **App (핫딜 쿠폰)** | `http://<ALB 주소>` (kubectl get ingress -n project) |
| **ArgoCD 대시보드** | `http://<NLB 주소>` (kubectl get svc argocd-server-lb -n argocd) |
| **ArgoCD 로그인** | ID: `admin` / PW: `kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath="{.data.password}" \| base64 -d` |

---

## 트러블슈팅

| 증상 | 확인 | 해결 |
|---|---|---|
| Actions 빌드 실패 | Actions 탭에서 로그 확인 | 코드 에러 수정 후 재push |
| ArgoCD OutOfSync | 대시보드에서 상태 확인 | SYNC 버튼 클릭 |
| ArgoCD Degraded | `kubectl describe pod -n project -l app=project-app` | 이미지/설정 오류 확인 |
| Pod CrashLoopBackOff | `kubectl logs -n project -l app=project-app` | 앱 에러 로그 확인 |
| ImagePullBackOff | 이미지 URL/ECR 권한 확인 | deployment.yaml 이미지 경로 확인 |

---

## 아키텍처 구조

```
                    ┌─────────── CI (GitHub Actions) ───────────┐
                    │                                            │
  [Developer]──push──→[app repo]──trigger──→[Build]──push──→[ECR]
                                               │
                                        image tag update
                                               │
                                               ▼
                                        [manifests repo]
                                               │
                                             watch
                                               │
                    ┌─────────── CD (ArgoCD) ───┤
                    │                           ▼
                    │                    [Auto Deploy]
                    │                           │
  ┌─────────────── AWS (eu-central-1) ─────────┼──────────────────┐
  │                                             │                  │
  │   [Internet]──→[ALB]──→[Worker Nodes]──→[App Pods]            │
  │                              │                                 │
  │                         [DB Pod]──→[EBS Volume]                │
  │                                                                │
  │   [EKS Control Plane]                                         │
  └────────────────────────────────────────────────────────────────┘
```
