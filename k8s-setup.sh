#!/bin/bash
set -e

# 버전 설정
KUBERNETES_VERSION="v1.33"
CRIO_VERSION="v1.33"

# 사전 준비
echo "[Step 1] 필수 패키지 설치"
apt-get update
apt-get install -y software-properties-common curl gnupg2 bash-completion

# APT 키 디렉토리 생성
mkdir -p /etc/apt/keyrings

echo "[Step 2] Kubernetes APT 저장소 등록"
curl -fsSL https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/Release.key |
    gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/ /" \
    > /etc/apt/sources.list.d/kubernetes.list

echo "[Step 3] CRI-O APT 저장소 등록"
curl -fsSL https://download.opensuse.org/repositories/isv:/cri-o:/stable:/${CRIO_VERSION}/deb/Release.key |
    gpg --dearmor -o /etc/apt/keyrings/cri-o-apt-keyring.gpg

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

# sysctl 설정을 지속적으로 적용하려면 아래도 추가 가능
cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF
sysctl --system

echo "[Step 7] kubeadm 초기화"
kubeadm init --pod-network-cidr=10.244.0.0/16

echo "[Step 8] kubeconfig 설정"
mkdir -p $HOME/.kube
cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config

echo "[Step 9] Flannel CNI 설치"
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

echo "[Step 10] kubectl bash-completion 및 alias 설정"
source /usr/share/bash-completion/bash_completion
echo 'source <(kubectl completion bash)' >> ~/.bashrc
echo 'alias k=kubectl' >> ~/.bashrc
echo 'complete -F __start_kubectl k' >> ~/.bashrc

echo "[완료] 시스템을 재시작하거나 'source ~/.bashrc' 명령어로 bash 환경을 갱신하세요."
