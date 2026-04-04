# manifests

CI/CD 파이프라인 및 K8s 배포 매니페스트 관리 레포.

app 레포에 push하면 자동으로 빌드 → 배포되는 GitOps 기반 파이프라인을 구성한다.

---

## CI/CD 파이프라인

```
[app 레포 push] → [GitHub Actions] → [Docker Build] → [ECR Push]
                                          ↓
                                   image 태그 업데이트
                                          ↓
                                   [manifests 레포]
                                          ↓ watch
                                      [ArgoCD]
                                          ↓ sync
                                    [EKS 클러스터]
```

| 단계 | 도구 | 역할 |
|---|---|---|
| CI | GitHub Actions | 코드 빌드, Docker 이미지 생성, ECR push |
| CD | ArgoCD | manifests 레포 감시, 변경 감지 시 클러스터 자동 배포 |
| 인증 | OIDC + IAM Role | GitHub Actions → AWS 인증 (액세스 키 불필요) |
| 이미지 저장소 | Amazon ECR | Docker 이미지 저장 |
| 오케스트레이션 | Amazon EKS | Kubernetes 클러스터 |
| 트래픽 | ALB Ingress Controller | Ingress 리소스로 ALB 자동 생성 |

---

## 기술 스택

### CI (Continuous Integration)

| 기술 | 용도 |
|---|---|
| **GitHub Actions** | main push 시 자동 트리거되는 CI 파이프라인 |
| **Docker** | 앱을 컨테이너 이미지로 빌드 |
| **Amazon ECR** | 빌드된 이미지를 저장하는 프라이빗 레지스트리 |
| **OIDC** | GitHub → AWS 간 액세스 키 없이 IAM Role 기반 인증 |

### CD (Continuous Deployment)

| 기술 | 용도 |
|---|---|
| **ArgoCD** | Git ↔ 클러스터 상태 비교 + 자동 동기화 (GitOps) |
| **Helm** | ALB Ingress Controller 등 K8s 패키지 설치 |

### 인프라

| 기술 | 용도 |
|---|---|
| **Amazon EKS** | 관리형 Kubernetes 클러스터 |
| **CloudFormation** | VPC/Subnet/NAT/ALB 네트워크 인프라 (IaC) |
| **eksctl** | EKS 클러스터 생성 CLI |
| **ALB Ingress Controller** | K8s Ingress → AWS ALB 자동 생성 |

---

## 핵심 개념

### GitOps

Git을 배포의 단일 진실 소스(Single Source of Truth)로 사용하는 운영 방식.

- 클러스터를 직접 수정하지 않고 **Git만 수정**
- ArgoCD가 Git 상태와 클러스터 상태를 비교하여 **자동 동기화**
- 롤백 = `git revert`

### 레포 분리 (app vs manifests)

| | app 레포 | manifests 레포 |
|---|---|---|
| **내용** | 소스코드 + Dockerfile + CI | K8s YAML + ArgoCD 설정 |
| **역할** | "앱을 어떻게 만들지" | "앱을 어떻게 배포할지" |
| **트리거** | push → CI 실행 | CI가 image 태그 업데이트 → ArgoCD 배포 |

### OIDC 인증

GitHub Actions가 AWS에 접근할 때 **액세스 키 대신 IAM Role**을 사용하는 방식.

```
GitHub Actions → OIDC 토큰 발행 → AWS IAM이 검증 → 임시 자격증명 발급
```

액세스 키를 저장하지 않으므로 키 유출 위험이 없다.

### ArgoCD 자동 복구 (selfHeal)

누군가 `kubectl`로 클러스터를 직접 수정해도 ArgoCD가 Git 상태로 자동 되돌린다.

```yaml
syncPolicy:
  automated:
    prune: true      # Git에서 삭제된 리소스 → 클러스터에서도 삭제
    selfHeal: true   # 클러스터 상태 ≠ Git → 자동 복구
```

---

## 디렉토리 구조

```
├── k8s/                          # K8s 배포 매니페스트 (ArgoCD 감시 대상)
│   ├── deployment.yaml           #   앱 Deployment (image 태그는 CI가 자동 관리)
│   ├── service.yaml              #   Service + Ingress (ALB)
│   └── postgres.yaml             #   PostgreSQL (DB + PVC + Secret)
│
├── infra/                        # 인프라 구축용
│   ├── project-network.yaml      #   CloudFormation: VPC/Subnet/NAT/ALB
│   ├── project-eks-cluster.yaml  #   eksctl: EKS 클러스터 설정
│   ├── eks-management.yaml       #   CloudFormation: 관리 서버 (EC2)
│   └── create-eks-cluster.sh     #   EKS 생성 자동화 스크립트
│
├── cicd/                         # CI/CD 관련
│   ├── argocd-app.yaml           #   ArgoCD Application 정의
│   ├── argocd-install.yaml       #   ArgoCD 서버 외부 노출 (NLB)
│   └── init-deployment.sh        #   deployment.yaml 이미지 URL 자동 세팅
│
├── docs/                         # 다이어그램
│   ├── architecture.svg          #   전체 아키텍처 구조도
│   ├── network-architecture.svg  #   네트워크 아키텍처
│   └── cicd-pipeline.svg         #   CI/CD 흐름도
│
├── README.md
├── CICD-GUIDE.md                 # CI/CD 구축 + 사용 가이드
├── CICD-SETUP.md                 # CI/CD 상세 설정 가이드
├── CONCEPTS.md                   # 핵심 개념 정리
└── PROJECT-SETUP-GUIDE.md        # 전체 작업 순서 가이드
```

---

## 관련 문서

| 문서 | 내용 |
|---|---|
| [CICD-GUIDE.md](CICD-GUIDE.md) | CI/CD 구축 절차 (Step 1~9) + 팀원 사용법 |
| [CICD-SETUP.md](CICD-SETUP.md) | OIDC, IAM Role, GitHub Secrets 등 상세 설정 |
| [CONCEPTS.md](CONCEPTS.md) | ALB/NLB, ArgoCD, Ingress, GitOps 개념 정리 |
| [PROJECT-SETUP-GUIDE.md](PROJECT-SETUP-GUIDE.md) | 인프라 구축 전체 작업 순서 |
