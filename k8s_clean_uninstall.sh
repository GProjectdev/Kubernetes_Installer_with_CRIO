#!/bin/bash

# ==============================================================================
# Script Name: k8s_clean_uninstall.sh
# Description: Safely uninstalls Kubernetes from the node.
#              Prioritizes Safety & Zero Side Effects.
#              DESTRUCTIVE OPERATIONS ARE FLAGGED (Opt-in).
# Author: DevOps Engineer (Antigravity)
# Updated: Final Robust Version (Specific Guards, Strict Args, Package Logic)
# ==============================================================================

# Definite Colors for Output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ==============================================================================
# Flags & Defaults (ALL DESTRUCTIVE OPTIONS DEFAULT TO FALSE)
# ==============================================================================
CLEANUP_CNI=false       # Removes CNI interfaces & /etc/cni/net.d
CLEANUP_ETCD=false      # Removes /var/lib/etcd
DO_AUTOREMOVE=false     # Runs apt-get autoremove

# Argument Parsing
for arg in "$@"; do
    case $arg in
        --cleanup-cni) CLEANUP_CNI=true ;;
        --cleanup-etcd) CLEANUP_ETCD=true ;;
        --autoremove) DO_AUTOREMOVE=true ;;
        --help) 
            echo "사용법: sudo $0 [옵션]"
            echo "옵션:"
            echo "  --cleanup-cni    CNI 네트워크 인터페이스 및 설정(/etc/cni/net.d) 삭제"
            echo "  --cleanup-etcd   etcd 데이터 디렉터리(/var/lib/etcd) 삭제"
            echo "  --autoremove     패키지 관리자 autoremove 실행(미사용 의존성 제거)"
            exit 0
            ;;
        *) 
            echo -e "${RED}[오류] 알 수 없는 옵션입니다: $arg${NC}"
            echo "--help로 사용법을 확인하세요."
            exit 1 
            ;;
    esac
done

echo -e "${BLUE}[정보] Kubernetes 정리 제거 스크립트를 시작합니다 (초안전 모드).${NC}"

# ==============================================================================
# 0. Safety Checks, Detection & Confirmation
# ==============================================================================
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[오류] 이 스크립트는 root 권한으로 실행해야 합니다. sudo를 사용하세요.${NC}"
  exit 1
fi

# Detect Kubernetes Traces (Guard for Network Cleanup)
# We check this BEFORE 'kubeadm reset' runs, as reset might clear some paths.
IS_K8S_DETECTED=false
if [ -d "/etc/kubernetes" ] || [ -d "/var/lib/kubelet" ] || systemctl list-unit-files --no-legend 2>/dev/null | grep -E -q '^kubelet\.service'; then
    IS_K8S_DETECTED=true
fi

echo -e "${RED}[경고] 이 스크립트는 다음 Kubernetes 구성요소를 제거합니다:${NC}"
echo -e "  - 패키지: kubeadm, kubelet, kubectl, kubernetes-cni, cri-tools (설치된 경우만)"
echo -e "  - 설정: /etc/kubernetes, /var/lib/kubelet"
echo -e "  - 바이너리: kubeadm, kubectl, kubelet (명시된 경로만)"

# Status Report
echo -e "\n${BLUE}[설정 상태]${NC}"
if [ "$CLEANUP_ETCD" = true ]; then
    echo -e "  - Etcd 데이터 (/var/lib/etcd): ${RED}삭제${NC}"
else
    echo -e "  - Etcd 데이터 (/var/lib/etcd): ${GREEN}유지 (--cleanup-etcd로 삭제)${NC}"
fi

if [ "$CLEANUP_CNI" = true ]; then
    echo -e "  - 네트워크 (CNI 인터페이스/설정): ${RED}삭제${NC}"
else
    echo -e "  - 네트워크 (CNI 인터페이스/설정): ${GREEN}유지 (--cleanup-cni로 삭제)${NC}"
fi

if [ "$DO_AUTOREMOVE" = true ]; then
    echo -e "  - 패키지 Autoremove: ${RED}예${NC}"
else
    echo -e "  - 패키지 Autoremove: ${GREEN}아니오 (--autoremove로 활성화)${NC}"
fi

read -p "정말 제거를 진행하시겠습니까? (y/N): " choice
case "$choice" in 
  y|Y ) echo -e "${GREEN}[정보] 사용자 확인됨. 제거를 진행합니다...${NC}";;
  * ) echo -e "${YELLOW}[정보] 사용자에 의해 작업이 취소되었습니다.${NC}"; exit 0;;
esac

# ==============================================================================
# 1. Service Drain & Reset
# ==============================================================================
echo -e "\n${BLUE}[1/5단계] Kubernetes 클러스터를 초기화합니다...${NC}"

# Robust check for kubelet service existence and state
if systemctl list-unit-files --no-legend 2>/dev/null | grep -E -q '^kubelet\.service'; then
    echo -e "kubelet.service를 찾아 중지 및 비활성화합니다..."
    systemctl stop kubelet
    systemctl disable kubelet
    systemctl reset-failed kubelet 2>/dev/null
else
    echo -e "${YELLOW}[정보] kubelet.service를 찾지 못해 중지/비활성화를 건너뜁니다.${NC}"
fi

# Execute kubeadm reset
if command -v kubeadm &> /dev/null; then
    echo -e "'kubeadm reset -f'를 실행합니다..."
    if kubeadm reset -f; then
        echo -e "${GREEN}[완료] kubeadm reset 실행 완료.${NC}"
    else
        echo -e "${RED}[경고] kubeadm reset 실패 또는 비정상 종료 코드 반환. 정리 작업은 계속 진행합니다...${NC}"
    fi
else
    echo -e "${YELLOW}[건너뜀] kubeadm 바이너리가 없어 reset 명령을 건너뜁니다.${NC}"
fi

# ==============================================================================
# 2. Package Purge (Install Check First)
# ==============================================================================
echo -e "\n${BLUE}[2/5단계] Kubernetes 패키지를 제거합니다...${NC}"

TARGET_PKGS="kubeadm kubectl kubelet kubernetes-cni cri-tools"
PKGS_TO_REMOVE=""

if command -v dpkg &> /dev/null; then
    # PRE-CHECK: only purge what is installed
    echo -e "apt/dpkg 기반 시스템(Debian/Ubuntu)을 감지했습니다."
    for pkg in $TARGET_PKGS; do
        if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
            PKGS_TO_REMOVE="$PKGS_TO_REMOVE $pkg"
        fi
    done
    
    if [ -n "$PKGS_TO_REMOVE" ]; then
        echo -e "설치된 패키지를 제거합니다: $PKGS_TO_REMOVE"
        apt-get purge -y $PKGS_TO_REMOVE
        
        if [ "$DO_AUTOREMOVE" = true ]; then
            echo -e "autoremove를 실행합니다..."
            apt-get autoremove -y
        fi
        echo -e "${GREEN}[완료] 패키지 처리 완료.${NC}"
    else
        echo -e "${YELLOW}[건너뜀] 제거 대상 Kubernetes 패키지가 설치되어 있지 않습니다.${NC}"
    fi

elif command -v rpm &> /dev/null; then
    # Determine Package Manager (dnf > yum)
    PKG_MGR="yum"
    if command -v dnf &> /dev/null; then
        PKG_MGR="dnf"
    fi
    echo -e "rpm 기반 시스템을 감지했습니다. 패키지 관리자: $PKG_MGR"

    for pkg in $TARGET_PKGS; do
        if rpm -q "$pkg" &> /dev/null; then
             PKGS_TO_REMOVE="$PKGS_TO_REMOVE $pkg"
        fi
    done

    if [ -n "$PKGS_TO_REMOVE" ]; then
        echo -e "설치된 패키지를 제거합니다: $PKGS_TO_REMOVE"
        $PKG_MGR remove -y $PKGS_TO_REMOVE
        echo -e "${GREEN}[완료] 패키지 처리 완료.${NC}"
    else
        echo -e "${YELLOW}[건너뜀] 제거 대상 Kubernetes 패키지가 설치되어 있지 않습니다.${NC}"
    fi
else
    echo -e "${RED}[오류] 지원하지 않는 패키지 관리자입니다.${NC}"
fi

# ==============================================================================
# 3. Network Cleanup (Opt-in + Guard)
# ==============================================================================
echo -e "\n${BLUE}[3/5단계] CNI 네트워크 인터페이스를 정리합니다...${NC}"

if [ "$CLEANUP_CNI" = true ]; then
    if [ "$IS_K8S_DETECTED" = true ]; then
        # Precision Mode List
        TARGET_INTERFACES="cni0 flannel.1 kube-ipvs0 weave antrea-gw0"
        SKIP_REGEX="^(lo|eth[0-9]+|en[opsx][0-9]+.*|wlan[0-9]+|docker0|virbr[0-9]+|br-.*|podman[0-9]+|cilium_.*)$"

        EXISTING_IFACES=$(ip -o link show | awk -F': ' '{print $2}' | cut -d'@' -f1)

        for iface in $EXISTING_IFACES; do
            if [[ "$iface" =~ $SKIP_REGEX ]]; then continue; fi

            MATCH=0
            for target in $TARGET_INTERFACES; do
                if [[ "$iface" == "$target" ]]; then MATCH=1; break; fi
            done

            if [ $MATCH -eq 1 ]; then
                echo -e "${YELLOW}네트워크 인터페이스 삭제: $iface${NC}"
                ip link set dev "$iface" down 2>/dev/null
                ip link delete "$iface" 2>/dev/null
            fi
        done
        
        # Clean /etc/cni/net.d
        if [ -d "/etc/cni/net.d" ]; then
            echo -e "CNI 설정 디렉터리 /etc/cni/net.d를 삭제합니다..."
            rm -rf /etc/cni/net.d
        fi
    else
        echo -e "${RED}[안전 차단] Kubernetes 흔적(kubelet/설정)을 찾지 못했습니다.${NC}"
        echo -e "${YELLOW}               비 Kubernetes 노드의 네트워크 손실 방지를 위해 인터페이스 삭제를 건너뜁니다.${NC}"
    fi
else
    echo -e "${YELLOW}[건너뜀] 네트워크 정리 및 /etc/cni/net.d 삭제는 기본값으로 비활성화되어 있습니다.${NC}"
    echo -e "${YELLOW}       Kubernetes 인터페이스/CNI 설정을 삭제하려면 --cleanup-cni 옵션을 사용하세요.${NC}"
fi

# ==============================================================================
# 4. Files Cleanup
# ==============================================================================
echo -e "\n${BLUE}[4/5단계] 설정 및 데이터 파일을 정리합니다...${NC}"

FILES_TO_REMOVE=(
    "/etc/kubernetes"
    "/var/lib/kubelet"
    "/var/lib/dockershim"
    "/var/run/kubernetes"
    "/etc/systemd/system/kubelet.service.d"
    "/usr/bin/kubeadm"
    "/usr/bin/kubectl"
    "/usr/bin/kubelet"
    "/usr/local/bin/kubeadm"
    "/usr/local/bin/kubectl"
    "/usr/local/bin/kubelet"
)

# Safe Etcd Removal (Opt-in)
if [ "$CLEANUP_ETCD" = true ]; then
    if [ -d "/var/lib/etcd" ]; then
        echo -e "/var/lib/etcd를 삭제합니다 (사용자 요청)..."
        rm -rf "/var/lib/etcd"
    else
        echo -e "${YELLOW}[정보] /var/lib/etcd를 찾지 못해 확인을 건너뜁니다.${NC}"
    fi
else
    if [ -d "/var/lib/etcd" ]; then
        echo -e "${YELLOW}[건너뜀] /var/lib/etcd가 존재하지만 기본값에 따라 보존합니다.${NC}"
        echo -e "${YELLOW}       삭제하려면 --cleanup-etcd 옵션을 사용하세요.${NC}"
    fi
fi

for target in "${FILES_TO_REMOVE[@]}"; do
    if [ -e "$target" ]; then
        echo -e "$target 삭제 중..."
        rm -rf "$target"
    fi 
done

# Clean root kubeconfig
if [ -d "/root/.kube" ]; then rm -rf /root/.kube; fi

# Clean SUDO_USER kubeconfig
if [ -n "$SUDO_USER" ]; then
    USER_HOME=$(eval echo "~$SUDO_USER")
    if [ -d "$USER_HOME/.kube" ]; then
        rm -rf "$USER_HOME/.kube"
    fi
fi

echo -e "\n${BLUE}[5/5단계] 마무리 작업 중...${NC}"
systemctl daemon-reload

echo -e "${GREEN}[완료] Kubernetes 제거가 완료되었습니다.${NC}"
echo -e "${YELLOW}[팁] 네트워크 상태까지 완전히 초기화하려면 재부팅을 권장합니다.${NC}"
