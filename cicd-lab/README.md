# CI/CD Lab — Forgejo + Jenkins (lab dentro do lab)

Continuação do homelab principal ([`../README.md`](../README.md)): em cima do
cluster KIND + MetalLB + NFS + Gateway API que já existe, sobe um fluxo de
CI/CD completo — **Forgejo** (Git + registry de containers) e **Jenkins**
(Kubernetes plugin + Kaniko), com um app real (`demo-app`) que vai do
`git push` até estar rodando de novo, sozinho, sem comando manual.

## Por que Forgejo (não Gitea)

Forgejo é um fork do Gitea (2024, liderado pela Codeberg) por preocupação
de governança — a mesma razão que fez o próprio Gitea nascer como fork do
Gogs em 2016. Pronuncia-se **/forˈd͡ʒe.jo/** ("for-DJÊ-iô"), do esperanto
*forĝejo* = "forja".

Além do lado da história, tem argumento técnico direto: o chart Helm do
Forgejo já nasce mais enxuto — SQLite, cache/sessão em memória, fila em
"level" e `Recreate` como padrão de fábrica, sem nenhum dos ajustes manuais
que o chart do Gitea exige. E tem suporte nativo a `HTTPRoute` (Gateway
API) embutido no próprio chart — nem precisa de um manifest separado.

## Pré-requisito

A infra base do repo já precisa estar de pé:

```bash
cd ..
./setup.sh
```

## Arquitetura

```mermaid
flowchart TB
    dev(["você"]) -->|git push| forgejo["Forgejo<br/>(repo git + registry OCI)"]
    forgejo -->|webhook: notifyCommit| jenkins["Jenkins controller"]
    jenkins -->|sobe 1 Pod agente por build| agent["Pod agente<br/>containers: python / kaniko / kubectl"]
    agent -->|1 - pytest| agent
    agent -->|"2 - kaniko build + push"| forgejo
    agent -->|"3 - kubectl set image"| deploy["Deployment demo-app<br/>(namespace cicd-demo)"]
    deploy --> route["HTTPRoute"] --> gw["Gateway compartilhado<br/>(mesmo do resto do repo)"]
    gw -->|"HTTP"| dev
```

Cada build do Jenkins sobe **um Pod novo** (Kubernetes plugin), com 3
containers que dividem o mesmo workspace: `python` (roda o `pytest`),
`kaniko` (builda a imagem e publica no registry do Forgejo — sem Docker
socket, roda em userspace) e `kubectl` (atualiza o Deployment já existente
em `cicd-demo`). O Pod morre no final do build.

Forgejo e Jenkins ganham `HTTPRoute` próprios (o do Forgejo é criado pelo
próprio chart), apontando pro mesmo `Gateway` que o resto do repo usa
(`gateway-api/gateway.yaml`) — por isso o `gateway.yaml` da raiz precisou de
um ajuste (`allowedRoutes.namespaces.from: All`), já que cada peça daqui
vive no seu próprio namespace (`forgejo`, `jenkins`, `cicd-demo`), diferente
do resto do repo que ficava tudo em `default`.

**Todo o tráfego do registry (push do Kaniko, pull do kubelet) passa pelo
mesmo `forgejo.gateway.local`, pelo mesmo Gateway** — não existe um "atalho
interno" separado. Isso é proposital: o registry OCI do Forgejo usa
autenticação por token, e o servidor de auth redireciona sempre pro
`ROOT_URL` configurado. Então `forgejo.gateway.local` precisa resolver de
verdade *dentro* do cluster também (não só no seu `/etc/hosts` de fora) —
o `setup.sh` cuida disso com uma entrada fixa no CoreDNS (pros Pods) e no
`/etc/hosts` de cada node do KIND (pro containerd).

## Instalação

```bash
./setup.sh
```

O script automatiza os passos abaixo (deploy do Forgejo, DNS interno,
ajuste de containerd nos nodes, deploy do Jenkins com os plugins certos,
credenciais, job, webhook). Se preferir entender/rodar cada pedaço
manualmente, os comandos estão comentados dentro dele na mesma ordem — ou
veja o `roteiro.md` (gitignorado, é material de gravação) pra uma versão
passo a passo com explicação de cada manifest.

Depois de rodar, adicione ao seu `/etc/hosts` (troque pelo IP real do
Gateway, `kubectl get svc -n default -l gateway.networking.k8s.io/gateway-name=nginx-gateway`):

```
<IP_DO_GATEWAY> forgejo.gateway.local jenkins.gateway.local demo-app.gateway.local
```

## Testando o fluxo completo

```bash
git clone http://forgejo_admin:TrocarAntesDeUsar123!@forgejo.gateway.local/forgejo_admin/demo-app.git
cd demo-app
# edita algo em app.py (ex: o valor de APP_VERSION)
git add app.py
git commit -m "teste"
git push
```

Sem rodar mais nada: o Forgejo chama o Jenkins (webhook), o Jenkins builda,
testa, publica a imagem no registry do próprio Forgejo e atualiza o
Deployment. Confira:

```bash
kubectl get pods -n jenkins -w        # aparece um Pod agente novo
curl -H "Host: demo-app.gateway.local" http://<IP_DO_GATEWAY>/
```

## O que quebrou (e por quê) — vale saber antes de gravar

Nada aqui funcionou de primeira. Documentando porque são pegadinhas reais
de rodar Forgejo/Jenkins num homelab Kubernetes, não erro de configuração
bobo — bom material pro vídeo também.

1. **SQLite + LevelDB não toleram 2 Pods rodando ao mesmo tempo** — o
   `RollingUpdate` padrão sobe o Pod novo antes de matar o velho, e os dois
   brigam pelo lock do banco/fila. O chart do Forgejo já usa `Recreate` de
   fábrica — não precisou mexer, mas vale saber o porquê (foi o primeiro
   ajuste manual que tivemos que fazer quando essa infra ainda era Gitea).

2. **`kubectl set image` só troca a imagem, nunca `args`/`command`** — o
   Deployment "alvo" (`manifests/deployment.yaml`) não pode usar um
   placeholder que dependa de argumentos customizados (tentamos
   `hashicorp/http-echo` com `-listen=:8080`; quebrou assim que a imagem
   virou o `demo-app` de verdade, que não entende esse "comando"). Fix:
   placeholder sem `args` (`nginx:alpine`, porta 80 — mesma porta que o
   `demo-app` usa).

3. **O `kubelet` também precisa de credencial pra puxar do registry
   privado** (não só o Kaniko pra fazer push) — `imagePullSecrets` na
   ServiceAccount `default` do namespace `cicd-demo`, senão vira
   `ImagePullBackOff`.

4. **Container `bitnami/kubectl` roda non-root (UID 1001) por padrão**,
   diferente dos outros containers do Pod agente (root) — sem permissão de
   escrever no workspace compartilhado, o step trava numa espera **sem
   nenhum erro visível** (o script nem consegue gravar o próprio resultado
   de erro). Fix: `securityContext.runAsUser: 0` só nesse container.

5. **O plugin `gitea` do Jenkins só dispara build automático em jobs
   Multibranch/Organization Folder** (via `GiteaSCMSource`) — não em
   Pipeline simples (`Pipeline script from SCM` com `GitSCM` comum, que é
   o nosso caso; o plugin funciona igual pro Forgejo, é o mesmo protocolo
   de webhook herdado do fork). Fix: usar o mecanismo universal do
   git-plugin (`/git/notifyCommit?url=...&token=...`), que funciona com
   qualquer job baseado em `GitSCM`. O token vem de "Manage Jenkins →
   Configure Global Security → Git plugin" (ou via script console, como o
   `setup.sh` faz).

6. **Webhook bloqueado por proteção anti-SSRF** — por padrão só deixa
   webhook chamar hosts "públicos", bloqueando a chamada interna pro
   Jenkins (`webhook can only call allowed HTTP servers`). No Gitea essa
   chave é `security.ALLOWED_HOST_LIST`; **no Forgejo migrou pra
   `webhook.ALLOWED_HOST_LIST`** — a mensagem de erro deixa isso claro
   (`check your webhook.ALLOWED_HOST_LIST setting`), mas custou um teste a
   mais pra descobrir que não era a mesma chave do Gitea.

7. **O registry OCI usa autenticação por token, e o realm de auth
   redireciona pro `ROOT_URL`** — não pro endereço que o cliente usou pra
   conectar. Isso significa que usar o ClusterIP do Forgejo direto (o que
   funcionava sem problema no Gitea) quebra a autenticação do Kaniko: ele
   conecta no IP, recebe o desafio 401, tenta seguir o redirect de auth
   pra `forgejo.gateway.local` — que não existe no DNS do cluster. Fix:
   `forgejo.gateway.local` precisa resolver *dentro* do cluster também —
   entrada fixa no CoreDNS (pros Pods) e no `/etc/hosts` de cada node (pro
   containerd), **apontando pro Gateway** (não pro ClusterIP do Forgejo:
   o `ROOT_URL` não declara porta, então assume 80 — só o Gateway escuta
   nela).

8. **Depois de resolver o DNS, o push travava com "413 Request Entity Too
   Large"** — o NGINX Gateway Fabric tem um limite padrão de tamanho de
   corpo de requisição, e um blob de imagem Docker (dezenas de MB) passa
   disso fácil. Fix: um `ClientSettingsPolicy` (CRD do NGINX Gateway
   Fabric) no `Gateway` inteiro, com `body.maxSize: "0"` (desliga a
   checagem).

## Limpeza

```bash
./cleanup.sh
```

Derruba só Forgejo/Jenkins/cicd-demo — a infra base do repo continua de pé
(`../cleanup.sh` pra derrubar tudo). O `cleanup.sh` **não** desfaz a
entrada de DNS no CoreDNS nem o `/etc/hosts` dos nodes — são inofensivos
(só resolvem um hostname a mais) e somem sozinhos se o cluster inteiro for
recriado.
