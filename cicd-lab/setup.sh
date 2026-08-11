#!/usr/bin/env bash
# Sobe o "lab dentro do lab": Forgejo + Jenkins (Kubernetes plugin + Kaniko)
# + um app real (demo-app) com pipeline de CI/CD completo — push no
# Forgejo dispara o Jenkins sozinho, que testa, builda, publica no
# registry do próprio Forgejo e faz o deploy, tudo dentro do cluster KIND
# já existente.
#
# Pré-requisito: a infra base do repo já está de pé (../setup.sh rodado
# antes — cluster, MetalLB, NFS, Gateway API).
#
# Idempotente na maior parte (helm upgrade --install, kubectl apply), mas
# alguns passos (criar repo/token/job/webhook via API) já checam se o
# recurso existe antes de tentar criar de novo.
#
# Uso: ./setup.sh

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

GATEWAY_IP=$(kubectl get svc -n default -l gateway.networking.k8s.io/gateway-name=nginx-gateway \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}')
if [ -z "$GATEWAY_IP" ]; then
  echo "Gateway não encontrado — rode ../setup.sh primeiro (infra base do repo)." >&2
  exit 1
fi
echo "Gateway em ${GATEWAY_IP}"

FORGEJO_USER="forgejo_admin"
FORGEJO_PASS="TrocarAntesDeUsar123!"
FORGEJO_HOST="forgejo.gateway.local"
CLUSTER_NAME="$(grep '^name:' ../cluster.yaml | awk '{print $2}')"

curl_forgejo() { curl -s -u "${FORGEJO_USER}:${FORGEJO_PASS}" -H "Host: ${FORGEJO_HOST}" "$@"; }
curl_jenkins() { curl -s -u "admin:${JENKINS_PASS}" -H "Host: jenkins.gateway.local" "$@"; }

# ---------------------------------------------------------------------
echo "== 1. Forgejo =="
kubectl create ns forgejo --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install forgejo oci://code.forgejo.org/forgejo-helm/forgejo \
  -f forgejo/values.yaml --namespace forgejo
kubectl wait --timeout=180s -n forgejo --for=condition=Ready pod -l app=forgejo
# httpRoute.enabled=true no values.yaml já faz o chart criar o HTTPRoute
# sozinho — não precisa de um manifest separado.

# Sem client_max_body_size maior, um push de imagem Docker (blobs de
# dezenas de MB) trava no Gateway com "413 Request Entity Too Large".
kubectl apply -f forgejo/client-settings-policy.yaml

echo "== 2. DNS interno pro hostname público (Forgejo, MetalLB, containerd) =="
# O registry do Forgejo usa autenticação por token (padrão OCI): o
# servidor de auth redireciona pro ROOT_URL configurado
# (http://forgejo.gateway.local/, porta 80 implícita). Isso significa que
# TANTO os Pods (Kaniko) QUANTO os nodes do KIND (kubelet puxando a
# imagem depois) precisam resolver esse hostname — e ele só existe de
# verdade no /etc/hosts de quem grava o vídeo, não dentro do cluster.
# Resolve com uma entrada fixa no CoreDNS (Pods) + /etc/hosts em cada node
# (containerd), ambos apontando pro Gateway — não pro ClusterIP do
# Forgejo direto, porque o ROOT_URL não tem porta (80), e é só o Gateway
# que escuta nela.
kubectl get configmap coredns -n kube-system -o jsonpath='{.data.Corefile}' > /tmp/coredns-corefile
if ! grep -q "${FORGEJO_HOST}" /tmp/coredns-corefile; then
  python3 - "$GATEWAY_IP" "$FORGEJO_HOST" << 'PYEOF'
import sys
gateway_ip, host = sys.argv[1], sys.argv[2]
with open("/tmp/coredns-corefile") as f:
    content = f.read()
hosts_block = f"    hosts {{\n       {gateway_ip} {host}\n       fallthrough\n    }}\n"
content = content.replace("    prometheus :9153\n", "    prometheus :9153\n" + hosts_block)
with open("/tmp/coredns-corefile.new", "w") as f:
    f.write(content)
PYEOF
  kubectl create configmap coredns -n kube-system --from-file=Corefile=/tmp/coredns-corefile.new \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl rollout restart deployment/coredns -n kube-system
  kubectl rollout status deployment/coredns -n kube-system --timeout=60s
fi

for node in $(docker ps --filter "label=io.x-k8s.kind.cluster=${CLUSTER_NAME}" --format '{{.Names}}'); do
  docker exec "$node" sh -c "grep -v ${FORGEJO_HOST} /etc/hosts > /tmp/hosts.new && cat /tmp/hosts.new > /etc/hosts && echo '${GATEWAY_IP} ${FORGEJO_HOST}' >> /etc/hosts"
  docker exec "$node" mkdir -p "/etc/containerd/certs.d/${FORGEJO_HOST}"
  docker exec "$node" sh -c "cat > /etc/containerd/certs.d/${FORGEJO_HOST}/hosts.toml << EOF
server = \"http://${FORGEJO_HOST}\"

[host.\"http://${FORGEJO_HOST}\"]
  capabilities = [\"pull\", \"resolve\", \"push\"]
EOF"
  docker exec "$node" systemctl restart containerd
  echo "  $node ajustado"
done

echo "== 3. Repositório demo-app no Forgejo =="
if ! curl_forgejo "http://${GATEWAY_IP}/api/v1/repos/${FORGEJO_USER}/demo-app" -o /dev/null -w '%{http_code}' | grep -q 200; then
  curl_forgejo -X POST "http://${GATEWAY_IP}/api/v1/user/repos" \
    -H "Content-Type: application/json" \
    -d '{"name":"demo-app","description":"App do lab de CI/CD","private":false,"auto_init":false}' >/dev/null
fi

echo "== 4. Manifests do deploy alvo (namespace cicd-demo) =="
kubectl apply -f manifests/namespace.yaml
kubectl apply -f manifests/deployment.yaml
kubectl apply -f manifests/service.yaml
kubectl apply -f manifests/httproute.yaml
kubectl apply -f manifests/rbac-binding.yaml
kubectl wait --timeout=60s -n cicd-demo --for=condition=Available deployment/demo-app

echo "== 5. Credenciais do registry (push do Kaniko + pull do kubelet) =="
kubectl create ns jenkins --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret docker-registry forgejo-registry-creds \
  --docker-server="${FORGEJO_HOST}" --docker-username="${FORGEJO_USER}" \
  --docker-password="${FORGEJO_PASS}" --docker-email="admin@homelab.local" \
  -n jenkins --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic jenkins-forgejo-creds -n jenkins \
  --from-literal=username="${FORGEJO_USER}" --from-literal=password="${FORGEJO_PASS}" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret docker-registry forgejo-registry-creds \
  --docker-server="${FORGEJO_HOST}" --docker-username="${FORGEJO_USER}" \
  --docker-password="${FORGEJO_PASS}" --docker-email="admin@homelab.local" \
  -n cicd-demo --dry-run=client -o yaml | kubectl apply -f -
kubectl patch serviceaccount default -n cicd-demo \
  -p '{"imagePullSecrets": [{"name": "forgejo-registry-creds"}]}' >/dev/null

echo "== 6. Jenkins =="
kubectl apply -f jenkins/rbac-deployer.yaml
helm repo add jenkins https://charts.jenkins.io >/dev/null
helm repo update jenkins >/dev/null
helm upgrade --install jenkins jenkins/jenkins -f jenkins/values.yaml --namespace jenkins
kubectl wait --timeout=300s -n jenkins --for=condition=Ready pod/jenkins-0
kubectl apply -f jenkins/httproute.yaml

JENKINS_PASS=$(kubectl exec --namespace jenkins svc/jenkins -c jenkins -- \
  /bin/cat /run/secrets/additional/chart-admin-password 2>/dev/null)
COOKIEJAR=$(mktemp)

# Todos os plugins (kubernetes, configuration-as-code, git, gitea,
# workflow-aggregator, credentials-binding) já vêm declarados em
# jenkins/values.yaml (installPlugins) — nada instalado depois via API.
echo "  conferindo se os plugins subiram certo..."
for i in $(seq 1 30); do
  READY=$(curl_jenkins "http://${GATEWAY_IP}/pluginManager/api/json?depth=1&tree=plugins[shortName]" \
    | jq -r '[.plugins[].shortName] | contains(["git","gitea","workflow-aggregator","credentials-binding","kubernetes","configuration-as-code"])')
  [ "$READY" = "true" ] && break
  sleep 5
done

echo "== 7. Push do demo-app pro Forgejo =="
rm -rf /tmp/demo-app-push
cp -r demo-app /tmp/demo-app-push
cd /tmp/demo-app-push
git init -q -b main
git config user.email "admin@homelab.local"
git config user.name "${FORGEJO_USER}"
git add .
git commit -q -m "deploy inicial via setup.sh" --allow-empty
git remote add origin "http://${FORGEJO_USER}:${FORGEJO_PASS}@${GATEWAY_IP}/${FORGEJO_USER}/demo-app.git"
git -c http.extraHeader="Host: ${FORGEJO_HOST}" push -f origin main
cd - >/dev/null

echo "== 8. Job Pipeline no Jenkins =="
if ! curl_jenkins -o /dev/null -w '%{http_code}' "http://${GATEWAY_IP}/job/demo-app/api/json" | grep -q 200; then
  cat > /tmp/job-config.xml << EOF
<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job">
  <description>Pipeline do demo-app (cicd-lab)</description>
  <keepDependencies>false</keepDependencies>
  <definition class="org.jenkinsci.plugins.workflow.cps.CpsScmFlowDefinition" plugin="workflow-cps">
    <scm class="hudson.plugins.git.GitSCM" plugin="git">
      <configVersion>2</configVersion>
      <userRemoteConfigs>
        <hudson.plugins.git.UserRemoteConfig>
          <url>http://forgejo-http.forgejo.svc.cluster.local:3000/${FORGEJO_USER}/demo-app.git</url>
          <credentialsId>forgejo-creds</credentialsId>
        </hudson.plugins.git.UserRemoteConfig>
      </userRemoteConfigs>
      <branches>
        <hudson.plugins.git.BranchSpec><name>*/main</name></hudson.plugins.git.BranchSpec>
      </branches>
      <doGenerateSubmoduleConfigurations>false</doGenerateSubmoduleConfigurations>
      <submoduleCfg class="empty-list"/>
      <extensions/>
    </scm>
    <scriptPath>Jenkinsfile</scriptPath>
    <lightweight>true</lightweight>
  </definition>
  <triggers>
    <hudson.triggers.SCMTrigger>
      <spec></spec>
      <ignorePostCommitHooks>false</ignorePostCommitHooks>
    </hudson.triggers.SCMTrigger>
  </triggers>
  <disabled>false</disabled>
</flow-definition>
EOF
  CRUMB=$(curl_jenkins -c "$COOKIEJAR" "http://${GATEWAY_IP}/crumbIssuer/api/json" | jq -r .crumb)
  curl -s -b "$COOKIEJAR" -u "admin:${JENKINS_PASS}" -H "Host: jenkins.gateway.local" -H "Jenkins-Crumb: $CRUMB" \
    -X POST "http://${GATEWAY_IP}/createItem?name=demo-app" \
    -H "Content-Type: application/xml" --data-binary @/tmp/job-config.xml >/dev/null
fi

echo "== 9. Token do git-plugin pro notifyCommit + webhook no Forgejo =="
CRUMB=$(curl_jenkins -c "$COOKIEJAR" "http://${GATEWAY_IP}/crumbIssuer/api/json" | jq -r .crumb)
NOTIFY_TOKEN=$(curl -s -b "$COOKIEJAR" -u "admin:${JENKINS_PASS}" -H "Host: jenkins.gateway.local" -H "Jenkins-Crumb: $CRUMB" \
  --data-urlencode 'script=
def cfg = hudson.plugins.git.ApiTokenPropertyConfiguration.get()
def existing = cfg.getApiTokens().find { it.name == "forgejo-notifycommit" }
if (existing) { println existing.value } else {
  def tok = cfg.generateApiToken("forgejo-notifycommit")
  cfg.save()
  println tok.value
}
' -X POST "http://${GATEWAY_IP}/scriptText" | tail -1)

WEBHOOK_URL="http://jenkins.jenkins.svc.cluster.local:8080/git/notifyCommit?url=http://forgejo-http.forgejo.svc.cluster.local:3000/${FORGEJO_USER}/demo-app.git&token=${NOTIFY_TOKEN}"
HOOK_ID=$(curl_forgejo "http://${GATEWAY_IP}/api/v1/repos/${FORGEJO_USER}/demo-app/hooks" | jq -r '.[0].id // empty')
if [ -z "$HOOK_ID" ]; then
  curl_forgejo -X POST "http://${GATEWAY_IP}/api/v1/repos/${FORGEJO_USER}/demo-app/hooks" \
    -H "Content-Type: application/json" \
    -d "{\"type\":\"gitea\",\"config\":{\"url\":\"${WEBHOOK_URL}\",\"content_type\":\"json\"},\"events\":[\"push\"],\"active\":true}" >/dev/null
else
  curl_forgejo -X PATCH "http://${GATEWAY_IP}/api/v1/repos/${FORGEJO_USER}/demo-app/hooks/${HOOK_ID}" \
    -H "Content-Type: application/json" \
    -d "{\"config\":{\"url\":\"${WEBHOOK_URL}\",\"content_type\":\"json\"}}" >/dev/null
fi
rm -f "$COOKIEJAR"

echo
echo "Lab de CI/CD no ar."
echo "  Forgejo:  http://forgejo.gateway.local (usuário: ${FORGEJO_USER})"
echo "  Jenkins:  http://jenkins.gateway.local (usuário: admin / senha: ${JENKINS_PASS})"
echo "  demo-app: http://demo-app.gateway.local"
echo
echo "Pra ver funcionando: edite cicd-lab/demo-app/app.py, dê commit+push no"
echo "repo em /tmp/demo-app-push (ou clone http://forgejo.gateway.local/${FORGEJO_USER}/demo-app.git)"
echo "e o pipeline dispara sozinho."