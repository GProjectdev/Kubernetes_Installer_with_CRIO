#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# Kubernetes Install Script (Kubeadm + CRI-O + Cilium)
#
# Target OS: Ubuntu/Debian based systems
# Role: Single Control Plane setup
# Security: Enforces Root verification, strict error handling, dependency checks
# ==============================================================================

# Error Trap with Line Number and Command
trap 'echo "[오류] ${LINENO}번째 줄에서 실패: ${BASH_COMMAND}" >&2' ERR

# ------------------------------------------------------------------------------
# 0. Safety & Environment Checks
# ------------------------------------------------------------------------------
# 0.1 Root Check
if [ "$EUID" -ne 0 ]; then
  echo "[오류] 이 스크립트는 root 권한으로 실행해야 합니다." >&2
  echo "사용법: sudo -i 후 이 스크립트를 실행하세요." >&2
  exit 1
fi

umask 022

# 0.2 Existing Installation Check
if [ -f "/etc/kubernetes/admin.conf" ] || [ -d "/var/lib/etcd" ]; then
    echo "[오류] 기존 Kubernetes 구성이 감지되었습니다." >&2
    echo "감지된 경로: /etc/kubernetes/admin.conf 또는 /var/lib/etcd" >&2
    echo "이 스크립트 실행 전에 'kubeadm reset' 또는 수동 정리를 먼저 수행하세요." >&2
    exit 1
fi

# 0.3 Kernel Version Check (Strict Mode)
# Cilium 1.18+ requires Linux Kernel 5.10+
CURRENT_KERNEL_FULL=$(uname -r)
CURRENT_KERNEL_MAIN=$(echo "$CURRENT_KERNEL_FULL" | cut -d- -f1) # Extracts 6.8.0 from 6.8.0-31-generic
MIN_KERNEL="5.10"

if dpkg --compare-versions "$CURRENT_KERNEL_MAIN" lt "$MIN_KERNEL"; then
    echo "[오류] Cilium 1.18.x는 Linux Kernel ${MIN_KERNEL} 이상이 필요합니다." >&2
    echo "        현재 커널: $CURRENT_KERNEL_MAIN ($CURRENT_KERNEL_FULL)" >&2
    echo "        커널 업그레이드 후 다시 시도하세요." >&2
    exit 1
fi

# ------------------------------------------------------------------------------
# 1. Configuration & User Input
# ------------------------------------------------------------------------------
# Default fallback when latest stable lookup fails
DEFAULT_K8S_VER="v1.35"

get_latest_k8s_minor_version() {
  local stable_full stable_minor
  stable_full="$(curl -fsSL https://dl.k8s.io/release/stable.txt 2>/dev/null || true)"

  if [[ "${stable_full}" =~ ^v1\.[0-9]+\.[0-9]+$ ]]; then
    stable_minor="$(echo "${stable_full}" | cut -d. -f1-2)"
    echo "${stable_minor}"
    return 0
  fi

  return 1
}

if ! LATEST_K8S_VER="$(get_latest_k8s_minor_version)"; then
  LATEST_K8S_VER="${DEFAULT_K8S_VER}"
  echo "[경고] 최신 Kubernetes 안정 버전 조회에 실패하여 ${DEFAULT_K8S_VER}를 사용합니다." >&2
fi
# Cilium Version: Using 1.18.6 (Latest patch in 1.18 series as of context) for better k8s 1.35 compatibility
CILIUM_VERSION="1.18.6"
CIDR="10.85.0.0/16"

echo "============================================================"
echo " Kubernetes 설치 설정"
echo "============================================================"
echo -n "설치할 Kubernetes 버전을 입력하세요 (예: v1.35) [기본값: ${LATEST_K8S_VER}]: "
read -r USER_INPUT

# Version Selection Logic
if [ -z "$USER_INPUT" ]; then
  KUBERNETES_VERSION="${LATEST_K8S_VER}"
else
  # Auto-prepend 'v' if missing
  if [[ "${USER_INPUT}" != v* ]]; then
    KUBERNETES_VERSION="v${USER_INPUT}"
  else
    KUBERNETES_VERSION="${USER_INPUT}"
  fi
fi

# Regex Validation (Strictly v1.XX)
if [[ ! "${KUBERNETES_VERSION}" =~ ^v1\.[0-9]{2}$ ]]; then
  echo "[오류] 버전 형식이 잘못되었습니다: ${KUBERNETES_VERSION}. v1.XX 형식(예: v1.35)으로 입력하세요." >&2
  exit 1
fi

# Sync CRI-O version with Kubernetes version
CRIO_VERSION="${KUBERNETES_VERSION}"

echo ""
echo "------------------------------------------------------------"
echo " [설정 확인]"
echo " - Kubernetes 버전 : ${KUBERNETES_VERSION}"
echo " - CRI-O 버전      : ${CRIO_VERSION}"
echo " - Cilium 버전     : ${CILIUM_VERSION}"
echo " - Pod CIDR         : ${CIDR}"
echo " - 커널 버전       : ${CURRENT_KERNEL_FULL} (정상)"
echo "------------------------------------------------------------"
echo "3초 후 설치를 시작합니다... (취소: Ctrl+C)"
sleep 3
echo ""

# ------------------------------------------------------------------------------
# 2. System Preparation
# ------------------------------------------------------------------------------
echo "[1단계] 시스템 설정 (의존성, 스왑, 모듈, Sysctl)"

# 2.1 Install Critical Dependencies
# Added: conntrack, socat, iproute2, iptables which are critical for K8s networking
apt-get update
apt-get install -y \
    software-properties-common curl gnupg2 bash-completion \
    apt-transport-https ca-certificates \
    conntrack socat iproute2 iptables ebtables

# 2.2 Disable Swap (Permanent)
if grep -q "swap" /etc/fstab; then
    echo " > /etc/fstab의 swap을 비활성화합니다 (백업: /etc/fstab.bak)"
    sed -ri.bak '/\sswap\s/s/^/#/' /etc/fstab
fi
swapoff -a

# 2.3 Kernel Modules (Permanent Load)
cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

# 2.4 Sysctl Params (Permanent)
cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system

# 2.5 Prepare Safe Keyring Directory
install -d -m 0755 /etc/apt/keyrings

# ------------------------------------------------------------------------------
# 3. APT Repositories Setup
# ------------------------------------------------------------------------------
echo "[2단계] APT 저장소 구성"

# Kubernetes Official Repo (pkgs.k8s.io)
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/Release.key" \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list

# CRI-O Official Repo
curl -fsSL "https://download.opensuse.org/repositories/isv:/cri-o:/stable:/${CRIO_VERSION}/deb/Release.key" \
  | gpg --dearmor -o /etc/apt/keyrings/cri-o-apt-keyring.gpg
chmod 644 /etc/apt/keyrings/cri-o-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/cri-o-apt-keyring.gpg] https://download.opensuse.org/repositories/isv:/cri-o:/stable:/${CRIO_VERSION}/deb/ /" \
  > /etc/apt/sources.list.d/cri-o.list

# ------------------------------------------------------------------------------
# 4. Install Packages
# ------------------------------------------------------------------------------
echo "[3단계] 패키지 설치 (CRI-O, Kubeadm, Kubelet, Kubectl)"
apt-get update
apt-get install -y cri-o kubelet kubeadm kubectl

# Prevent accidental upgrades
# Note: In strict production environment, you might only hold kube components and let CRI-O update via patches,
# but holding all is safer for consistency without manual intervention.
apt-mark hold cri-o kubelet kubeadm kubectl

# Enable CRI-O
systemctl daemon-reload
systemctl enable --now crio

# ------------------------------------------------------------------------------
# 5. Cluster Initialization
# ------------------------------------------------------------------------------
echo "[4단계] Kubernetes 클러스터 초기화"
kubeadm init --pod-network-cidr="${CIDR}" --cri-socket=unix:///var/run/crio/crio.sock

# ------------------------------------------------------------------------------
# 5.1 Verification Wait Loop
# ------------------------------------------------------------------------------
echo " > API 서버 준비 상태를 확인합니다..."
export KUBECONFIG=/etc/kubernetes/admin.conf

# Wait up to 60 seconds
MAX_RETRIES=30
for ((i=1; i<=MAX_RETRIES; i++)); do
    if kubectl get --raw='/readyz' >/dev/null 2>&1; then
        echo " > API 서버가 준비되었습니다."
        break
    fi
    echo "   ... API 서버 대기 중 ($i/$MAX_RETRIES)"
    sleep 2
done

if ! kubectl get --raw='/readyz' >/dev/null 2>&1; then
    echo "[오류] 제한 시간 내 API 서버가 준비되지 않았습니다." >&2
    exit 1
fi

# ------------------------------------------------------------------------------
# 6. Kubeconfig Setup
# ------------------------------------------------------------------------------
echo "[5단계] kubeconfig 설정"

mkdir -p "$HOME/.kube"
cp -f /etc/kubernetes/admin.conf "$HOME/.kube/config"
chmod 600 "$HOME/.kube/config"

if [ -n "${SUDO_USER:-}" ]; then
    USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    USER_GID=$(id -gn "$SUDO_USER")
    
    echo " > sudo 사용자($SUDO_USER) 홈으로 kubeconfig를 복사합니다..."
    mkdir -p "$USER_HOME/.kube"
    cp -f /etc/kubernetes/admin.conf "$USER_HOME/.kube/config"
    chown -R "$SUDO_USER:$USER_GID" "$USER_HOME/.kube"
    chmod 600 "$USER_HOME/.kube/config"
fi

# ------------------------------------------------------------------------------
# 7. Install Tools (Helm & Cilium)
# ------------------------------------------------------------------------------
echo "[6단계] Helm 설치"
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh
./get_helm.sh
rm get_helm.sh

echo "[7단계] Cilium 설치"
# 7.1 Install Cilium CLI with robust error check (-fsSL)
# Fetching latest stable version strictly
CILIUM_CLI_VERSION=$(curl -fsSL https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
CLI_ARCH=amd64
if [ "$(uname -m)" = "aarch64" ]; then CLI_ARCH=arm64; fi

echo " > Cilium CLI ${CILIUM_CLI_VERSION} 다운로드 중..."
curl -L --fail --remote-name-all \
  "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz"{,.sha256sum}
sha256sum --check cilium-linux-${CLI_ARCH}.tar.gz.sha256sum
tar xzvf cilium-linux-${CLI_ARCH}.tar.gz -C /usr/local/bin
rm cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}

# 7.2 Install Cilium CNI
# Using updated version 1.18.6 for better stability with newer K8s
# Explicitly setting ipam.mode=kubernetes to match kubeadm pod-network-cidr
echo " > Cilium CNI 설치 중 (버전: ${CILIUM_VERSION}, ipam.mode=kubernetes)..."
cilium install --version "${CILIUM_VERSION}" \
  --helm-set ipam.mode=kubernetes

echo " > Cilium 상태를 확인합니다..."
cilium status --wait

# ------------------------------------------------------------------------------
# 8. User Convenience (.bashrc)
# ------------------------------------------------------------------------------
echo "[8단계] 쉘 편의 설정"

add_bash_config() {
    local target_file="$1"
    if ! grep -q "### K8S-SETUP-START" "$target_file"; then
        cat <<'EOF' >> "$target_file"

### K8S-SETUP-START
source <(kubectl completion bash)
alias k=kubectl
complete -F __start_kubectl k
### K8S-SETUP-END
EOF
    else
        echo " > Bash 설정이 이미 존재합니다: $target_file"
    fi
}

add_bash_config "$HOME/.bashrc"

if [ -n "${SUDO_USER:-}" ]; then
    USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    USER_GID=$(id -gn "$SUDO_USER") # Get group ID
    
    # Check if file exists before writing
    if [ -f "$USER_HOME/.bashrc" ]; then
        add_bash_config "$USER_HOME/.bashrc"
        # Since we append as root, we should ensure ownership isn't messed up, 
        # but appending usually preserves ownership if file exists. 
        # Just in case, safe to re-chown.
        chown "$SUDO_USER:$USER_GID" "$USER_HOME/.bashrc"
    fi
fi

# ------------------------------------------------------------------------------
# Completion
# ------------------------------------------------------------------------------
echo ""
echo "============================================================"
echo " [설치가 완료되었습니다]"
echo "============================================================"
echo " 1. 쉘 다시 불러오기:  source ~/.bashrc"
echo " 2. 노드 확인:        kubectl get nodes"
echo " 3. 파드 확인:        kubectl get pods -A"
echo "============================================================"
