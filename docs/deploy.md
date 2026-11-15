# Azure 배포 절차

[README](../README.md)의 배포 흐름을 명령으로 옮긴 문서입니다. HorizonDB·AKS·Azure OpenAI·Managed Grafana를 만들고
카탈로그를 적재하기까지 약 90분이 걸리며 유료 자원을 쓰므로, 끝나면 [정리](#11-정리)합니다.

필요한 도구: Azure CLI(`horizondb` 확장), `kubectl`, `helm`, `envsubst`, `jq`, `psql` 15 이상, Python 3.

## 1. HorizonDB cluster

HorizonDB API `2026-10-01-preview`(Azure CLI `horizondb` 확장 1.0.0b9) 기준입니다.
cluster를 만든 뒤 pool, parameter group, 관리자 인증, 방화벽을 따로 만듭니다.

```bash
RG=rg-movielog-horizondb; LOC=koreacentral
HZ="<horizondb-cluster>"; ACR="<acr-name>"; AOAI="<openai-name>"; GRAFANA="<grafana-name>"
SID="$(az account show --query id -o tsv)"
RID="/subscriptions/$SID/resourceGroups/$RG/providers/Microsoft.HorizonDb"
API=api-version=2026-10-01-preview

az extension add --name horizondb
az group create -n $RG -l $LOC
az horizondb cluster create -g $RG -n "$HZ" -l $LOC --version 17 \
  --public-access Enabled --geo-redundancy Disabled

# Parameter group: extensions allowlist and AGE preload.
az rest --method put --uri "https://management.azure.com$RID/parameterGroups/pg-movielog-age?$API" --body \
  "{\"location\":\"$LOC\",\"properties\":{\"postgreSqlVersion\":\"17\",\"parameters\":[
    {\"name\":\"azure.extensions\",\"value\":\"vector,pg_diskann,age\"},
    {\"name\":\"shared_preload_libraries\",\"value\":\"age\"}]}}"

# Pool creation accepts only the default parameter group; assign the custom one afterwards.
az horizondb cluster pool create -g $RG --cluster-name "$HZ" -n pool-01 \
  --compute-processor Intel --compute-generation 1 --v-cores 4 --node-count 1 --high-availability-mode Disabled
az rest --method patch --uri "https://management.azure.com$RID/clusters/$HZ/pools/pool-01?$API" --body \
  "{\"properties\":{\"parameterGroup\":{\"parameterGroupResourceId\":\"$RID/parameterGroups/pg-movielog-age\",\"applyMethod\":\"Immediate\"}}}"

# Administrator (password authentication) and firewall rules for the operator and AKS egress.
# jq escapes quotes and backslashes in the password.
az rest --method put --uri "https://management.azure.com$RID/clusters/$HZ/authentications/passwordMethod?$API" \
  --body "$(jq -nc --arg password "$HZ_ADMIN_PASSWORD" \
    '{properties: {state: "Enabled", administratorLogin: "movielogadmin", administratorLoginPassword: $password}}')"
az rest --method put --uri "https://management.azure.com$RID/clusters/$HZ/pools/pool-01/firewallRules/client?$API" \
  --body "{\"properties\":{\"startIpAddress\":\"$MY_IP\",\"endIpAddress\":\"$MY_IP\"}}"
HZ_HOST="$(az rest --method get --uri "https://management.azure.com$RID/clusters/$HZ/endpoints?$API" \
  --query "value[?properties.role=='ReadWrite'].properties.fullyQualifiedDomainName | [0]" -o tsv)"
```

`passwordMethod`와 cluster 응답에는 `provisioningState`가 없을 수 있으므로
`administratorLogin`이 응답에 나타나는지로 완료를 확인합니다.

## 2. Azure OpenAI·AKS·모니터링 리소스

Azure OpenAI, AKS(workload identity·app monitoring), 모니터링 리소스를 만듭니다.

```bash
az cognitiveservices account create -g $RG -n "$AOAI" -l $LOC --kind OpenAI --sku S0 --custom-domain "$AOAI"
# Keyless: only Microsoft Entra tokens (workload identity, az login) can call the account.
az resource update --ids "$(az cognitiveservices account show -g $RG -n "$AOAI" --query id -o tsv)" \
  --set properties.disableLocalAuth=true
az cognitiveservices account deployment create -g $RG -n "$AOAI" --deployment-name text-embedding-3-large \
  --model-name text-embedding-3-large --model-version 1 --model-format OpenAI --sku-name GlobalStandard --sku-capacity 150
az monitor log-analytics workspace create -g $RG -n law-movielog-hz
az monitor app-insights component create -g $RG -a appi-movielog-hz -l $LOC \
  --workspace "$(az monitor log-analytics workspace show -g $RG -n law-movielog-hz --query id -o tsv)"
az acr create -g $RG -n "$ACR" --sku Basic
az aks create -g $RG -n aks-movielog-hz --node-count 2 --node-vm-size Standard_D4s_v5 \
  --enable-azure-monitor-app-monitoring --enable-oidc-issuer --enable-workload-identity \
  --attach-acr "$ACR" --generate-ssh-keys
az grafana create -g $RG -n "$GRAFANA" --sku-tier Standard

# Workload identity for query embeddings; the operator also needs the role for embed_catalog.py.
AOAI_ID="$(az cognitiveservices account show -g $RG -n "$AOAI" --query id -o tsv)"
az identity create -g $RG -n id-movielog-app
az role assignment create --assignee-object-id "$(az identity show -g $RG -n id-movielog-app --query principalId -o tsv)" \
  --assignee-principal-type ServicePrincipal --role "Cognitive Services OpenAI User" --scope "$AOAI_ID"
az role assignment create --assignee-object-id "$(az ad signed-in-user show --query id -o tsv)" \
  --assignee-principal-type User --role "Cognitive Services OpenAI User" --scope "$AOAI_ID"
az identity federated-credential create -g $RG --identity-name id-movielog-app -n movielog-sa \
  --issuer "$(az aks show -g $RG -n aks-movielog-hz --query oidcIssuerProfile.issuerUrl -o tsv)" \
  --subject system:serviceaccount:movielog:movielog --audiences api://AzureADTokenExchange
```

## 3. DB 준비

AKS outbound IP를 HorizonDB 방화벽에 더하고 DB를 준비합니다.

```bash
NRG="$(az aks show -g $RG -n aks-movielog-hz --query nodeResourceGroup -o tsv)"
EGRESS="$(az network public-ip list -g "$NRG" \
  --query "[?tags.\"aks-managed-type\"=='aks-slb-managed-outbound-ip'].ipAddress | [0]" -o tsv)"
az rest --method put --uri "https://management.azure.com$RID/clusters/$HZ/pools/pool-01/firewallRules/aks-egress?$API" \
  --body "{\"properties\":{\"startIpAddress\":\"$EGRESS\",\"endIpAddress\":\"$EGRESS\"}}"

export PGHOST="$HZ_HOST" PGUSER=movielogadmin PGPASSWORD="$HZ_ADMIN_PASSWORD" PGSSLMODE=require
# 00-database.sql reads APP_DB_PASSWORD from the environment (psql 15+), not from the command line.
APP_DB_PASSWORD="$APP_DB_PASSWORD" psql -d postgres -f db/00-database.sql
PGDATABASE=movielog psql -f db/10-schema.sql
```

## 4. Key Vault 비밀값과 Microsoft Entra ID 앱

앱 비밀값을 Key Vault에 넣고 Microsoft Entra ID 앱을 등록합니다. 공개 주소(`APP_HOST`)를 먼저 정하면
redirect URI를 미리 등록할 수 있습니다. 값은 파일 권한 600인 임시 파일로만 다루고 명령줄에 쓰지 않습니다.

```bash
# APP_HOST: a new name in a DNS zone you own, for example movielog.example.com.
export APP_HOST=movielog.example.com
export KEYVAULT_NAME="<keyvault-name>" KEYVAULT_TENANT_ID="$(az account show --query tenantId -o tsv)"
az keyvault create -g $RG -n "$KEYVAULT_NAME" -l $LOC --enable-rbac-authorization true
KV_ID="$(az keyvault show -n "$KEYVAULT_NAME" --query id -o tsv)"
az role assignment create --assignee-object-id "$(az identity show -g $RG -n id-movielog-app --query principalId -o tsv)" \
  --assignee-principal-type ServicePrincipal --role "Key Vault Secrets User" --scope "$KV_ID"

# Private endpoint in the AKS VNet (public network access was disabled by policy in the lab subscription).
NRG="$(az aks show -g $RG -n aks-movielog-hz --query nodeResourceGroup -o tsv)"
VNET_ID="$(az network vnet list -g "$NRG" --query "[0].id" -o tsv)"
az network private-dns zone create -g $RG -n privatelink.vaultcore.azure.net
az network private-dns link vnet create -g $RG -z privatelink.vaultcore.azure.net -n aks-vnet-link -v "$VNET_ID" -e false
az network private-endpoint create -g $RG -n "pe-$KEYVAULT_NAME" -l $LOC --subnet "$VNET_ID/subnets/aks-subnet" \
  --private-connection-resource-id "$KV_ID" --group-ids vault --connection-name kv-conn
az network private-endpoint dns-zone-group create -g $RG --endpoint-name "pe-$KEYVAULT_NAME" -n default \
  --private-dns-zone privatelink.vaultcore.azure.net --zone-name vault
az aks enable-addons -g $RG -n aks-movielog-hz --addons azure-keyvault-secrets-provider

# Single-tenant Entra ID app; the client secret goes straight to a 600 file.
export ENTRA_TENANT_ID="$KEYVAULT_TENANT_ID"
export ENTRA_CLIENT_ID="$(az ad app create --display-name movielog-horizondb-lab --sign-in-audience AzureADMyOrg \
  --web-redirect-uris "https://$APP_HOST/login/oauth2/code/entra" --query appId -o tsv)"
az ad sp create --id "$ENTRA_CLIENT_ID"
umask 077; SECRETS="$(mktemp -d)"
az ad app credential reset --id "$ENTRA_CLIENT_ID" --display-name aks-movielog \
  --end-date "$(date -u -d '+180 days' +%Y-%m-%d)" --query password -o tsv | tr -d '\n' > "$SECRETS/entra-client-secret"
# Put the TMDB API Read Access Token and the OMDb key into $SECRETS/tmdb-api-key and $SECRETS/omdb-api-key.
for name in tmdb-api-key omdb-api-key entra-client-secret; do
  jq -nc --rawfile v "$SECRETS/$name" '{properties: {value: $v, contentType: "text/plain"}}' > "$SECRETS/body.json"
  az rest --method put --uri "https://management.azure.com$KV_ID/secrets/$name?api-version=2023-07-01" \
    --body @"$SECRETS/body.json" --query name -o tsv
done
rm -rf "$SECRETS"
```

## 5. 앱 배포

앱을 배포합니다. 첫 배포는 replica 1개로 Hibernate가 schema를 만들게 합니다.

```bash
ACR_SERVER="$(az acr show -n "$ACR" --query loginServer -o tsv)"
# Released image pinned by digest: the image value printed by the release workflow (also in the docs sample.yml).
VERSION=2.6.5  # release to deploy
IMAGE="ghcr.io/hellices/sample-movielog-horizondb:$VERSION@sha256:<digest>"
az acr import --name "$ACR" --source "${IMAGE%%:*}@${IMAGE#*@}" --image "movielog:$VERSION" --force
az acr build -r "$ACR" -t observability/applicationinsights-agent:3.7.10 --platform linux/amd64 agent-init
az aks get-credentials -g $RG -n aks-movielog-hz

export MI_CLIENT_ID="$(az identity show -g $RG -n id-movielog-app --query clientId -o tsv)"
export AZURE_OPENAI_ENDPOINT="https://$AOAI.openai.azure.com/"
export APP_IMAGE="$ACR_SERVER/movielog:$VERSION"
export APPLICATIONINSIGHTS_CONNECTION_STRING="$(az monitor app-insights component show \
  -g $RG -a appi-movielog-hz --query connectionString -o tsv)"
envsubst < k8s/00-namespace.yaml | kubectl apply -f -
envsubst < k8s/24-keyvault-secrets.yaml | kubectl apply -f -
kubectl create secret generic movielog-db -n movielog \
  --from-literal=url="jdbc:postgresql://$HZ_HOST:5432/movielog?sslmode=require" \
  --from-literal=username=movielog --from-literal=password="$APP_DB_PASSWORD"
envsubst < k8s/10-instrumentation.yaml | kubectl apply -f -
envsubst < k8s/20-movielog.yaml | kubectl apply -f -
kubectl rollout status deploy/movielog -n movielog
```

주입된 agent가 3.7.9 미만이면 `k8s/21-agent-3.7.10.patch.yaml` 주석의 두 단계로
3.7.10 init image로 바꿉니다. 이후 이미지만 바꿀 때는 patch가 유지되도록
`kubectl set image`를 씁니다.

## 6. 카탈로그 적재·임베딩·그래프

카탈로그를 적재하고 임베딩·index·그래프를 만듭니다. 영화 약 480편 기준으로
`build_catalog.py`는 약 8–11분, `catalog.sql` 적재와 임베딩은 각각 약 3–4분,
TMDB 보강은 약 2분, 그래프 생성은 약 6초 걸렸습니다. Wikidata·Wikipedia에는 포스터가 없으므로
`enrich_tmdb.py`가 TMDB API Read Access Token(`TMDB_API_TOKEN`)으로 포스터 경로를 채웁니다.
토큰은 셸 history에 남지 않도록 `read -rs`로 입력합니다.

```bash
python3 data/build_catalog.py
export PGDATABASE=movielog
psql -q -f data/out/catalog.sql
read -rs TMDB_API_TOKEN && export TMDB_API_TOKEN
python3 data/enrich_tmdb.py
psql -q -f data/out/tmdb.sql
AZURE_OPENAI_ENDPOINT="https://$AOAI.openai.azure.com/" python3 data/embed_catalog.py
psql -f db/20-vector-index.sql
psql -f db/30-graph.sql
psql -f db/40-graph-sync.sql
```

## 7. 부하

부하를 켭니다.

```bash
kubectl scale deploy/movielog -n movielog --replicas=2
kubectl create configmap loadgen -n movielog --from-file=loadgen/loadgen.py
kubectl apply -f k8s/30-loadgen.yaml
```

## 8. HTTPS 공개(Application Gateway for Containers)

Application Gateway for Containers로 앱을 커스텀 도메인의 HTTPS로 공개합니다. 회원 가입과
form login이 있어 HTTP만 열면 비밀번호와 session cookie가 평문으로 전달되므로, HTTP listener는
Let's Encrypt HTTP-01 challenge에만 응답하고 나머지 요청은 HTTPS로 301 redirect합니다.

- **DNS** — 소유한 DNS zone에 이미 쓰는 이름과 겹치지 않는 host를 정하고, CNAME을 Gateway 주소로
  향하게 합니다. 실습은 Azure DNS zone의 새 하위 이름 하나를 썼습니다.
- **NSG** — AKS 관리형 VNet의 `aks-appgateway` 서브넷 NSG가 association에 적용되므로 frontend
  포트(TCP 80, 443)를 Internet에서 허용하는 규칙이 필요합니다. AGFC에서 Pod로 가는 트래픽은
  VNet 내부라 노드 NSG는 바꾸지 않습니다.
- **조직 보안 자동화** — 실습 구독에서는 모든 포트를 여는 Internet 허용 규칙을 만든 지 약 25분 뒤
  조직 보안 자동화(다른 tenant의 app)가 NSG를 다시 써서 규칙을 지웠고, 그 뒤 frontend 접속이
  시간 초과됐습니다. 포트를 지정한 규칙은 유지됐습니다.

```bash
# Requires the ManagedGatewayAPIPreview and ApplicationLoadBalancerPreview features (Microsoft.ContainerService).
az aks update -g $RG -n aks-movielog-hz --enable-gateway-api --enable-application-load-balancer
NRG="$(az aks show -g $RG -n aks-movielog-hz --query nodeResourceGroup -o tsv)"
export ALB_SUBNET_ID="$(az network vnet list -g "$NRG" \
  --query "[].subnets[?name=='aks-appgateway'][].id | [0]" -o tsv)"
ALB_NSG="$(az network vnet subnet show --ids "$ALB_SUBNET_ID" --query networkSecurityGroup.id -o tsv)"
for rule in http:200:80 https:210:443; do
  IFS=: read -r name priority port <<< "$rule"
  az network nsg rule create -g "$NRG" --nsg-name "${ALB_NSG##*/}" -n "allow-agfc-frontend-$name" \
    --priority "$priority" --direction Inbound --access Allow --protocol Tcp \
    --source-address-prefixes Internet --source-port-ranges '*' \
    --destination-address-prefixes '*' --destination-port-ranges "$port"
done

# cert-manager with Gateway API support (Learn: Cert-manager and Let's Encrypt with AGFC - Gateway API).
helm install cert-manager oci://quay.io/jetstack/charts/cert-manager --version v1.19.3 \
  --namespace cert-manager --create-namespace \
  --set config.enableGatewayAPI=true --set crds.enabled=true --wait

# APP_HOST was set with the Entra ID redirect URI above.
envsubst '$APP_HOST $ALB_SUBNET_ID' < k8s/26-agfc.yaml | kubectl apply -f -
GATEWAY_FQDN="$(kubectl get gateway movielog -n movielog -o jsonpath='{.status.addresses[0].value}')"
# Azure DNS example; DNS_ZONE_RG and DNS_ZONE are the resource group and name of your zone.
az network dns record-set list -g "$DNS_ZONE_RG" -z "$DNS_ZONE" --query "[].name" -o tsv  # pick an unused name
az network dns record-set cname set-record -g "$DNS_ZONE_RG" -z "$DNS_ZONE" \
  -n "${APP_HOST%%.$DNS_ZONE}" -c "$GATEWAY_FQDN" --ttl 300
envsubst '$APP_HOST' < k8s/27-tls.yaml | kubectl apply -f -
kubectl wait certificate/movielog-tls -n movielog --for=condition=Ready --timeout=5m
```

실습에서는 `Certificate` 적용 후 약 45초 만에 Let's Encrypt 인증서가 발급됐고, 두 listener가
모두 `Programmed`가 됐습니다. 확인은 다음처럼 합니다.

```bash
curl -sI "http://$APP_HOST/" | grep -iE '^HTTP|^location'     # 301 -> https://$APP_HOST/
curl -sv -o /dev/null "https://$APP_HOST/" 2>&1 | grep issuer # O=Let's Encrypt
curl -sI "https://$APP_HOST/reviews/new" | grep -i location   # https://$APP_HOST/login
```

AGFC는 백엔드에 `x-forwarded-proto`를 넘기고 Spring Boot는 Kubernetes에서 이 헤더를 따르므로,
앱이 만드는 redirect는 `https://` 주소가 되고 `JSESSIONID`·`XSRF-TOKEN` cookie에는 `Secure`가
붙었습니다. listener에 hostname을 지정했으므로 AGFC 기본 FQDN으로 들어온 요청은 404를 받습니다.
cert-manager는 만료 전에 인증서를 자동으로 갱신합니다.

## 9. Microsoft Entra ID 로그인 확인

HTTPS가 준비되면 Microsoft Entra ID 로그인을 확인합니다. 로그인 화면의 **Microsoft Entra ID로 로그인**은
`/oauth2/authorization/entra`에서 Entra ID authorize endpoint로 넘어갑니다. 실습에서는 redirect의
`client_id`, `redirect_uri`(`https://$APP_HOST/login/oauth2/code/entra`), `scope=openid profile`, `state`·`nonce`와
Entra ID 로그인 화면(이메일 입력)까지 브라우저로 확인했고, 기존 아이디·비밀번호 가입과 로그인도 그대로
동작했습니다.

```bash
curl -s -o /dev/null -w '%{redirect_url}\n' "https://$APP_HOST/oauth2/authorization/entra"
```

이미 실행 중인 앱을 Entra ID 로그인이 있는 이미지로 바꾸면 Hibernate `ddl-auto=update`가 `members`에
`external_id` 열을 더합니다. 실습에서는 이 순간 아직 남아 있던 이전 Pod의 회원가입 INSERT 7건이 약 1초 동안
`cached plan must not change result type`으로 실패했고, 이전 Pod가 내려간 뒤에는 다시 나지 않았습니다.

`RoutePolicy`의 `managed-cookie`는 gateway가 `AGCAffinity` cookie를 첫 응답에 붙여
로그인 session이 한 Pod에 머물게 합니다. 실습에서 가입·로그인 뒤 인증이 필요한 리뷰 작성
10건이 모두 성공했고, HTTPS 전환 뒤에도 가입·로그인이 정상 동작했습니다.

## 10. Grafana dashboard

![MovieLog HorizonDB 의미 검색 Grafana 대시보드](images/grafana-discover-dashboard.png)

`appinsights` 변수에 Application Insights resource ID를 채운 사본을 만들어 올립니다.
채운 JSON은 커밋하지 않습니다.

```bash
AIID="$(az monitor app-insights component show -g $RG -a appi-movielog-hz --query id -o tsv)"
python3 - "$AIID" > /tmp/live.json <<'PY'
import json, sys
d = json.load(open("grafana/movielog-horizondb-dashboard.json", encoding="utf-8"))
for v in d["templating"]["list"]:
    if v["name"] == "appinsights":
        v.update(query=sys.argv[1], current={"text": sys.argv[1], "value": sys.argv[1]}, hide=2)
json.dump(d, sys.stdout, ensure_ascii=False)
PY
az grafana dashboard create -g $RG -n "$GRAFANA" --definition @/tmp/live.json --overwrite true
rm /tmp/live.json
```

| Micrometer meter | 종류 | tag |
|---|---|---|
| `movielog.discover.embedding` | Timer | `kind=query`, `outcome` |
| `movielog.discover.search`, `movielog.discover.similar` | Timer | `kind=vector`, `outcome` = `found`/`empty`/`error` |
| `movielog.discover.graph` | Timer | `kind` = `movie`/`results`, `outcome` |
| `movielog.discover.rejected` | Counter | 요청률 한도로 Azure OpenAI 호출 전에 거부한 의미 검색 |

## 11. 정리

DNS 레코드는 실습 resource group 밖의 zone에 있으므로 따로 지웁니다.

```bash
az network dns record-set cname delete -g "$DNS_ZONE_RG" -z "$DNS_ZONE" -n "${APP_HOST%%.$DNS_ZONE}" --yes
az group delete -n "$RG" --yes --no-wait
```
