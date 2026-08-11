#!/usr/bin/env bash
# Derruba só o "lab dentro do lab" (Forgejo + Jenkins + demo-app/cicd-demo),
# sem mexer na infra base do repo (cluster, MetalLB, NFS, Gateway API) —
# pra isso, use o ../cleanup.sh na raiz.
#
# Uso: ./cleanup.sh

set -uo pipefail

echo "== Removendo Jenkins =="
helm uninstall jenkins -n jenkins 2>/dev/null || echo "release jenkins não existe, pulando."
kubectl delete ns jenkins --ignore-not-found

echo "== Removendo Forgejo =="
helm uninstall forgejo -n forgejo 2>/dev/null || echo "release forgejo não existe, pulando."
kubectl delete ns forgejo --ignore-not-found

echo "== Removendo cicd-demo =="
kubectl delete ns cicd-demo --ignore-not-found

rm -rf /tmp/demo-app-push

echo
echo "cicd-lab limpo. A config de registry inseguro nos nodes do KIND (containerd)"
echo "fica pra trás — inofensiva, e some sozinha se o cluster inteiro for recriado"
echo "(../cleanup.sh + ../setup.sh)."