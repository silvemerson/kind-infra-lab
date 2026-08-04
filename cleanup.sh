#!/usr/bin/env bash
# Derruba tudo que os passos do README criam FORA do cluster Kubernetes:
# o cluster KIND em si, o container do NFS e a rede Docker fixa (seção 0).
# Idempotente: pode rodar de novo mesmo que só parte da infra exista.
#
# Uso: ./cleanup.sh

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

CLUSTER_NAME="$(grep '^name:' cluster.yaml | awk '{print $2}')"
NETWORK_NAME="kind"

echo "== Derrubando cluster KIND '${CLUSTER_NAME}' =="
if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  kind delete cluster --name "${CLUSTER_NAME}"
else
  echo "cluster '${CLUSTER_NAME}' não existe, pulando."
fi

echo "== Derrubando container do NFS =="
docker compose -f nfs/nfs-server-compose.yaml down

echo "== Removendo rede Docker '${NETWORK_NAME}' =="
if docker network ls --format '{{.Name}}' | grep -qx "${NETWORK_NAME}"; then
  docker network rm "${NETWORK_NAME}"
else
  echo "rede '${NETWORK_NAME}' não existe, pulando."
fi

echo
echo "Infra limpa. A pasta nfs/nfs-data (dados do NFS) foi mantida de propósito."
echo "Pra recriar tudo do zero, siga o README a partir da seção 0."
