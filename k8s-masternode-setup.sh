#!/bin/bash
set -e

# 버전 설정 (실제 존재하는 버전으로 변경 필요할 수 있음)
KUBERNETES_VERSION="v1.33"
CRIO_VERSION="v1.33"

# 사전 준비
echo "[Step 1] 필수 패키지 설치"
apt-get update
apt-get install -y software-properties-common curl gnupg2 bash-completion

# APT 키 디렉토리 생성
mkdir -p /etc/apt/keyrings

echo "[Step 2] Kubernetes APT 저장소 등록"
curl -fsSL https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/Release.key \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list

echo "[Step 3] CRI-O APT 저장소 등록"
curl -fsSL https://download.opensuse.org/repositories/isv:/cri-o:/stable:/${CRIO_VERSION}/deb/Release.key \
  | gpg --dearmor -o /etc/apt/keyrings/cri-o-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/cri-o-apt-keyring.gpg] https://download.opensuse.org/repositories/isv:/cri-o:/stable:/${CRIO_VERSION}/deb/ /" \
  > /etc/apt/sources.list.d/cri-o.list

echo "[Step 4] Kubernetes 및 CRI-O 설치"
apt-get update
apt-get install -y cri-o kubelet kubeadm kubectl

echo "[Step 5] CRI-O 서비스 시작"
systemctl daemon-reexec
systemctl enable crio
systemctl start crio

echo "[Step 6] Swap 및 커널 설정"
swapoff -a
modprobe br_netfilter
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.bridge.bridge-nf-call-iptables=1

cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF
sysctl --system

echo "[Step 7] kubeadm 초기화"
export CIDR=10.85.0.0/16
kubeadm init --pod-network-cidr=$CIDR --cri-socket=unix:///var/run/crio/crio.sock

echo "[Step 8] kubeconfig 설정"
mkdir -p "$HOME/.kube"
cp -i /etc/kubernetes/admin.conf "$HOME/.kube/config"
chown "$(id -u)":"$(id -g)" "$HOME/.kube/config"

echo "[Step 9] Helm 및 Cilium 설치"

# Helm 설치
sudo apt-get install curl gpg apt-transport-https --yes
curl -fsSL https://packages.buildkite.com/helm-linux/helm-debian/gpgkey \
  | gpg --dearmor | sudo tee /usr/share/keyrings/helm.gpg > /dev/null

echo "deb [signed-by=/usr/share/keyrings/helm.gpg] https://packages.buildkite.com/helm-linux/helm-debian/any/ any main" \
  | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list

sudo apt-get update
sudo apt-get install -y helm

# Cilium CLI 설치
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
CLI_ARCH=amd64
if [ "$(uname -m)" = "aarch64" ]; then CLI_ARCH=arm64; fi

curl -L --fail --remote-name-all \
  https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}

sha256sum --check cilium-linux-${CLI_ARCH}.tar.gz.sha256sum
sudo tar xzvf cilium-linux-${CLI_ARCH}.tar.gz -C /usr/local/bin
rm cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}

# Cilium 설치
cilium install --version 1.18.2

# Cilium 설치 확인
cilium status --wait

echo "[Step 10] kubectl bash-completion 및 alias 설정"
source /usr/share/bash-completion/bash_completion
echo 'source <(kubectl completion bash)' >> ~/.bashrc
echo 'alias k=kubectl' >> ~/.bashrc
echo 'complete -F __start_kubectl k' >> ~/.bashrc

echo "[완료] 시스템을 재시작하거나 'source ~/.bashrc' 명령어로 bash 환경을 갱신하세요."
