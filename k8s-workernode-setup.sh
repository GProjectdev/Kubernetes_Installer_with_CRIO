#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# Kubernetes Worker Node Installer with CRI-O
#
# 실행 예:
#   sudo bash k8s-workernode-setup.sh
#
# Join까지 자동 수행:
#   sudo JOIN_COMMAND='kubeadm join 10.0.0.10:6443 \
#     --token abcdef.0123456789abcdef \
#     --discovery-token-ca-cert-hash sha256:...' \
#     bash k8s-workernode-setup.sh
# ============================================================

KUBERNETES_VERSION="${KUBERNETES_VERSION:-v1.33}"
CRIO_VERSION="${CRIO_VERSION:-v1.33}"

CRIO_SOCKET="unix:///var/run/crio/crio.sock"

log() {
    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"
}

error_handler() {
    echo
    echo "[ERROR] 스크립트 실행 중 오류가 발생했습니다."
    echo "Line: ${BASH_LINENO[0]}"
    exit 1
}

trap error_handler ERR

# ------------------------------------------------------------
# 0. 실행 환경 확인
# ------------------------------------------------------------
if [[ "${EUID}" -ne 0 ]]; then
    echo "이 스크립트는 root 권한으로 실행해야 합니다."
    echo "예: sudo bash $0"
    exit 1
fi

if [[ ! -f /etc/os-release ]]; then
    echo "/etc/os-release를 찾을 수 없습니다."
    exit 1
fi

source /etc/os-release

case "${ID}" in
    ubuntu|debian)
        ;;
    *)
        echo "지원하지 않는 운영체제입니다: ${ID}"
        echo "현재 스크립트는 Ubuntu/Debian 계열을 대상으로 합니다."
        exit 1
        ;;
esac

ARCH="$(dpkg --print-architecture)"

case "${ARCH}" in
    amd64|arm64)
        ;;
    *)
        echo "지원 여부를 확인하지 않은 아키텍처입니다: ${ARCH}"
        exit 1
        ;;
esac

log "[Step 1] Swap 비활성화"

swapoff -a

# /etc/fstab에서 Swap 항목을 주석 처리하여 재부팅 후에도 비활성화
if grep -Eq '^[^#].*\sswap\s' /etc/fstab; then
    cp /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"
    sed -ri '/^[^#].*\sswap\s/s/^/#/' /etc/fstab
fi

log "[Step 2] 커널 모듈 설정"

cat > /etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

log "[Step 3] 네트워크 커널 파라미터 설정"

cat > /etc/sysctl.d/99-kubernetes-cri.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system

log "[Step 4] 필수 패키지 설치"

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gpg \
    gnupg2 \
    software-properties-common \
    bash-completion \
    conntrack \
    socat

install -m 0755 -d /etc/apt/keyrings

log "[Step 5] Kubernetes APT 저장소 등록"

rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg

curl -fsSL \
    "https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/Release.key" |
    gpg --dearmor \
        -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

chmod 0644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg

cat > /etc/apt/sources.list.d/kubernetes.list <<EOF
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/ /
EOF

log "[Step 6] CRI-O APT 저장소 등록"

rm -f /etc/apt/keyrings/cri-o-apt-keyring.gpg

curl -fsSL \
    "https://download.opensuse.org/repositories/isv:/cri-o:/stable:/${CRIO_VERSION}/deb/Release.key" |
    gpg --dearmor \
        -o /etc/apt/keyrings/cri-o-apt-keyring.gpg

chmod 0644 /etc/apt/keyrings/cri-o-apt-keyring.gpg

cat > /etc/apt/sources.list.d/cri-o.list <<EOF
deb [signed-by=/etc/apt/keyrings/cri-o-apt-keyring.gpg] https://download.opensuse.org/repositories/isv:/cri-o:/stable:/${CRIO_VERSION}/deb/ /
EOF

log "[Step 7] Kubernetes 및 CRI-O 설치"

apt-get update
apt-get install -y \
    cri-o \
    kubelet \
    kubeadm \
    kubectl

# 자동 업데이트로 인한 Kubernetes 버전 불일치 방지
apt-mark hold kubelet kubeadm kubectl cri-o

log "[Step 8] CRI-O 및 kubelet 서비스 활성화"

systemctl daemon-reload
systemctl enable --now crio
systemctl enable --now kubelet

log "[Step 9] CRI-O 상태 확인"

if ! systemctl is-active --quiet crio; then
    echo "CRI-O가 정상적으로 실행되지 않았습니다."
    systemctl status crio --no-pager || true
    journalctl -u crio -n 100 --no-pager || true
    exit 1
fi

echo "CRI-O service: active"
echo "CRI-O socket: ${CRIO_SOCKET}"

if [[ ! -S /var/run/crio/crio.sock ]]; then
    echo "CRI-O 소켓을 찾을 수 없습니다: /var/run/crio/crio.sock"
    exit 1
fi

if command -v crictl >/dev/null 2>&1; then
    cat > /etc/crictl.yaml <<EOF
runtime-endpoint: ${CRIO_SOCKET}
image-endpoint: ${CRIO_SOCKET}
timeout: 10
debug: false
EOF

    crictl info >/dev/null
    echo "CRI API 연결 확인 완료"
else
    echo "[WARNING] crictl을 찾지 못해 CRI API 검증을 생략합니다."
fi

log "[Step 10] 설치 결과 확인"

echo "Kubernetes repository version: ${KUBERNETES_VERSION}"
echo "CRI-O repository version:      ${CRIO_VERSION}"
echo

kubeadm version -o short
kubelet --version
kubectl version --client
crio --version | head -n 1

# ------------------------------------------------------------
# 선택 사항: Control Plane에 자동 Join
#
# 토큰이 포함된 Join 명령을 파일에 직접 기록하지 말고,
# JOIN_COMMAND 환경변수로 전달한다.
# ------------------------------------------------------------
if [[ -n "${JOIN_COMMAND:-}" ]]; then
    log "[Step 11] Kubernetes 클러스터 Join"

    # 이미 Join된 노드라면 중복 실행 방지
    if [[ -f /etc/kubernetes/kubelet.conf ]]; then
        echo "이미 /etc/kubernetes/kubelet.conf가 존재합니다."
        echo "이 노드는 이미 클러스터에 Join된 것으로 보입니다."
        exit 1
    fi

    # CRI-O 소켓을 명시하지 않은 경우 자동 추가
    if [[ "${JOIN_COMMAND}" != *"--cri-socket"* ]]; then
        JOIN_COMMAND="${JOIN_COMMAND} --cri-socket ${CRIO_SOCKET}"
    fi

    eval "${JOIN_COMMAND}"

    echo
    echo "Worker Node Join 명령을 완료했습니다."
else
    log "Worker Node 사전 설치 완료"

    echo "아직 Kubernetes 클러스터에 Join하지 않았습니다."
    echo
    echo "Control Plane에서 다음 명령으로 Join 명령을 생성하십시오:"
    echo
    echo "  kubeadm token create --print-join-command"
    echo
    echo "출력된 명령을 이 Worker Node에서 다음과 같이 실행하십시오:"
    echo
    echo "  sudo kubeadm join <CONTROL_PLANE_IP>:6443 \\"
    echo "    --token <TOKEN> \\"
    echo "    --discovery-token-ca-cert-hash sha256:<HASH> \\"
    echo "    --cri-socket ${CRIO_SOCKET}"
fi
