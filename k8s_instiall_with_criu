#!/bin/bash
set -e

# ==========================================
# 1. 버전 및 환경 변수 설정
# ==========================================
# v1.33
KUBERNETES_VERSION="v1.33"
CRIO_VERSION="v1.33"
CILIUM_VERSION="1.16.1" # 최신 안정 버전

echo "[Start] Kubernetes + CRI-O(w/ CRIU) + Cilium 설치 시작"

# ==========================================
# 2. 사전 준비 & 필수 패키지
# ==========================================
echo "[Step 1] 기존 충돌 패키지 정리 및 필수 패키지 설치"
# 충돌 방지를 위해 기존 Docker/Containerd 제거
apt-get remove -y docker.io containerd.io kubelet kubeadm kubectl || true
apt-get autoremove -y

apt-get update
# [PDF 반영] CRIU 및 빌드 관련 의존성 추가 (libnftables, protobuf 등)
apt-get install -y software-properties-common curl gnupg2 bash-completion \
    libnftables-dev build-essential protobuf-compiler libbtrfs-dev libgpgme-dev \
    pkg-config nano vim nfs-common git

# [PDF 반영] CRIU PPA 추가 및 설치
add-apt-repository -y ppa:criu/ppa
apt-get update
apt-get install -y criu runc

# ==========================================
# 3. 저장소 등록 (K8s, CRI-O, Helm)
# ==========================================
mkdir -p /etc/apt/keyrings

echo "[Step 2] Kubernetes & CRI-O 저장소 등록"
# Kubernetes
curl -fsSL https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/Release.key | \
    gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/ /" | \
    tee /etc/apt/sources.list.d/kubernetes.list

# CRI-O
curl -fsSL https://pkgs.k8s.io/addons:/cri-o:/stable:/${CRIO_VERSION}/deb/Release.key | \
    gpg --dearmor -o /etc/apt/keyrings/cri-o-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/cri-o-apt-keyring.gpg] https://pkgs.k8s.io/addons:/cri-o:/stable:/${CRIO_VERSION}/deb/ /" | \
    tee /etc/apt/sources.list.d/cri-o.list

echo "[Step 3] Helm 저장소 등록"
# [수정] 줄바꿈 에러(Malformed entry) 방지를 위해 한 줄로 작성, 공식 GPG 키 사용 권장
curl https://baltocdn.com/helm/signing.asc | gpg --dearmor | tee /usr/share/keyrings/helm.gpg > /dev/null
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/helm.gpg] https://baltocdn.com/helm/stable/debian/ all main" | \
    tee /etc/apt/sources.list.d/helm-stable-debian.list

# ==========================================
# 4. 패키지 설치
# ==========================================
echo "[Step 4] 패키지 설치 (K8s, CRI-O, Helm)"
apt-get update
apt-get install -y cri-o kubelet kubeadm kubectl helm

# ==========================================
# 5. 시스템 설정 (Kernel, Swap, CRI-O config)
# ==========================================
echo "[Step 5] 시스템 및 커널 설정"
swapoff -a
modprobe br_netfilter
modprobe overlay

cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

echo "[Step 6] CRI-O 설정 (CRIU 활성화 및 runc 지정)"
# 기본 설정 생성
crio config > /etc/crio/crio.conf

# [PDF 반영] 설정 오버라이드
# 1. default_runtime을 runc로 변경 (crun은 호환성 문제)
# 2. enable_criu_support 활성화
mkdir -p /etc/crio/crio.conf.d
cat <<EOF | tee /etc/crio/crio.conf.d/10-crio.conf
[crio.runtime]
default_runtime = "runc"
enable_criu_support = true

[crio.image]
# Restore 시 이미지 서명 문제 방지
signature_policy = ""
EOF

systemctl daemon-reload
systemctl enable crio
systemctl restart crio

echo "[Step 7] Kubelet Checkpoint Feature Gate 활성화"
# [PDF 반영] kubelet에 ContainerCheckpoint 기능 켜기
if [ -f /etc/default/kubelet ]; then
    if grep -q "KUBELET_EXTRA_ARGS" /etc/default/kubelet; then
         sed -i 's/KUBELET_EXTRA_ARGS="/KUBELET_EXTRA_ARGS="--feature-gates=ContainerCheckpoint=true /' /etc/default/kubelet
    else
         echo 'KUBELET_EXTRA_ARGS="--feature-gates=ContainerCheckpoint=true"' >> /etc/default/kubelet
    fi
else
    echo 'KUBELET_EXTRA_ARGS="--feature-gates=ContainerCheckpoint=true"' > /etc/default/kubelet
fi
systemctl restart kubelet

# ==========================================
# 6. Kubernetes 초기화
# ==========================================
echo "[Step 8] kubeadm 초기화"
export CIDR=10.85.0.0/16

# [수정] --crisocket 오류 해결 -> --cri-socket
kubeadm init --pod-network-cidr=$CIDR --cri-socket=unix:///var/run/crio/crio.sock

echo "[Step 9] kubeconfig 설정"
mkdir -p $HOME/.kube
cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config

# ==========================================
# 7. Cilium 설치
# ==========================================
echo "[Step 10] Cilium CLI 설치"
# [수정] URL 오타(ciliumcli -> cilium-cli) 및 tar 문법 오류 해결
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
CLI_ARCH=amd64
if [ "$(uname -m)" = "aarch64" ]; then CLI_ARCH=arm64; fi

echo "Downloading Cilium CLI ${CILIUM_CLI_VERSION}..."
curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
sha256sum --check cilium-linux-${CLI_ARCH}.tar.gz.sha256sum
sudo tar xzvf cilium-linux-${CLI_ARCH}.tar.gz -C /usr/local/bin
rm cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}

echo "[Step 11] Cilium Helm Chart 설치"
helm repo add cilium https://helm.cilium.io/
helm repo update
# Cilium 설치 (Operator 복제본 1개 설정 등)
helm install cilium cilium/cilium --version ${CILIUM_VERSION} \
   --namespace kube-system \
   --set operator.replicas=1 \
   --set ipam.operator.clusterPoolIPv4PodCIDRList=$CIDR

echo "[Step 12] kubectl 편의 설정"
source /usr/share/bash-completion/bash_completion
echo 'source <(kubectl completion bash)' >> ~/.bashrc
echo 'alias k=kubectl' >> ~/.bashrc
echo 'complete -F __start_kubectl k' >> ~/.bashrc

echo "============================================================"
echo "[완료] 설치가 모두 끝났습니다."
echo "1. 변경된 환경변수 적용을 위해 다음 명령어를 입력하세요:"
echo "   source ~/.bashrc"
echo "2. CRI-O 런타임이 runc로 설정되었는지 확인:"
echo "   crio config | grep default_runtime"
echo "3. 노드 상태 확인:"
echo "   kubectl get nodes -o wide"
echo "============================================================"
