# CI/CD 파이프라인 사용 가이드

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
