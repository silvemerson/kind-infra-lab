# KIND + MetalLB + Nginx + NFS


## Pré-requisitos KIND + MetalLB + NGINX + NFS

| Componente                            | Versão Recomendada      | Link Oficial                                                                 | Observações                                               |
|-------------------------------------|------------------------|-----------------------------------------------------------------------------|-----------------------------------------------------------|
| **Kind**                            | v0.20.0 ou superior    | [https://kind.sigs.k8s.io/](https://kind.sigs.k8s.io/)                      | Ferramenta para criar clusters Kubernetes locais.         |
| **kubectl**                        | v1.27.x ou superior     | [https://kubernetes.io/docs/tasks/tools/](https://kubernetes.io/docs/tasks/tools/) | CLI para controlar clusters Kubernetes.                   |
| **MetalLB**                        | v0.14.9 ou superior    | [https://metallb.universe.tf/](https://metallb.universe.tf/)                | LoadBalancer para clusters bare-metal e Kind.             |
| **NGINX Ingress Controller**       | v1.9.1 ou superior     | [https://kubernetes.github.io/ingress-nginx/](https://kubernetes.github.io/ingress-nginx/) | Controlador Ingress para roteamento HTTP/HTTPS.          |
| **Helm**                          | v3.12.0 ou superior    | [https://helm.sh/](https://helm.sh/)                                        | Gerenciador de pacotes para Kubernetes.                    |
| **NFS Server (Docker container)** | Qualquer versão estável | [https://nfs-utils.sourceforge.net/](https://nfs-utils.sourceforge.net/)    | NFS server rodando em container Docker para armazenamento compartilhado. |
| **NFS Client Provisioner**          | v4.0.13 ou superior    | [https://github.com/kubernetes-sigs/nfs-subdir-external-provisioner](https://github.com/kubernetes-sigs/nfs-subdir-external-provisioner) | Provisionador dinâmico para PVCs usando NFS.              |
         |


### 1. KIND 

Crie seu cluster local com KIND usando o arquivo de configuração customizado cluster.yaml. Este arquivo define a rede e recursos do cluster.

```kind create cluster --config cluster.yaml```

### 2. MetalLB

MetalLB permitirá que seu cluster KIND tenha IPs de LoadBalancer, já que KIND não tem isso nativamente.

```kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.9/config/manifests/metallb-native.yaml```


Crie um arquivo loadbalancer/metallb-config.yaml com o seguinte conteúdo, ajustando o range IP para sua rede KIND:

```yaml

apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: kind-pool
  namespace: metallb-system
spec:
  addresses:
  - 172.18.0.240-172.18.0.250  # intervalo seguro fora dos IPs dos nodes
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: l2
  namespace: metallb-system
```
```kubectl apply -f loadbalancer/metallb-config.yaml```

Altere de acordo com o range de IP do Kind



### 3. Nginx

Crie o namespace dedicado e instale o ingress NGINX, expondo o serviço como LoadBalancer para receber tráfego externo:

```bash
kubectl create namespace ingress-nginx
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --set controller.service.type=LoadBalancer


```

### 4. NFS

Use um arquivo nfs-server-compose.yaml para criar um container Docker com servidor NFS, que será usado para armazenamento compartilhado.

Inicie o container:

```docker compose -f nfs/nfs-server-compose.yaml up -d```


### 5. NFS client

Esse provisionador vai permitir que PersistentVolumeClaims (PVCs) criem volumes automaticamente no servidor NFS.

```bash
helm repo add nfs https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner
helm repo update
kubectl create ns nfs-provisioner
helm upgrade --install nfs-provisioner nfs/nfs-subdir-external-provisioner \
    --namespace nfs-provisioner \
    --set nfs.server=172.18.0.5 \
    --set nfs.path="/" \
    --set storageClass.name=nfs-client \
    --set storageClass.defaultClass=true
```

### 6. Testar Integração do NFS com Kubernetes

Crie namespace de teste e aplique um PVC para validar se o provisionador está funcionando:

```bash
kubectl create ns test-nfs
kubectl apply -f nfs/pvc-nfs-test.yaml
kubectl get pvc -n test-nfs

```