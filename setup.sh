#!/usr/bin/env bash
# Sobe toda a infra do homelab, na mesma ordem e com os mesmos comandos
# documentados no README (seções 0 a 6): rede Docker fixa, cluster KIND,
# MetalLB, NFS (server + provisioner), Gateway API (CRDs + NGINX Gateway
# Fabric + Gateway) e um HTTPRoute de exemplo (whoami) pra provar que o
# roteamento funciona de ponta a ponta. Idempotente: pode rodar de novo,
# pula/atualiza o que já existe em vez de dar erro.
#
# NÃO inclui o deploy final do Snake Classic (apps/snake-classic/) — esse
# depende de clonar e buildar uma imagem externa, é um passo à parte
# (ver README seção 7).
#
# Variáveis opcionais:
#   SUBNET  (default 172.20.0.0/16) — subnet da rede Docker 'kind'
#   GATEWAY (default 172.20.0.1)    — gateway dessa rede
# Se mudar SUBNET, o pool do MetalLB em loadbalancer/metallb-config.yaml
# precisa ser ajustado manualmente pra bater (ver README seção 0).
#
# Uso: ./setup.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

SUBNET="${SUBNET:-172.20.0.0/16}"
GATEWAY="${GATEWAY:-172.20.0.1}"
CLUSTER_NAME="$(grep '^name:' cluster.yaml | awk '{print $2}')"
NETWORK_NAME="kind"

echo "== 0. Rede Docker fixa =="
if docker network ls --format '{{.Name}}' | grep -qx "${NETWORK_NAME}"; then
  echo "rede '${NETWORK_NAME}' já existe, pulando."
else
  docker network create --subnet="${SUBNET}" --gateway="${GATEWAY}" "${NETWORK_NAME}"
fi

echo "== 1. Cluster KIND '${CLUSTER_NAME}' =="
if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  echo "cluster '${CLUSTER_NAME}' já existe, pulando."
else
  kind create cluster --config cluster.yaml
fi

echo "== 2. MetalLB =="
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.9/config/manifests/metallb-native.yaml
kubectl wait --namespace metallb-system --for=condition=ready pod -l app=metallb --timeout=120s
kubectl wait --namespace metallb-system --for=condition=ready pod -l component=speaker --timeout=90s
kubectl apply -f loadbalancer/metallb-config.yaml

echo "== 3. NFS server (container Docker) =="
docker compose -f nfs/nfs-server-compose.yaml up -d
NFS_IP="$(docker inspect nfs-server --format '{{.NetworkSettings.Networks.kind.IPAddress}}')"
echo "nfs-server em ${NFS_IP}"

echo "== 4. NFS client provisioner =="
helm repo add nfs https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner
helm repo update
kubectl create ns nfs-provisioner --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install nfs-provisioner nfs/nfs-subdir-external-provisioner \
    --namespace nfs-provisioner \
    --set nfs.server="${NFS_IP}" \
    --set nfs.path="/" \
    --set storageClass.name=nfs-client \
    --set storageClass.defaultClass=true

echo "== 6.1 Gateway API: CRDs (standard channel) =="
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.1/standard-install.yaml

echo "== 6.2 NGINX Gateway Fabric =="
kubectl create ns nginx-gateway --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install ngf oci://ghcr.io/nginx/charts/nginx-gateway-fabric --namespace nginx-gateway
kubectl wait --timeout=5m -n nginx-gateway deployment/ngf-nginx-gateway-fabric --for=condition=Available

echo "== 6.3 Gateway =="
kubectl apply -f gateway-api/gateway.yaml
kubectl wait --timeout=90s -n default --for=condition=Programmed gateway/nginx-gateway

echo "== 6.4 HTTPRoute de exemplo (whoami) =="
kubectl apply -f gateway-api/httproute-demo.yaml
kubectl wait --timeout=90s -n default --for=condition=Available deployment/demo-app

GATEWAY_IP="$(kubectl get svc -n default -l gateway.networking.k8s.io/gateway-name=nginx-gateway \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}')"

echo
echo "Infra no ar. Gateway em ${GATEWAY_IP}"
echo "Teste:   curl -H \"Host: demo.gateway.local\" http://${GATEWAY_IP}/"
echo "Deploy final (Snake Classic): ver README seção 7, ou apps/snake-classic/."
echo "Pra derrubar tudo depois: ./cleanup.sh"
