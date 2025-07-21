# Kubernetes_Installer_with_CRIO
현재 사용하는 tool 및 version들은 다음과 같습니다.
- Kubernetes:v1.33
- CRI:CRI-O(v1.33)
- CNI: Flannel

현재 CRI-O 및 Kubernetes 사용 Version은 1.33으로 이를 바꾸기 위해서는 스크립트 파일에 들어가 다음을 원하는 버전으로 바꿔야 합니다.
```
KUBERNETES_VERSION="v1.33"
CRIO_VERSION="v1.33"
```
또한 다음 스크립트 파일은 Root 계정으로 실행해야 합니다.
```
sudo su -
``` 
## 사용 방법
파일 다운
```
git clone https://github.com/GProjectdev/Kubernetes_Installer_with_CRIO.git
```

권한부여
```
chmod +x ./Kubernetes_Installer_with_CRIO/setup-k8s.sh
```

파일 실행
```
sudo ./Kubernetes_Installer_with_CRIO/setup-k8s.sh
```

## Master Node 설정이기에 해당 Node에 Pod를 배포하기 위해서는 다음을 진행해야 합니다.
```
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
```
