# Kubernetes Installer (Kubeadm + CRI-O + Cilium)

Ubuntu/Debian 환경에서 **단 한 번의 스크립트 실행**으로 프로덕션 수준의 Kubernetes 환경을 구축할 수 있습니다.
최신 안정 버전의 **Kubernetes**, **CRI-O**, **Cilium**을 자동으로 설치 및 구성하며, 운영 환경에 필수적인 커널 설정과 보안 조치가 포함되어 있습니다.

---

## 🛠️ 주요 기능

- **자동화된 설치**: 필수 의존성 설치 → 시스템 설정 영구화(Swap off, Sysctl, Modules) → Repo 등록 → 패키지 설치 → 클러스터 초기화 → Helm & Cilium 설치
- **안정성 강화**:
  - `set -e`, `pipefail` 적용으로 에러 발생 시 즉시 중단
  - **Kernel Version Check**: Cilium 1.18+ 호환성을 위한 엄격한 커널 버전 체크 (5.10+ 필수)
  - **입력 검증**: 정규식을 통한 버전 포맷 검증 및 안정성 체크
- **네트워크 정합성**: kubeadm `--pod-network-cidr`와 Cilium IPAM 모드(`kubernetes`) 자동 동기화
- **사용자 편의**:
  - `sudo` 사용자 및 `root` 사용자 모두에게 kubeconfig 자동 복사
  - kubectl 자동 완성 및 alias(`k`) 등록

---

## 📋 전제 조건 (Prerequisites)

- **OS**: Ubuntu 22.04 LTS / 24.04 LTS (권장) 또는 Debian 계열
- **Kernel**: **Linux Kernel 5.10 이상** (Cilium 1.18.x 필수 요구사항)
- **Privilege**: Root 권한 (`sudo -i` 또는 `sudo` 실행)
- **Network**: 외부 인터넷 접속 필요

---

## 📂 스크립트 파일 용도

| 파일명 | 용도 | 주요 실행 상황 |
| :--- | :--- | :--- |
| `k8s-setup.sh` | 단일 Control Plane 노드 설치(클러스터 초기화 + Cilium/Helm 포함) | 마스터(컨트롤 플레인) 최초 구축 |
| `k8s-worker-setup.sh` | Worker 노드 설치 및 `kubeadm join` 수행 | 워커 노드 추가 |
| `k8s_clean_uninstall.sh` | Kubernetes 구성요소 안전 제거(옵션 기반 정리) | 재설치 전 초기화/제거 |
| `test/k8s_instiall_with_criu_test.sh` | CRIU 관련 실험/테스트용 설치 스크립트 | 기능 검증/테스트 |

## 🔎 메시지(로그) 추적 가이드

- 설치 스크립트(`k8s-setup.sh`, `k8s-worker-setup.sh`)는 단계별로 `[1단계]`, `[2단계]` 형식으로 진행 상태를 출력합니다.
- 제거 스크립트(`k8s_clean_uninstall.sh`)는 `[1/5단계]` ~ `[5/5단계]` 형식으로 출력합니다.
- 오류 발생 시 `[오류]`, 경고는 `[경고]`, 일반 상태는 `[정보]`, 선택적 건너뛰기는 `[건너뜀]` 접두사로 표시됩니다.
- 실패 지점을 빠르게 찾으려면 실행 로그를 파일로 저장하세요.

```bash
sudo ./k8s-setup.sh 2>&1 | tee k8s-setup.log
sudo ./k8s-worker-setup.sh 2>&1 | tee k8s-worker-setup.log
sudo ./k8s_clean_uninstall.sh 2>&1 | tee k8s-clean-uninstall.log
```

---

## 🚀 사용 가이드 (Quick Start)

### 1. 스크립트 다운로드 및 권한 부여
```bash
git clone https://github.com/WoogiBoogi1129/Kubernetes_Installer_2026.git
cd Kubernetes_Installer_2026
chmod +x k8s-setup.sh
```

### 2. 설치 실행
반드시 **Root** 권한이 필요합니다.
```bash
# 권장: sudo 사용
sudo ./k8s-setup.sh

# 또는 root 쉘에서 실행
sudo -i
./k8s-setup.sh
```

### 3. 설치 과정 상호작용
스크립트를 실행하면 설치할 버전을 묻습니다.
```text
============================================================
 Kubernetes 설치 설정
============================================================
설치할 Kubernetes 버전을 입력하세요 (예: v1.35) [기본값: <latest stable>]:
```
- **Enter 입력 시**: 실행 시점 기준 최신 안정 버전으로 설치가 진행됩니다.
- **버전 지정 시**: `v1.34`와 같이 입력하면 해당 버전의 Kubernetes 및 호환되는 CRI-O가 설치됩니다.
- **검증**: 시스템은 자동으로 커널 버전과 입력 형식을 검증하고 설치를 진행합니다.

### 4. 설치 확인
설치가 완료되면 쉘을 재로딩하여 설정을 적용하세요.
```bash
source ~/.bashrc

# 노드 상태 확인 (Ready 상태여야 함)
k get nodes

# 모든 팟 상태 확인 (Cilium 포함 Running 상태여야 함)
k get pods -A
```

---

## 🧪 테스트 환경 (Single Node)
이 스크립트는 Single Control Plane 구성을 기본으로 합니다.
만약 **단일 노드**에서 파드를 배포하고 싶다면(Control Plane 노드에 스케줄링 허용), 아래 명령어를 추가로 실행하세요:

```bash
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
```

---

## 🗑️ 제거 및 초기화 (Clean Uninstall)

설치된 Kubernetes 환경을 안전하게 제거하고 초기화해야 할 경우, `k8s_clean_uninstall.sh`를 사용하세요.

```bash
chmod +x k8s_clean_uninstall.sh
sudo ./k8s_clean_uninstall.sh
```
> 상세한 제거 옵션은 스크립트 내부 도움말이나 하단 내용을 참고하세요.

### 제거 스크립트 옵션
| 옵션 | 설명 | 주의사항 |
| :--- | :--- | :--- |
| **`--cleanup-cni`** | CNI 인터페이스(`cni0` 등) 삭제 | K8s 전용 노드일 때만 권장 |
| **`--cleanup-etcd`** | Etcd 데이터(`/var/lib/etcd`) 삭제 | **데이터 복구 불가** |
| **`--autoremove`** | 의존성 패키지 자동 정리 | 타 프로그램 영향 확인 필요 |

---

## 📦 기술 스택 버전 정보
기본 설치 시 적용되는 버전은 다음과 같습니다. (스크립트 실행 시 변경 가능)

| Component | Default Version | Note |
| :--- | :--- | :--- |
| **Kubernetes** | `<latest stable>` | 실행 시 `https://dl.k8s.io/release/stable.txt` 조회 |
| **CRI-O** | Kubernetes와 동일 Minor | Kubernetes 버전과 자동 동기화 |
| **Cilium** | `1.18.6` | 최신 안정 버전 (Kernel 5.10+ Required) |
| **Helm** | Latest | 공식 인스톨러 사용 |
