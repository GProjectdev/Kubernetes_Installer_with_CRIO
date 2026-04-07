#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# Kubernetes Worker Install Script (Kubeadm + CRI-O)
#
# Target OS: Ubuntu/Debian based systems
# Role: Worker node setup and cluster join
# Security: Enforces Root verification, strict error handling, dependency checks
# ==============================================================================

trap 'echo "[오류] ${LINENO}번째 줄에서 실패: ${BASH_COMMAND}" >&2' ERR

APT_GET=(apt-get -o Dpkg::Lock::Timeout=120 -o Acquire::Retries=3)

# ------------------------------------------------------------------------------
# 0. Safety & Environment Checks
# ------------------------------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
  echo "[오류] 이 스크립트는 root 권한으로 실행해야 합니다." >&2
  echo "사용법: sudo -i 후 이 스크립트를 실행하세요." >&2
  exit 1
fi

umask 022

# Abort if node already joined a cluster
if [ -f "/etc/kubernetes/kubelet.conf" ] || [ -d "/etc/kubernetes/pki" ]; then
  echo "[오류] 기존 Kubernetes 워커 노드 구성이 감지되었습니다." >&2
  echo "감지된 경로: /etc/kubernetes/kubelet.conf 또는 /etc/kubernetes/pki" >&2
  echo "이 스크립트 실행 전에 'kubeadm reset' 또는 수동 정리를 먼저 수행하세요." >&2
  exit 1
fi

# Kernel Version Check (Cilium datapath compatibility on workers)
CURRENT_KERNEL_FULL=$(uname -r)
CURRENT_KERNEL_MAIN=$(echo "$CURRENT_KERNEL_FULL" | cut -d- -f1)
MIN_KERNEL="5.10"

if dpkg --compare-versions "$CURRENT_KERNEL_MAIN" lt "$MIN_KERNEL"; then
  echo "[오류] 이 설치는 Linux Kernel ${MIN_KERNEL} 이상이 필요합니다." >&2
  echo "        현재 커널: $CURRENT_KERNEL_MAIN ($CURRENT_KERNEL_FULL)" >&2
  exit 1
fi

# ------------------------------------------------------------------------------
# 1. Configuration & User Input
# ------------------------------------------------------------------------------
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

echo "============================================================"
echo " Kubernetes 워커 노드 설치 설정"
echo "============================================================"

echo -n "설치할 Kubernetes 버전을 입력하세요 (예: v1.35) [기본값: ${LATEST_K8S_VER}]: "
read -r USER_INPUT

if [ -z "$USER_INPUT" ]; then
  KUBERNETES_VERSION="${LATEST_K8S_VER}"
else
  if [[ "${USER_INPUT}" != v* ]]; then
    KUBERNETES_VERSION="v${USER_INPUT}"
  else
    KUBERNETES_VERSION="${USER_INPUT}"
  fi
fi

if [[ ! "${KUBERNETES_VERSION}" =~ ^v1\.[0-9]{2}$ ]]; then
  echo "[오류] 버전 형식이 잘못되었습니다: ${KUBERNETES_VERSION}. v1.XX 형식(예: v1.35)으로 입력하세요." >&2
  exit 1
fi

CRIO_VERSION="${KUBERNETES_VERSION}"

echo -n "컨트롤 플레인 엔드포인트를 입력하세요 (예: 10.0.0.10:6443): "
read -r CONTROL_PLANE_ENDPOINT
if [[ ! "${CONTROL_PLANE_ENDPOINT}" =~ ^[a-zA-Z0-9._-]+:[0-9]{2,5}$ ]]; then
  echo "[오류] 엔드포인트 형식이 잘못되었습니다: ${CONTROL_PLANE_ENDPOINT}. host:port 형식으로 입력하세요." >&2
  exit 1
fi

echo -n "kubeadm 조인 토큰을 입력하세요 (예: abcdef.0123456789abcdef): "
read -r JOIN_TOKEN
if [[ ! "${JOIN_TOKEN}" =~ ^[a-z0-9]{6}\.[a-z0-9]{16}$ ]]; then
  echo "[오류] 토큰 형식이 잘못되었습니다." >&2
  exit 1
fi

echo -n "discovery token CA cert hash를 입력하세요 (예: sha256:...): "
read -r DISCOVERY_HASH
if [[ ! "${DISCOVERY_HASH}" =~ ^sha256:[a-f0-9]{64}$ ]]; then
  echo "[오류] discovery hash 형식이 잘못되었습니다." >&2
  exit 1
fi

echo -n "노드 이름 오버라이드(선택)를 입력하세요 (건너뛰려면 Enter): "
read -r NODE_NAME

echo ""
echo "------------------------------------------------------------"
echo " [설정 확인]"
echo " - Kubernetes 버전 : ${KUBERNETES_VERSION}"
echo " - CRI-O 버전      : ${CRIO_VERSION}"
echo " - 컨트롤 플레인   : ${CONTROL_PLANE_ENDPOINT}"
echo " - 커널 버전       : ${CURRENT_KERNEL_FULL} (정상)"
if [ -n "${NODE_NAME}" ]; then
  echo " - 노드 이름 지정   : ${NODE_NAME}"
else
  echo " - 노드 이름 지정   : (없음)"
fi
echo "------------------------------------------------------------"
echo "3초 후 설치를 시작합니다... (취소: Ctrl+C)"
sleep 3
echo ""

# ------------------------------------------------------------------------------
# 2. System Preparation
# ------------------------------------------------------------------------------
echo "[1단계] 시스템 설정 (의존성, 스왑, 모듈, Sysctl)"

export DEBIAN_FRONTEND=noninteractive

"${APT_GET[@]}" update
"${APT_GET[@]}" install -y --no-install-recommends \
    software-properties-common curl gnupg2 bash-completion \
    apt-transport-https ca-certificates \
    conntrack socat iproute2 iptables ebtables

swapoff -a
if grep -q "swap" /etc/fstab; then
    echo " > /etc/fstab의 swap을 비활성화합니다 (백업: /etc/fstab.bak)"
    sed -ri.bak '/\sswap\s/s/^/#/' /etc/fstab
fi

# Mask all systemd-managed swap units to keep swap disabled after reboot.
while read -r swap_unit; do
    [ -n "${swap_unit}" ] && systemctl mask "${swap_unit}" >/dev/null 2>&1 || true
done < <(systemctl list-unit-files --type=swap --no-legend 2>/dev/null | awk '{print $1}')

cat > /etc/modules-load.d/k8s.conf <<EOF_MOD
overlay
br_netfilter
EOF_MOD

modprobe overlay
modprobe br_netfilter

cat > /etc/sysctl.d/k8s.conf <<EOF_SYSCTL
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF_SYSCTL

sysctl --system
install -d -m 0755 /etc/apt/keyrings

# ------------------------------------------------------------------------------
# 3. APT Repositories Setup
# ------------------------------------------------------------------------------
echo "[2단계] APT 저장소 구성"

download_key() {
  local url="$1"
  local out="$2"
  local tmp
  tmp="$(mktemp)"

  if ! curl -fsSL "${url}" -o "${tmp}"; then
    rm -f "${tmp}"
    echo "[오류] 키 다운로드에 실패했습니다: ${url}" >&2
    exit 1
  fi

  if [ ! -s "${tmp}" ]; then
    rm -f "${tmp}"
    echo "[오류] 빈 키 파일이 다운로드되었습니다: ${url}" >&2
    exit 1
  fi

  if ! gpg --dearmor -o "${out}" "${tmp}"; then
    rm -f "${tmp}" "${out}"
    echo "[오류] 키링 변환에 실패했습니다: ${out}" >&2
    exit 1
  fi

  rm -f "${tmp}"
  chmod 644 "${out}"
}

download_key \
  "https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/Release.key" \
  "/etc/apt/keyrings/kubernetes-apt-keyring.gpg"

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list

download_key \
  "https://pkgs.k8s.io/addons:/cri-o:/stable:/${CRIO_VERSION}/deb/Release.key" \
  "/etc/apt/keyrings/cri-o-apt-keyring.gpg"

echo "deb [signed-by=/etc/apt/keyrings/cri-o-apt-keyring.gpg] https://pkgs.k8s.io/addons:/cri-o:/stable:/${CRIO_VERSION}/deb/ /" \
  > /etc/apt/sources.list.d/cri-o.list

# ------------------------------------------------------------------------------
# 4. Install Packages
# ------------------------------------------------------------------------------
echo "[3단계] 패키지 설치 (CRI-O, Kubeadm, Kubelet, Kubectl)"
"${APT_GET[@]}" update
"${APT_GET[@]}" install -y --no-install-recommends cri-o kubelet kubeadm kubectl

apt-mark hold cri-o kubelet kubeadm kubectl

# Explicitly pin CRI-O to systemd cgroup manager for kubelet compatibility.
install -d -m 0755 /etc/crio/crio.conf.d
cat > /etc/crio/crio.conf.d/99-kubernetes.conf <<'EOF_CRIO'
[crio.runtime]
cgroup_manager = "systemd"
EOF_CRIO

systemctl daemon-reload
systemctl enable --now crio
systemctl enable kubelet

if ! systemctl is-active --quiet crio; then
  echo "[오류] CRI-O 서비스가 비활성 상태입니다. 확인: systemctl status crio" >&2
  exit 1
fi

# ------------------------------------------------------------------------------
# 5. Join Cluster
# ------------------------------------------------------------------------------
echo "[4단계] 워커 노드를 클러스터에 조인"

JOIN_CMD=(
  kubeadm join "${CONTROL_PLANE_ENDPOINT}"
  --token "${JOIN_TOKEN}"
  --discovery-token-ca-cert-hash "${DISCOVERY_HASH}"
  --cri-socket unix:///var/run/crio/crio.sock
)

if [ -n "${NODE_NAME}" ]; then
  JOIN_CMD+=(--node-name "${NODE_NAME}")
fi

"${JOIN_CMD[@]}"

# ------------------------------------------------------------------------------
# 6. User Convenience (.bashrc)
# ------------------------------------------------------------------------------
echo "[5단계] 쉘 편의 설정"

add_bash_config() {
    local target_file="$1"
    [ -f "${target_file}" ] || return 0

    if ! grep -q "### K8S-SETUP-START" "$target_file"; then
        cat <<'EOF_BASH' >> "$target_file"

### K8S-SETUP-START
source <(kubectl completion bash)
alias k=kubectl
complete -F __start_kubectl k
### K8S-SETUP-END
EOF_BASH
    else
        echo " > Bash 설정이 이미 존재합니다: $target_file"
    fi
}

add_bash_config "$HOME/.bashrc"

REAL_USER="${SUDO_USER:-}"
if [ -z "${REAL_USER}" ]; then
    REAL_USER="$(logname 2>/dev/null || true)"
fi

if [ -n "${REAL_USER}" ] && [ "${REAL_USER}" != "root" ]; then
    USER_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
    USER_GID=$(id -gn "$REAL_USER")

    if [ -f "$USER_HOME/.bashrc" ]; then
        add_bash_config "$USER_HOME/.bashrc"
        chown "$REAL_USER:$USER_GID" "$USER_HOME/.bashrc"
    fi
fi

# ------------------------------------------------------------------------------
# Completion
# ------------------------------------------------------------------------------
echo ""
echo "============================================================"
echo " [워커 노드 조인이 완료되었습니다]"
echo "============================================================"
echo " 1. 쉘 다시 불러오기:  source ~/.bashrc"
echo " 2. 컨트롤 플레인에서 확인: kubectl get nodes"
echo "============================================================"
