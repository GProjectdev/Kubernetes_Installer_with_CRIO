#!/bin/bash
set -e

# ==========================================
# 1. 버전 설정
# ==========================================
# v1.33
# 필요 시 버전을 변경하세요.
KUBERNETES_VERSION="v1.33"
CRIO_VERSION="v1.33"
CILIUM_VERSION="1.16.1" # Cilium 안정 버전 추천

echo "[Start] Kubernetes(v1.33) + CRI-O + Cilium 설치 (No CRIU)"

# ==========================================
# 2. 사전 준비
# ==========================================
echo "[Step 1] 필수 패키지 설치"
# 충돌 방지를 위해 기존 패키지 제거
apt-get remove -y docker.io containerd.io kubelet kubeadm kubectl || true
apt-get autoremove -y

apt-get update
apt-get install -y software-properties-common curl gnupg2 bash-completion apt-transport-https

# APT 키 디렉토리 생성
mkdir -p /etc/apt/keyrings

echo "[Step 2] Kubernetes APT 저장소 등록"
curl -fsSL https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/Release.key | \
    gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/ /" | \
    tee /etc/apt/sources.list.d/kubernetes.list

echo "[Step 3] CRI-O APT 저장소 등록"
curl -fsSL https://pkgs.k8s.io/addons:/cri-o:/stable:/${CRIO_VERSION}/deb/Release.key | \
    gpg --dearmor -o /etc/apt/keyrings/cri-o-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/cri-o-apt-keyring.gpg] https://pkgs.k8s.io/addons:/cri-o:/stable:/${CRIO_VERSION}/deb/ /" | \
    tee /etc/apt/sources.list.d/cri-o.list

echo "[Step 4] Kubernetes 및 CRI-O 설치"
apt-get update
apt-get install -y cri-o kubelet kubeadm kubectl

echo "[Step 5] CRI-O 서비스 시작"
systemctl daemon-reload
systemctl enable crio
systemctl start crio

echo "[Step 6] Swap 및 커널 설정"
swapoff -a
modprobe br_netfilter
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.bridge.bridge-nf-call-iptables=1

# sysctl 영구 적용
cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF
sysctl --system

# ==========================================
# 3. 클러스터 초기화
# ==========================================
echo "[Step 7] kubeadm 초기화"
export CIDR=10.85.0.0/16

# [수정됨] --crisocket -> --cri-socket (오타 수정)
kubeadm init --pod-network-cidr=$CIDR --cri-socket=unix:///var/run/crio/crio.sock

echo "[Step 8] kubeconfig 설정"
mkdir -p $HOME/.kube
cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config

# ==========================================
# 4. Helm 및 Cilium 설치
# ==========================================
echo "[Step 9] Helm 설치"
# [수정됨] echo 줄바꿈 제거 (Malformed entry 해결) 및 공식 Repo 사용
curl https://baltocdn.com/helm/signing.asc | gpg --dearmor | tee /usr/share/keyrings/helm.gpg > /dev/null
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/helm.gpg] https://baltocdn.com/helm/stable/debian/ all main" | \
    tee /etc/apt/sources.list.d/helm-stable-debian.list

apt-get update
apt-get install -y helm

echo "[Step 10] Cilium CLI 설치"
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
CLI_ARCH=amd64
if [ "$(uname -m)" = "aarch64" ]; then CLI_ARCH=arm64; fi

# [수정됨] URL 오타 수정 (ciliumcli -> cilium-cli) 및 tar 문법 수정
echo "Downloading Cilium CLI..."
curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
sha256sum --check cilium-linux-${CLI_ARCH}.tar.gz.sha256sum
sudo tar xzvf cilium-linux-${CLI_ARCH}.tar.gz -C /usr/local/bin
rm cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}

echo "[Step 11] Cilium 설치 (Helm Chart)"
# CLI install 명령어 대신 Helm을 권장하나, 요청하신 CLI 방식도 가능합니다.
# 여기서는 안정적인 버전 설치를 위해 버전을 명시합니다.
cilium install --version ${CILIUM_VERSION}

# Cilium 상태 확인
echo "Cilium 상태 확인 중..."
cilium status --wait

# ==========================================
# 5. 마무리
# ==========================================
echo "[Step 12] kubectl 편의 설정"
source /usr/share/bash-completion/bash_completion
echo 'source <(kubectl completion bash)' >> ~/.bashrc
echo 'alias k=kubectl' >> ~/.bashrc
echo 'complete -F __start_kubectl k' >> ~/.bashrc

echo "[완료] 시스템을 재시작하거나 'source ~/.bashrc' 명령어로 bash 환경을 갱신하세요."
