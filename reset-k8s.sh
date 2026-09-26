#!/bin/bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "[ERROR] root 권한으로 실행하세요."
    echo "sudo ./reset-k8s.sh"
    exit 1
fi

echo "=========================================="
echo " Kubernetes / CRI-O / Cilium 초기화 시작"
echo "=========================================="

# ------------------------------------------------------------
# Step 1. Cilium 제거
# ------------------------------------------------------------
echo "[Step 1] Cilium 제거"

if command -v cilium >/dev/null 2>&1; then
    if kubectl get nodes >/dev/null 2>&1; then
        cilium uninstall || true
    fi
fi


# ------------------------------------------------------------
# Step 2. kubeadm reset
# ------------------------------------------------------------
echo "[Step 2] kubeadm reset"

if command -v kubeadm >/dev/null 2>&1; then
    kubeadm reset -f \
        --cri-socket=unix:///var/run/crio/crio.sock || true
fi


# ------------------------------------------------------------
# Step 3. 서비스 중지
# ------------------------------------------------------------
echo "[Step 3] kubelet / CRI-O 중지"

systemctl stop kubelet 2>/dev/null || true
systemctl stop crio 2>/dev/null || true

systemctl disable kubelet 2>/dev/null || true
systemctl disable crio 2>/dev/null || true


# ------------------------------------------------------------
# Step 4. APT hold 해제
# ------------------------------------------------------------
echo "[Step 4] Kubernetes package hold 해제"

apt-mark unhold \
    kubelet \
    kubeadm \
    kubectl 2>/dev/null || true


# ------------------------------------------------------------
# Step 5. Package 제거
# ------------------------------------------------------------
echo "[Step 5] Kubernetes / CRI-O / Helm 제거"

apt-get purge -y \
    kubelet \
    kubeadm \
    kubectl \
    cri-o \
    cri-tools \
    kubernetes-cni \
    helm || true

apt-get autoremove --purge -y


# ------------------------------------------------------------
# Step 6. Kubernetes 데이터 제거
# ------------------------------------------------------------
echo "[Step 6] Kubernetes 데이터 제거"

rm -rf /etc/kubernetes
rm -rf /var/lib/kubelet
rm -rf /var/lib/etcd

rm -rf /etc/cni/net.d
rm -rf /var/lib/cni

rm -rf /var/run/kubernetes


# ------------------------------------------------------------
# Step 7. CRI-O 데이터/설정 제거
# ------------------------------------------------------------
echo "[Step 7] CRI-O 설정 제거"

rm -rf /etc/crio
rm -rf /var/lib/crio
rm -rf /var/run/crio
rm -rf /run/crio


# ------------------------------------------------------------
# Step 8. Cilium 상태 제거
# ------------------------------------------------------------
echo "[Step] Cilium cgroup mount 정리"

if mountpoint -q /run/cilium/cgroupv2; then
    echo "Cilium cgroupv2 mount 발견 - unmount"
    umount /run/cilium/cgroupv2 2>/dev/null || \
        umount -l /run/cilium/cgroupv2
fi

# Cilium 상태 제거
rm -rf /run/cilium
rm -rf /var/lib/cilium
rm -rf /etc/cilium

# Cilium network interface 제거
ip link delete cilium_host 2>/dev/null || true
ip link delete cilium_net 2>/dev/null || true
ip link delete cilium_vxlan 2>/dev/null || true

# ------------------------------------------------------------
# Step 9. kubeconfig 제거
# ------------------------------------------------------------
echo "[Step 9] kubeconfig 제거"

rm -rf "${HOME}/.kube"


# ------------------------------------------------------------
# Step 10. Repository 제거
# ------------------------------------------------------------
echo "[Step 10] 기존 Repository 제거"

rm -f /etc/apt/sources.list.d/kubernetes.list
rm -f /etc/apt/sources.list.d/cri-o.list
rm -f /etc/apt/sources.list.d/helm-stable-debian.list

rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
rm -f /etc/apt/keyrings/cri-o-apt-keyring.gpg
rm -f /usr/share/keyrings/helm.gpg


# ------------------------------------------------------------
# Step 11. Kernel / sysctl 설정 제거
# ------------------------------------------------------------
echo "[Step 11] Kubernetes kernel 설정 제거"

rm -f /etc/modules-load.d/k8s.conf
rm -f /etc/sysctl.d/k8s.conf

sysctl --system >/dev/null || true


# ------------------------------------------------------------
# Step 12. bash completion 설정 제거
# ------------------------------------------------------------
echo "[Step 12] kubectl alias / completion 제거"

if [ -f "${HOME}/.bashrc" ]; then
    sed -i '\|source <(kubectl completion bash)|d' "${HOME}/.bashrc"
    sed -i '\|alias k=kubectl|d' "${HOME}/.bashrc"
    sed -i '\|complete -F __start_kubectl k|d' "${HOME}/.bashrc"
    sed -i '\|complete -o default -F __start_kubectl k|d' "${HOME}/.bashrc"
fi


# ------------------------------------------------------------
# Step 13. APT 갱신
# ------------------------------------------------------------
echo "[Step 13] apt update"

apt-get update


echo ""
echo "=========================================="
echo " 초기화 완료"
echo "=========================================="
echo ""
echo "이제 reboot 하는 것을 권장합니다."
echo ""
echo "sudo reboot"
