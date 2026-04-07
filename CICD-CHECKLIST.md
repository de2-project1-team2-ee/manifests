# CI/CD 새 프로젝트 적용 체크리스트

> 새 프로젝트에 CI/CD를 적용할 때 이 체크리스트를 따라 진행한다.
> `<앱이름>`, `<org>`, `<리전>` 등은 실제 값으로 치환할 것.

---

## 1. AWS 사전 준비

### 1-1. ECR 레포지토리 생성

```bash
aws ecr create-repository --repository-name <앱이름> --region <리전>
```

### 1-2. GitHub OIDC Provider 등록 (AWS 계정당 1회)

```bash
# 이미 등록되어 있으면 EntityAlreadyExists 에러 → 스킵
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
```

확인:
```bash
aws iam list-open-id-connect-providers
```

### 1-3. GitHub Actions IAM Role 생성

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
          "token.actions.githubusercontent.com:sub": "repo:<org>/<app-repo>:*"
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

> **주의**: `repo:<org>/<app-repo>:*` 를 실제 레포 경로로 변경!
> 이미 Role이 있으면 trust policy에 새 레포를 추가하면 됨.

---

## 2. App 레포 설정

### 2-1. CI Workflow 복사

App 레포에 `.github/workflows/ci.yaml` 생성 (아래 내용 그대로 사용, 수정 불필요):

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
      id-token: write
      contents: read

    steps:
      - uses: actions/checkout@v4

      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::${{ secrets.AWS_ACCOUNT_ID }}:role/github-actions-role
          aws-region: ${{ env.AWS_REGION }}

      - uses: aws-actions/amazon-ecr-login@v2

      - name: Build and push
        run: |
          docker build -t $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG .
          docker push $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG
          docker tag $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG $ECR_REGISTRY/$ECR_REPOSITORY:latest
          docker push $ECR_REGISTRY/$ECR_REPOSITORY:latest
          echo "IMAGE=$ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG" >> $GITHUB_ENV

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

### 2-2. GitHub Secrets 등록

App 레포 → Settings → Secrets and variables → Actions:

| Secret 이름 | 값 예시 | 확인 방법 |
|---|---|---|
| `AWS_ACCOUNT_ID` | `486053612615` | `aws sts get-caller-identity` |
| `AWS_REGION` | `eu-central-1` | - |
| `ECR_REPOSITORY` | `<앱이름>` | 1-1에서 생성한 이름 |
| `MANIFESTS_REPO` | `<org>/<manifests-repo>` | GitHub 레포 경로 |
| `MANIFESTS_TOKEN` | `ghp_xxxxx` | GitHub PAT (repo 권한) |

> **PAT 발급**: GitHub → Settings → Developer settings → Personal access tokens → Tokens (classic) → `repo` 권한 체크

---

## 3. Manifests 레포 설정

### 3-1. deployment.yaml

아래에서 `<앱이름>`, `<네임스페이스>`, 환경변수, 포트를 프로젝트에 맞게 수정:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: <앱이름>
  namespace: <네임스페이스>
  labels:
    app: <앱이름>
spec:
  replicas: 2
  selector:
    matchLabels:
      app: <앱이름>
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app: <앱이름>
    spec:
      containers:
        - name: <앱이름>
          image: <ACCOUNT_ID>.dkr.ecr.<리전>.amazonaws.com/<앱이름>:latest
          ports:
            - containerPort: <앱포트>
          env:
            # 앱에 맞는 환경변수 작성
            []
          resources:
            requests:
              cpu: "100m"
              memory: "128Mi"
            limits:
              cpu: "500m"
              memory: "256Mi"
          readinessProbe:
            httpGet:
              path: <헬스체크경로>
              port: <앱포트>
            initialDelaySeconds: 5
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: <헬스체크경로>
              port: <앱포트>
            initialDelaySeconds: 10
            periodSeconds: 10
```

### 3-2. service.yaml

```yaml
apiVersion: v1
kind: Service
metadata:
  name: <앱이름>-svc
  namespace: <네임스페이스>
  labels:
    app: <앱이름>
spec:
  type: ClusterIP
  selector:
    app: <앱이름>
  ports:
    - name: http
      port: 80
      targetPort: <앱포트>
      protocol: TCP
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: <앱이름>-ingress
  namespace: <네임스페이스>
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/healthcheck-path: <헬스체크경로>
spec:
  ingressClassName: alb
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: <앱이름>-svc
                port:
                  number: 80
```

### 3-3. postgres.yaml (DB 필요 시)

기존 [postgres.yaml](k8s/postgres.yaml) 복사 후 `namespace`만 변경.
DB명, 유저, 비밀번호는 프로젝트에 맞게 수정.

---

## 4. ArgoCD Application 등록

```bash
cat > argocd-app.yaml << 'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: <앱이름>
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/<org>/<manifests-repo>.git
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

> Private 레포인 경우 ArgoCD에 인증 등록 필요:
> ```bash
> kubectl create secret generic argocd-repo-<앱이름> \
>   -n argocd \
>   --from-literal=url=https://github.com/<org>/<manifests-repo>.git \
>   --from-literal=username=<GitHub아이디> \
>   --from-literal=password=<GitHub PAT> \
>   -l argocd.argoproj.io/secret-type=repository
> ```

---

## 5. 테스트

```bash
# app 레포에서 아무 변경 push
cd <app-repo>
echo "# test" >> README.md
git add README.md
git commit -m "test: CI/CD pipeline test"
git push origin main
```

확인 순서:

- [ ] GitHub Actions 탭 → 워크플로우 성공
- [ ] manifests 레포 → `deployment.yaml` image 태그 변경됨
- [ ] ArgoCD 대시보드 → Synced + Healthy
- [ ] ALB 주소로 접속 → 앱 정상 동작

```bash
# 상태 확인 명령어
kubectl get pods -n <네임스페이스>
kubectl get deploy <앱이름> -n <네임스페이스> -o jsonpath='{.spec.template.spec.containers[0].image}' && echo
kubectl get ingress -n <네임스페이스>
kubectl get applications -n argocd
```

---

## 트러블슈팅

| 증상 | 원인 | 해결 |
|---|---|---|
| OIDC AssumeRole 실패 | trust policy의 repo 이름 오타 | `repo:<org>/<app-repo>:*` 확인 |
| ECR push 실패 | IAM Role에 ECR 권한 없음 | `AmazonEC2ContainerRegistryPowerUser` 정책 확인 |
| manifests push 실패 | PAT 권한 부족 또는 만료 | GitHub PAT에 `repo` 권한 확인 |
| ArgoCD Sync Unknown | manifests 레포 접근 불가 | ArgoCD 레포 인증 Secret 등록 |
| Ingress ADDRESS 없음 | ALB Controller 미설치 | ALB Ingress Controller 설치 필요 |
| ImagePullBackOff | 이미지 URL/리전 불일치 | deployment.yaml 이미지 경로 확인 |
| Pod CrashLoopBackOff | 앱 자체 에러 | `kubectl logs -n <네임스페이스> -l app=<앱이름>` |

---

## 변경 포인트 요약

새 프로젝트에서 바꿔야 하는 값을 한눈에 정리:

| 치환 대상 | 설명 | 사용 위치 |
|---|---|---|
| `<앱이름>` | ECR 레포명, K8s 리소스명, ArgoCD 앱명 | 전체 |
| `<네임스페이스>` | K8s 네임스페이스 | deployment, service, argocd-app |
| `<org>/<app-repo>` | App 소스코드 레포 | IAM trust policy |
| `<org>/<manifests-repo>` | Manifests 레포 | argocd-app, GitHub Secrets |
| `<리전>` | AWS 리전 | GitHub Secrets |
| `<ACCOUNT_ID>` | AWS 계정 ID | GitHub Secrets, deployment 초기값 |
| `<앱포트>` | 앱 컨테이너 포트 | deployment, service |
| `<헬스체크경로>` | 헬스체크 엔드포인트 | deployment, service ingress |
