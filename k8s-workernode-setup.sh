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
