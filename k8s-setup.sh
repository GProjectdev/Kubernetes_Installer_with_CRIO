#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# Kubernetes Install Script (Kubeadm + CRI-O + Cilium)
#
# Target OS: Ubuntu/Debian based systems
# Role: Single Control Plane setup
# Security: Enforces Root verification, strict error handling, dependency checks
# ==============================================================================

trap 'echo "[오류] ${LINENO}번째 줄에서 실패: ${BASH_COMMAND}" >&2' ERR

APT_GET=(apt-get -o Dpkg::Lock::Timeout=120 -o Acquire::Retries=3)

DEFAULT_K8S_VER="${DEFAULT_K8S_VER:-v1.35}"
CILIUM_VERSION="${CILIUM_VERSION:-1.18.6}"
CIDR="${CIDR:-10.85.0.0/16}"

MODE="all"
REQUESTED_STEP=""
SELECTED_START=0
SELECTED_END=0

STEP_NUMBERS=(1 2 3 4 5 6 7 8)
STEP_NAMES=(
  system-prep
  apt-repos
  install-packages
  init-cluster
  kubeconfig
  install-helm
  install-cilium
  shell-config
)
STEP_TITLES=(
  "시스템 설정 (의존성, 스왑, 모듈, Sysctl)"
  "APT 저장소 구성"
  "패키지 설치 (CRI-O, Kubeadm, Kubelet, Kubectl)"
  "Kubernetes 클러스터 초기화"
  "kubeconfig 설정"
  "Helm 설치"
  "Cilium 설치"
  "쉘 편의 설정"
)
STEP_FUNCS=(
  step_system_prep
  step_apt_repos
  step_install_packages
  step_init_cluster
  step_kubeconfig
  step_install_helm
  step_install_cilium
  step_shell_config
)

usage() {
  cat <<'EOF'
사용법:
  sudo ./k8s-setup.sh
  sudo ./k8s-setup.sh --all
  sudo ./k8s-setup.sh --list-steps
  sudo ./k8s-setup.sh --step <number|name>
  sudo ./k8s-setup.sh --from-step <number|name>

예시:
  sudo ./k8s-setup.sh --step 3
  sudo ./k8s-setup.sh --step install-packages
  sudo ./k8s-setup.sh --from-step init-cluster
EOF
}

list_steps() {
  local i
  for i in "${!STEP_NAMES[@]}"; do
    printf "%s  %-16s %s\n" "${STEP_NUMBERS[$i]}" "${STEP_NAMES[$i]}" "${STEP_TITLES[$i]}"
  done
}

normalize_step() {
  local selector="${1//_/-}"
  local i

  for i in "${!STEP_NAMES[@]}"; do
    if [ "${selector}" = "${STEP_NUMBERS[$i]}" ] || [ "${selector}" = "${STEP_NAMES[$i]}" ]; then
      echo "$i"
      return 0
    fi
  done

  echo "[오류] 알 수 없는 단계입니다: $1" >&2
  echo "사용 가능한 단계:" >&2
  list_steps >&2
  echo ""
  return 0
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --all)
        MODE="all"
        REQUESTED_STEP=""
        shift
        ;;
      --list-steps)
        MODE="list"
        shift
        ;;
      --step)
        if [ "$#" -lt 2 ]; then
          echo "[오류] --step에는 단계 번호 또는 이름이 필요합니다." >&2
          usage >&2
          exit 1
        fi
        MODE="step"
        REQUESTED_STEP="$2"
        shift 2
        ;;
      --from-step)
        if [ "$#" -lt 2 ]; then
          echo "[오류] --from-step에는 단계 번호 또는 이름이 필요합니다." >&2
          usage >&2
          exit 1
        fi
        MODE="from-step"
        REQUESTED_STEP="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "[오류] 알 수 없는 옵션입니다: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
  done
}

select_steps() {
  local last_index=$(( ${#STEP_NAMES[@]} - 1 ))
  local step_index

  case "${MODE}" in
    all)
      SELECTED_START=0
      SELECTED_END="${last_index}"
      ;;
    step)
      step_index="$(normalize_step "${REQUESTED_STEP}")"
      if [ -z "${step_index}" ]; then
        exit 1
      fi
      SELECTED_START="${step_index}"
      SELECTED_END="${step_index}"
      ;;
    from-step)
      step_index="$(normalize_step "${REQUESTED_STEP}")"
      if [ -z "${step_index}" ]; then
        exit 1
      fi
      SELECTED_START="${step_index}"
      SELECTED_END="${last_index}"
      ;;
    list)
      list_steps
      exit 0
      ;;
  esac
}

selected_contains() {
  local name="$1"
  local i

  for ((i=SELECTED_START; i<=SELECTED_END; i++)); do
    if [ "${STEP_NAMES[$i]}" = "${name}" ]; then
      return 0
    fi
  done

  return 1
}

require_root() {
  if [ "$EUID" -ne 0 ]; then
    echo "[오류] 이 스크립트는 root 권한으로 실행해야 합니다." >&2
    echo "사용법: sudo -i 후 이 스크립트를 실행하세요." >&2
    exit 1
  fi
}

check_kernel_version() {
  CURRENT_KERNEL_FULL=$(uname -r)
  CURRENT_KERNEL_MAIN=$(echo "$CURRENT_KERNEL_FULL" | cut -d- -f1)
  MIN_KERNEL="5.10"

  if dpkg --compare-versions "$CURRENT_KERNEL_MAIN" lt "$MIN_KERNEL"; then
    echo "[오류] Cilium 1.18.x는 Linux Kernel ${MIN_KERNEL} 이상이 필요합니다." >&2
    echo "        현재 커널: $CURRENT_KERNEL_MAIN ($CURRENT_KERNEL_FULL)" >&2
    echo "        커널 업그레이드 후 다시 시도하세요." >&2
    exit 1
  fi
}

preflight() {
  require_root
  umask 022
  check_kernel_version

  if selected_contains init-cluster; then
    if [ -f "/etc/kubernetes/admin.conf" ] || [ -d "/var/lib/etcd" ]; then
      echo "[오류] 기존 Kubernetes 구성이 감지되었습니다." >&2
      echo "감지된 경로: /etc/kubernetes/admin.conf 또는 /var/lib/etcd" >&2
      echo "클러스터 초기화 단계 실행 전에 'kubeadm reset' 또는 수동 정리를 먼저 수행하세요." >&2
      exit 1
    fi
  fi
}

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

validate_k8s_version() {
  if [[ ! "${KUBERNETES_VERSION}" =~ ^v1\.[0-9]{2}$ ]]; then
    echo "[오류] 버전 형식이 잘못되었습니다: ${KUBERNETES_VERSION}. v1.XX 형식(예: v1.35)으로 입력하세요." >&2
    exit 1
  fi
}

collect_k8s_version() {
  local latest_k8s_ver user_input

  if ! latest_k8s_ver="$(get_latest_k8s_minor_version)"; then
    latest_k8s_ver="${DEFAULT_K8S_VER}"
    echo "[경고] 최신 Kubernetes 안정 버전 조회에 실패하여 ${DEFAULT_K8S_VER}를 사용합니다." >&2
  fi

  echo "============================================================"
  echo " Kubernetes 설치 설정"
  echo "============================================================"

  if [ -n "${KUBERNETES_VERSION:-}" ]; then
    if [[ "${KUBERNETES_VERSION}" != v* ]]; then
      KUBERNETES_VERSION="v${KUBERNETES_VERSION}"
    fi
  else
    echo -n "설치할 Kubernetes 버전을 입력하세요 (예: v1.35) [기본값: ${latest_k8s_ver}]: "
    read -r user_input

    if [ -z "${user_input}" ]; then
      KUBERNETES_VERSION="${latest_k8s_ver}"
    elif [[ "${user_input}" != v* ]]; then
      KUBERNETES_VERSION="v${user_input}"
    else
      KUBERNETES_VERSION="${user_input}"
    fi
  fi

  validate_k8s_version
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
}

print_selected_steps() {
  local i
  echo "실행할 단계:"
  for ((i=SELECTED_START; i<=SELECTED_END; i++)); do
    printf " - %s (%s): %s\n" "${STEP_NUMBERS[$i]}" "${STEP_NAMES[$i]}" "${STEP_TITLES[$i]}"
  done
  echo "3초 후 시작합니다... (취소: Ctrl+C)"
  sleep 3
  echo ""
}

require_file() {
  local path="$1"
  local message="$2"

  if [ ! -f "${path}" ]; then
    echo "[오류] ${message}: ${path}" >&2
    exit 1
  fi
}

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

  if ! gpg --dearmor --yes -o "${out}" "${tmp}"; then
    rm -f "${tmp}" "${out}"
    echo "[오류] 키링 변환에 실패했습니다: ${out}" >&2
    exit 1
  fi

  rm -f "${tmp}"
  chmod 644 "${out}"
}

add_bash_config() {
  local target_file="$1"
  [ -f "${target_file}" ] || return 0

  if ! grep -q "### K8S-SETUP-START" "${target_file}"; then
    cat <<'EOF' >> "${target_file}"

### K8S-SETUP-START
source <(kubectl completion bash)
alias k=kubectl
complete -F __start_kubectl k
### K8S-SETUP-END
EOF
  else
    echo " > Bash 설정이 이미 존재합니다: ${target_file}"
  fi
}

step_system_prep() {
  echo "[1단계] 시스템 설정 (의존성, 스왑, 모듈, Sysctl)"
  export DEBIAN_FRONTEND=noninteractive

  "${APT_GET[@]}" update
  "${APT_GET[@]}" install -y --no-install-recommends \
    software-properties-common curl gnupg2 bash-completion \
    apt-transport-https ca-certificates \
    conntrack socat iproute2 iptables ebtables

  if grep -q "swap" /etc/fstab; then
    echo " > /etc/fstab의 swap을 비활성화합니다 (백업: /etc/fstab.bak)"
    sed -ri.bak '/\sswap\s/s/^/#/' /etc/fstab
  fi
  swapoff -a

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
}

step_apt_repos() {
  echo "[2단계] APT 저장소 구성"
  : "${KUBERNETES_VERSION:?KUBERNETES_VERSION is required}"
  : "${CRIO_VERSION:?CRIO_VERSION is required}"

  install -d -m 0755 /etc/apt/keyrings

  download_key \
    "https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/Release.key" \
    "/etc/apt/keyrings/kubernetes-apt-keyring.gpg"

  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/ /" \
    > /etc/apt/sources.list.d/kubernetes.list

  download_key \
    "https://download.opensuse.org/repositories/isv:/cri-o:/stable:/${CRIO_VERSION}/deb/Release.key" \
    "/etc/apt/keyrings/cri-o-apt-keyring.gpg"

  echo "deb [signed-by=/etc/apt/keyrings/cri-o-apt-keyring.gpg] https://download.opensuse.org/repositories/isv:/cri-o:/stable:/${CRIO_VERSION}/deb/ /" \
    > /etc/apt/sources.list.d/cri-o.list
}

step_install_packages() {
  echo "[3단계] 패키지 설치 (CRI-O, Kubeadm, Kubelet, Kubectl)"

  require_file "/etc/apt/sources.list.d/kubernetes.list" "Kubernetes APT 저장소가 없습니다. 먼저 apt-repos 단계를 실행하세요"
  require_file "/etc/apt/sources.list.d/cri-o.list" "CRI-O APT 저장소가 없습니다. 먼저 apt-repos 단계를 실행하세요"

  "${APT_GET[@]}" update
  "${APT_GET[@]}" install -y --no-install-recommends cri-o kubelet kubeadm kubectl
  apt-mark hold cri-o kubelet kubeadm kubectl

  systemctl daemon-reload
  systemctl enable --now crio
}

step_init_cluster() {
  echo "[4단계] Kubernetes 클러스터 초기화"

  if [ -f "/etc/kubernetes/admin.conf" ] || [ -d "/var/lib/etcd" ]; then
    echo "[오류] 기존 Kubernetes 구성이 감지되어 클러스터 초기화를 중단합니다." >&2
    exit 1
  fi

  if ! systemctl is-active --quiet crio; then
    echo "[오류] CRI-O 서비스가 활성 상태가 아닙니다. 먼저 install-packages 단계를 확인하세요." >&2
    exit 1
  fi

  kubeadm init --pod-network-cidr="${CIDR}" --cri-socket=unix:///var/run/crio/crio.sock

  echo " > API 서버 준비 상태를 확인합니다..."
  export KUBECONFIG=/etc/kubernetes/admin.conf

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
}

step_kubeconfig() {
  echo "[5단계] kubeconfig 설정"

  require_file "/etc/kubernetes/admin.conf" "kubeconfig 원본이 없습니다. 먼저 init-cluster 단계를 실행하세요"

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
}

step_install_helm() {
  echo "[6단계] Helm 설치"

  curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
  chmod 700 get_helm.sh
  ./get_helm.sh
  rm get_helm.sh
}

step_install_cilium() {
  echo "[7단계] Cilium 설치"

  require_file "/etc/kubernetes/admin.conf" "Cilium 설치에 필요한 kubeconfig가 없습니다. 먼저 init-cluster/kubeconfig 단계를 실행하세요"
  export KUBECONFIG=/etc/kubernetes/admin.conf

  CILIUM_CLI_VERSION=$(curl -fsSL https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
  CLI_ARCH=amd64
  if [ "$(uname -m)" = "aarch64" ]; then CLI_ARCH=arm64; fi

  echo " > Cilium CLI ${CILIUM_CLI_VERSION} 다운로드 중..."
  curl -L --fail --remote-name-all \
    "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz"{,.sha256sum}
  sha256sum --check "cilium-linux-${CLI_ARCH}.tar.gz.sha256sum"
  tar xzvf "cilium-linux-${CLI_ARCH}.tar.gz" -C /usr/local/bin
  rm "cilium-linux-${CLI_ARCH}.tar.gz" "cilium-linux-${CLI_ARCH}.tar.gz.sha256sum"

  echo " > Cilium CNI 설치 중 (버전: ${CILIUM_VERSION}, ipam.mode=kubernetes)..."
  cilium install --version "${CILIUM_VERSION}" \
    --helm-set ipam.mode=kubernetes

  echo " > Cilium 상태를 확인합니다..."
  cilium status --wait
}

step_shell_config() {
  echo "[8단계] 쉘 편의 설정"

  add_bash_config "$HOME/.bashrc"

  if [ -n "${SUDO_USER:-}" ]; then
    USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    USER_GID=$(id -gn "$SUDO_USER")

    if [ -f "$USER_HOME/.bashrc" ]; then
      add_bash_config "$USER_HOME/.bashrc"
      chown "$SUDO_USER:$USER_GID" "$USER_HOME/.bashrc"
    fi
  fi
}

run_selected_steps() {
  local i

  for ((i=SELECTED_START; i<=SELECTED_END; i++)); do
    "${STEP_FUNCS[$i]}"
    echo ""
  done
}

print_completion() {
  echo "============================================================"
  if [ "${MODE}" = "all" ]; then
    echo " [설치가 완료되었습니다]"
  else
    echo " [선택한 단계 실행이 완료되었습니다]"
  fi
  echo "============================================================"
  echo " 1. 쉘 다시 불러오기:  source ~/.bashrc"
  echo " 2. 노드 확인:        kubectl get nodes"
  echo " 3. 파드 확인:        kubectl get pods -A"
  echo "============================================================"
}

main() {
  parse_args "$@"
  select_steps
  preflight

  if selected_contains apt-repos; then
    collect_k8s_version
  fi

  print_selected_steps
  run_selected_steps
  print_completion
}

main "$@"
