#!/bin/bash
set -e

# ============================================================
# Version Configuration
# ============================================================

# Kubernetes / CRI-O는 minor repository를 지정.
# 해당 repository에서 제공되는 최신 patch version이 설치됨.
KUBERNETES_VERSION="v1.37"
CRIO_VERSION="v1.37"

# Kubernetes 1.37을 공식 테스트 대상으로 포함하는 Cilium 계열.
# 주의: 현재 1.21은 pre-release 상태.
CILIUM_VERSION="1.21.0-pre.2"

POD_CIDR="10.85.0.0/16"

echo "=========================================="
echo " Kubernetes Master Setup"
echo " Kubernetes : ${KUBERNETES_VERSION}"
echo " CRI-O      : ${CRIO_VERSION}"
echo " Cilium     : ${CILIUM_VERSION}"
echo " Pod CIDR   : ${POD_CIDR}"
echo "=========================================="

# ============================================================
# Step 1. 필수 패키지 설치
# ============================================================
echo "[Step 1] 필수 패키지 설치"

apt-get update

apt-get install -y \
    software-properties-common \
    curl \
    gnupg2 \
    bash-completion \
    apt-transport-https \
    ca-certificates

mkdir -p /etc/apt/keyrings


# ============================================================
# Step 2. Kubernetes Repository
# ============================================================
echo "[Step 2] Kubernetes ${KUBERNETES_VERSION} APT 저장소 등록"

rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg

curl -fsSL \
    https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/Release.key \
    | gpg --dearmor \
    -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo \
"deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/ /" \
    > /etc/apt/sources.list.d/kubernetes.list


# ============================================================
# Step 3. CRI-O Repository
# ============================================================
echo "[Step 3] CRI-O ${CRIO_VERSION} APT 저장소 등록"

rm -f /etc/apt/keyrings/cri-o-apt-keyring.gpg

curl -fsSL \
    https://download.opensuse.org/repositories/isv:/cri-o:/stable:/${CRIO_VERSION}/deb/Release.key \
    | gpg --dearmor \
    -o /etc/apt/keyrings/cri-o-apt-keyring.gpg

echo \
"deb [signed-by=/etc/apt/keyrings/cri-o-apt-keyring.gpg] \
https://download.opensuse.org/repositories/isv:/cri-o:/stable:/${CRIO_VERSION}/deb/ /" \
    > /etc/apt/sources.list.d/cri-o.list


# ============================================================
# Step 4. Kubernetes + CRI-O 설치
# ============================================================
echo "[Step 4] Kubernetes 및 CRI-O 설치"

apt-get update

echo "=== 설치 가능한 Kubernetes 버전 ==="
apt-cache madison kubeadm || true

echo ""
echo "=== 설치 가능한 CRI-O 버전 ==="
apt-cache madison cri-o || true

apt-get install -y \
    cri-o \
    kubelet \
    kubeadm \
    kubectl

# 자동 버전 변경 방지
apt-mark hold kubelet kubeadm kubectl

echo ""
echo "=========================================="
echo " Installed versions"
echo "=========================================="

kubeadm version
kubelet --version
kubectl version --client
crio --version | head -n 5


# ============================================================
# Step 5. Kernel Module 설정
# ============================================================
echo "[Step 5] Kernel Module 설정"

cat <<EOF > /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

echo ""
echo "Loaded modules:"
lsmod | grep -E 'overlay|br_netfilter' || true


# ============================================================
# Step 6. Swap 비활성화
# ============================================================
echo "[Step 6] Swap 비활성화"

swapoff -a

# 재부팅 후에도 swap 비활성
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

echo "Current swap:"
swapon --show


# ============================================================
# Step 7. Sysctl 설정
# ============================================================
echo "[Step 7] Kubernetes Network Sysctl 설정"

cat <<EOF > /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF

sysctl --system


# ============================================================
# Step 8. CRI-O 시작
# ============================================================
echo "[Step 8] CRI-O 서비스 시작"

systemctl daemon-reload
systemctl enable --now crio

echo ""
echo "CRI-O status:"
systemctl is-active crio

if [ ! -S /var/run/crio/crio.sock ]; then
    echo "[ERROR] CRI-O socket을 찾을 수 없습니다."
    echo "확인:"
    echo "  systemctl status crio"
    echo "  journalctl -u crio -xe"
    exit 1
fi

echo "CRI-O socket:"
ls -l /var/run/crio/crio.sock


# ============================================================
# Step 9. kubelet 활성화
# ============================================================
echo "[Step 9] kubelet 활성화"

systemctl enable kubelet


# ============================================================
# Step 10. kubeadm init
# ============================================================
echo "[Step 10] Kubernetes Control Plane 초기화"

kubeadm init \
    --pod-network-cidr="${POD_CIDR}" \
    --cri-socket=unix:///var/run/crio/crio.sock


# ============================================================
# Step 11. kubeconfig
# ============================================================
echo "[Step 11] kubeconfig 설정"

mkdir -p "$HOME/.kube"

cp -f \
    /etc/kubernetes/admin.conf \
    "$HOME/.kube/config"

chown "$(id -u)":"$(id -g)" \
    "$HOME/.kube/config"

export KUBECONFIG="$HOME/.kube/config"


# ============================================================
# Step 12. Helm 설치
# ============================================================
echo "[Step 12] Helm 설치"

rm -f /usr/share/keyrings/helm.gpg

curl -fsSL \
    https://packages.buildkite.com/helm-linux/helm-debian/gpgkey \
    | gpg --dearmor \
    | tee /usr/share/keyrings/helm.gpg > /dev/null

echo \
"deb [signed-by=/usr/share/keyrings/helm.gpg] \
https://packages.buildkite.com/helm-linux/helm-debian/any/ any main" \
    > /etc/apt/sources.list.d/helm-stable-debian.list

apt-get update
apt-get install -y helm

helm version


# ============================================================
# Step 13. Cilium CLI 설치
# ============================================================
echo "[Step 13] Cilium CLI 설치"

CILIUM_CLI_VERSION=$(
    curl -s \
    https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt
)

CLI_ARCH=amd64

if [ "$(uname -m)" = "aarch64" ]; then
    CLI_ARCH=arm64
fi

echo "Cilium CLI Version: ${CILIUM_CLI_VERSION}"
echo "Architecture      : ${CLI_ARCH}"

curl -L --fail --remote-name-all \
    https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}

sha256sum \
    --check \
    cilium-linux-${CLI_ARCH}.tar.gz.sha256sum

tar xzvf \
    cilium-linux-${CLI_ARCH}.tar.gz \
    -C /usr/local/bin

rm -f \
    cilium-linux-${CLI_ARCH}.tar.gz \
    cilium-linux-${CLI_ARCH}.tar.gz.sha256sum

cilium version


# ============================================================
# Step 14. Cilium 설치
# ============================================================
echo "[Step 14] Cilium ${CILIUM_VERSION} 설치"

cilium install \
    --version "${CILIUM_VERSION}"

echo ""
echo "[Step 14-1] Cilium 상태 확인"

cilium status --wait


# ============================================================
# Step 15. Kubernetes Cluster 확인
# ============================================================
echo "[Step 15] Kubernetes Cluster 상태 확인"

echo ""
echo "=== Nodes ==="
kubectl get nodes -o wide

echo ""
echo "=== Pods ==="
kubectl get pods -A


# ============================================================
# Step 16. DRA API 확인
# ============================================================
echo "[Step 16] Kubernetes DRA API 확인"

echo ""
echo "=== resource.k8s.io resources ==="

kubectl api-resources \
    --api-group=resource.k8s.io || true

echo ""
echo "=== DeviceClasses ==="
kubectl get deviceclasses 2>/dev/null || true

echo ""
echo "=== ResourceClaims ==="
kubectl get resourceclaims -A 2>/dev/null || true

echo ""
echo "=== ResourceSlices ==="
kubectl get resourceslices 2>/dev/null || true


# ============================================================
# Step 17. kubectl completion 및 alias
# ============================================================
echo "[Step 17] kubectl bash completion 및 alias 설정"

grep -qxF \
    'source <(kubectl completion bash)' ~/.bashrc || \
    echo 'source <(kubectl completion bash)' >> ~/.bashrc

grep -qxF \
    'alias k=kubectl' ~/.bashrc || \
    echo 'alias k=kubectl' >> ~/.bashrc

grep -qxF \
    'complete -o default -F __start_kubectl k' ~/.bashrc || \
    echo 'complete -o default -F __start_kubectl k' >> ~/.bashrc


# ============================================================
# 완료
# ============================================================

echo ""
echo "=========================================="
echo " Kubernetes Master Setup Complete"
echo "=========================================="

echo ""
echo "Kubernetes:"
kubectl version --client

echo ""
echo "CRI-O:"
crio --version | head -n 5

echo ""
echo "Cilium:"
cilium version

echo ""
echo "Nodes:"
kubectl get nodes -o wide

echo ""
echo "DRA Resources:"
kubectl api-resources --api-group=resource.k8s.io || true

echo ""
echo "[완료]"
echo "bash 설정 적용:"
echo "source ~/.bashrc"
