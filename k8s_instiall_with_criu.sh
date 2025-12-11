#!/bin/bash
set -e

# ==============================
# 버전 설정 (실제 존재하는 버전으로 조정 필요할 수 있음)
# ==============================
KUBERNETES_VERSION="v1.33"
CRIO_VERSION="v1.33"
POD_CIDR="10.85.0.0/16"

# ==============================
# Step 1. 기본 패키지
# ==============================
echo "[Step 1] 필수 패키지 설치"
apt-get update
apt-get install -y \
  software-properties-common \
  curl \
  gnupg2 \
  bash-completion \
  ca-certificates \
  lsb-release

mkdir -p /etc/apt/keyrings

# ==============================
# Step 2. Kubernetes APT 저장소
# ==============================
echo "[Step 2] Kubernetes APT 저장소 등록"

curl -fsSL https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/Release.key \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list

# ==============================
# Step 3. CRI-O APT 저장소
# ==============================
echo "[Step 3] CRI-O APT 저장소 등록"

curl -fsSL https://download.opensuse.org/repositories/isv:/cri-o:/stable:/${CRIO_VERSION}/deb/Release.key \
  | gpg --dearmor -o /etc/apt/keyrings/cri-o-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/cri-o-apt-keyring.gpg] https://download.opensuse.org/repositories/isv:/cri-o:/stable:/${CRIO_VERSION}/deb/ /" \
  > /etc/apt/sources.list.d/cri-o.list

# ==============================
# Step 4. Kubernetes + CRI-O 설치
# ==============================
echo "[Step 4] Kubernetes 및 CRI-O 설치"

apt-get update
apt-get install -y \
  cri-o \
  kubelet \
  kubeadm \
  kubectl

# kubelet 자동 시작 방지 (kubeadm init 전에)
systemctl disable kubelet || true
systemctl stop kubelet || true

# ==============================
# Step 5. CRI-O 기본 서비스 시작
# ==============================
echo "[Step 5] CRI-O 서비스 시작 (기본)"

systemctl daemon-reexec
systemctl enable crio
systemctl restart crio

# ==============================
# Step 6. 네트워크 / 커널 설정
# ==============================
echo "[Step 6] Swap 및 커널 설정"

swapoff -a

modprobe br_netfilter || true

cat <<EOF >/etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF

sysctl --system

# ==============================
# Step 7. CRIU, runc 및 CRI-O CRIU 지원 설정
# ==============================
echo "[Step 7] CRIU, runc 및 CRI-O CRIU 지원 설정"

# runc 설치 (crun 대신 runc 사용)
apt-get install -y runc

# CRIU 설치 (ppa:criu/ppa)
add-apt-repository -y ppa:criu/ppa
apt-get update
apt-get install -y criu

# CRIU 설정 파일 (/etc/criu/runc.conf)
mkdir -p /etc/criu
cat <<EOF >/etc/criu/runc.conf
tcp-established
log-file /tmp/criu.log
skip-in-flight
EOF

# CRI-O 추가 의존 패키지 + 빌드용 패키지
apt-get install -y \
  build-essential \
  protobuf-compiler \
  podman \
  pkg-config \
  libbtrfs-dev \
  libgpgme-dev \
  libnftables-dev \
  nano \
  vim \
  nfs-common \
  git \
  make \
  asciidoctor \
  buildah

# CRI-O CRIU 설정 드롭인 생성
# - default_runtime = "runc"
# - enable_criu_support = true
# - 이미지 signature 검증 임시 비활성화 (restore 시 서명 문제 회피)
cat <<EOF >/etc/crio/crio.conf.d/99-criu.conf
[crio.runtime]
default_runtime = "runc"
enable_criu_support = true

[crio.image]
#signature_policy = ""
EOF

# CRI-O 재시작
systemctl restart crio

# ==============================
# Step 8. Go 1.24.4 설치 (필수 버전 강제)
# ==============================
echo "[Step 8] Go 1.24.4 설치 중..."

GO_VERSION="1.24.4"
GO_TAR="go${GO_VERSION}.linux-amd64.tar.gz"

# 기존 Go 삭제
rm -rf /usr/local/go
apt-get remove -y golang-go || true
snap remove go || true

# Go 다운로드 및 설치
curl -L -o /tmp/${GO_TAR} https://go.dev/dl/${GO_TAR}
tar -C /usr/local -xzf /tmp/${GO_TAR}

# PATH 설정
if ! grep -q "export PATH=\$PATH:/usr/local/go/bin" ~/.bashrc ; then
  echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc
fi

export PATH=$PATH:/usr/local/go/bin

echo "[Go 설치 완료] 버전:"
go version

# ==============================
# Step 9. checkpointctl 설치
# ==============================
echo "[Step 9] checkpointctl 설치"

if [ ! -d /tmp/checkpointctl ]; then
  git clone https://github.com/checkpoint-restore/checkpointctl.git /tmp/checkpointctl
fi

cd /tmp/checkpointctl
make
make install
cd -

# ==============================
# Step 10. kubelet에 ContainerCheckpoint feature-gate 활성화
# ==============================
echo "[Step 10] kubelet에 ContainerCheckpoint feature-gate 설정"

cat <<EOF >/etc/default/kubelet
KUBELET_EXTRA_ARGS="--feature-gates=ContainerCheckpoint=true"
EOF

systemctl daemon-reload
systemctl restart crio

# kubelet은 kubeadm init 후 systemd가 다시 관리하게 됨

# ==============================
# Step 11. kubeadm init
# ==============================
echo "[Step 11] kubeadm 초기화"

kubeadm init \
  --pod-network-cidr=${POD_CIDR} \
  --cri-socket=unix:///var/run/crio/crio.sock

# ==============================
# Step 12. kubeconfig 설정
# ==============================
echo "[Step 12] kubeconfig 설정"

mkdir -p "$HOME/.kube"
cp -i /etc/kubernetes/admin.conf "$HOME/.kube/config"
chown "$(id -u)":"$(id -g)" "$HOME/.kube/config"

export KUBECONFIG=$HOME/.kube/config

# ==============================
# Step 13. Helm 설치
# ==============================
echo "[Step 13] Helm 설치"

apt-get install -y curl gpg apt-transport-https

curl -fsSL https://packages.buildkite.com/helm-linux/helm-debian/gpgkey \
  | gpg --dearmor | tee /usr/share/keyrings/helm.gpg > /dev/null

echo "deb [signed-by=/usr/share/keyrings/helm.gpg] https://packages.buildkite.com/helm-linux/helm-debian/any/ any main" \
  | tee /etc/apt/sources.list.d/helm-stable-debian.list

apt-get update
apt-get install -y helm

# ==============================
# Step 14. Cilium CLI 설치
# ==============================
echo "[Step 14] Cilium CLI 설치"

CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
CLI_ARCH=amd64
if [ "$(uname -m)" = "aarch64" ]; then
  CLI_ARCH=arm64
fi

curl -L --fail --remote-name-all \
  https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}

sha256sum --check cilium-linux-${CLI_ARCH}.tar.gz.sha256sum
tar xzvf cilium-linux-${CLI_ARCH}.tar.gz -C /usr/local/bin
rm cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}

# ==============================
# Step 15. Cilium CNI 설치
# ==============================
echo "[Step 15] Cilium CNI 설치"

cilium install --version 1.18.2
cilium status --wait

# ==============================
# Step 16. kubectl bash-completion 및 alias
# ==============================
echo "[Step 16] kubectl bash-completion 및 alias 설정"

source /usr/share/bash-completion/bash_completion || true
{
  echo 'source <(kubectl completion bash)'
  echo 'alias k=kubectl'
  echo 'complete -F __start_kubectl k'
} >> ~/.bashrc

echo "[완료] 노드 재부팅 후 'source ~/.bashrc'를 실행하면 편합니다."
echo "[참고] 이제 CRI-O + CRIU 기반 ContainerCheckpoint 기능을 사용할 수 있습니다."
