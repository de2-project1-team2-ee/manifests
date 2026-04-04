# 핵심 개념 정리

## 1. AWS 로드밸런서 — ALB vs NLB

둘 다 AWS의 로드밸런서이지만 동작 계층과 용도가 다르다.

| | ALB (Application LB) | NLB (Network LB) |
|---|---|---|
| **계층** | L7 (HTTP/HTTPS) | L4 (TCP/UDP) |
| **특징** | 경로 기반 라우팅, HTTP 헬스체크 경로 지정 | 단순 포트 포워딩, 고성능, 저지연 |
| **사용 예** | 웹 앱 트래픽 (사용자 요청) | 관리 도구, DB 접근 등 |
| **생성 방식** | Ingress 리소스 + ALB Controller가 자동 생성 | `type: LoadBalancer` Service로 직접 생성 |

### 이 프로젝트에서의 사용

| 서비스 | 로드밸런서 | 이유 |
|---|---|---|
| **App (핫딜 쿠폰)** | ALB (Ingress) | `/healthz` 경로 기반 헬스체크, HTTP 라우팅 필요 |
| **ArgoCD (대시보드)** | NLB (LoadBalancer) | 관리자만 접속, 단순 포트 포워딩이면 충분 |

### 트래픽 흐름

```
[사용자] → Internet → ALB (L7) → Worker Node → App Pod (:8000)
[관리자] → Internet → NLB (L4) → Worker Node → ArgoCD Pod (:8080)
```

### ALB Ingress Controller란?

K8s의 `Ingress` 리소스를 읽어서 실제 AWS ALB를 자동 생성/관리해주는 컨트롤러.
이게 설치되어 있어야 `service.yaml`의 Ingress 정의가 동작한다.

---

## 2. ArgoCD

**K8s 위에서 동작하는 GitOps CD(Continuous Deployment) 도구.**

Git 레포의 K8s 매니페스트를 감시하다가, 변경이 생기면 클러스터에 자동 반영한다.

### ArgoCD가 하는 일

```
1. Git 레포(manifests)를 주기적으로 polling (기본 3분)
2. Git의 YAML과 클러스터의 실제 상태를 비교
3. 차이가 있으면 자동으로 동기화 (Sync)
```

### 핵심 개념

| 용어 | 의미 |
|---|---|
| **Application** | ArgoCD가 관리하는 배포 단위. "이 Git 레포의 이 경로를 이 클러스터에 배포해라" |
| **Sync** | Git 상태 → 클러스터 상태로 반영하는 동작 |
| **Synced** | Git과 클러스터 상태가 일치 |
| **OutOfSync** | Git과 클러스터 상태가 불일치 (새 커밋이 있거나, 누군가 직접 수정) |
| **Healthy** | 배포된 리소스가 정상 동작 중 |
| **Degraded** | Pod 실패 등 비정상 상태 |
| **Prune** | Git에서 삭제된 리소스를 클러스터에서도 삭제 |
| **Self Heal** | 클러스터를 직접 수정해도 Git 상태로 자동 복구 |

### 이 프로젝트에서의 ArgoCD 설정

```yaml
# argocd-app.yaml
spec:
  source:
    repoURL: https://github.com/.../manifests.git
    path: k8s            # 이 디렉토리의 YAML을 배포
    targetRevision: main  # 이 브랜치를 감시

  destination:
    server: https://kubernetes.default.svc  # 현재 클러스터
    namespace: project                      # 이 네임스페이스에 배포
```

- `k8s/` 디렉토리의 `deployment.yaml`, `service.yaml`, `postgres.yaml`을 감시
- CI가 `deployment.yaml`의 image 태그를 바꾸면 → ArgoCD가 감지 → 자동 배포

### ArgoCD 구성 요소 (EKS 위에서 동작)

| 컴포넌트 | 역할 |
|---|---|
| **argocd-server** | 웹 UI + API 서버 (관리자가 접속하는 대시보드) |
| **argocd-repo-server** | Git 레포를 clone하고 매니페스트를 렌더링 |
| **argocd-application-controller** | Git ↔ 클러스터 상태 비교 + Sync 실행 |

### ArgoCD vs Jenkins/GitHub Actions

| | ArgoCD | Jenkins / GitHub Actions |
|---|---|---|
| **역할** | CD (배포) | CI (빌드/테스트) |
| **방식** | Pull — Git을 감시하다 변경 감지 시 배포 | Push — 파이프라인에서 직접 배포 명령 실행 |
| **클러스터 접근** | 클러스터 안에서 동작 (별도 인증 불필요) | 외부에서 접근 (kubeconfig/credentials 필요) |
| **상태 관리** | Git ↔ 클러스터 지속 비교 + 자동 복구 | 배포 후 끝 (상태 추적 안 함) |

이 프로젝트에서는 **GitHub Actions(CI) + ArgoCD(CD)** 조합으로 역할을 분리한다.

---

## 3. GitOps

**Git을 배포의 단일 진실 소스(Single Source of Truth)로 사용하는 운영 방식.**

핵심 원칙: "클러스터를 직접 수정하지 않고, Git만 수정한다."

### 기존 방식 vs GitOps

| | 기존 방식 | GitOps |
|---|---|---|
| **배포** | 사람이 `kubectl apply` 직접 실행 | Git에 push하면 자동 배포 |
| **현재 상태 확인** | 클러스터에 접속해서 확인 | Git 보면 됨 (Git = 현재 상태) |
| **롤백** | 기억에 의존하거나 수동 복구 | `git revert`하면 끝 |
| **감사 추적** | 누가 뭘 바꿨는지 알기 어려움 | Git 커밋 히스토리에 전부 기록 |

### 이 프로젝트에서의 GitOps 흐름

```
manifests 레포 (Git)    ← "원하는 상태"를 정의하는 곳
       ↓ watch
    ArgoCD              ← Git과 클러스터 상태를 계속 비교
       ↓ sync
  EKS 클러스터           ← 실제 상태를 Git에 맞춰 자동 동기화
```

### 왜 레포를 분리하나? (app vs manifests)

```
app 레포        → 소스코드 + CI (빌드/테스트)
manifests 레포  → K8s YAML (배포 정의) ← ArgoCD가 이것만 감시
```

- 앱 코드 변경과 인프라/배포 변경의 **관심사 분리**
- CI가 manifests 레포의 image 태그만 바꾸면 → ArgoCD가 감지 → 자동 배포
- manifests 레포의 Git 히스토리 = 배포 이력

### ArgoCD 자동 복구 (selfHeal)

누군가 `kubectl`로 클러스터를 직접 수정해도,
ArgoCD가 Git 상태와 다른 것을 감지하고 **자동으로 Git 상태로 되돌린다.**

```yaml
# argocd-app.yaml
syncPolicy:
  automated:
    prune: true      # Git에서 삭제된 리소스는 클러스터에서도 삭제
    selfHeal: true   # 클러스터 상태가 Git과 달라지면 자동 복구
```
