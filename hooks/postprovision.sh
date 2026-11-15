#!/usr/bin/env bash
# azd postprovision: everything Bicep cannot declare yet.
#   1. Azure HorizonDB (preview, no Bicep types): parameter group, cluster, pool, administrator, firewall rules
#   2. movielog database, app role and schema
#   3. Key Vault private endpoint in the AKS virtual network and the app secrets
#   4. Optional Microsoft Entra ID app registration (APP_HOST set)
#   5. Cluster-wide Kubernetes objects: namespace, workload identity, instrumentation, secrets
# Every step checks what exists, so the hook can run again.
# shellcheck source=hooks/lib.sh
source "$(dirname "$0")/lib.sh"

HZ="$HORIZONDB_CLUSTER_NAME"
PG=pg-movielog
POOL=pool-01

log "HorizonDB parameter group $PG (vector, pg_diskann, age; AGE preloaded)"
horizondb put "parameterGroups/$PG" -o none --body "$(jq -nc --arg location "$AZURE_LOCATION" '{
  location: $location,
  properties: {
    postgreSqlVersion: "17",
    description: "MovieLog: vector, DiskANN, Apache AGE",
    parameters: [
      {name: "azure.extensions", value: "vector,pg_diskann,age"},
      {name: "shared_preload_libraries", value: "age"}
    ]
  }
}')"

if ! horizondb get "clusters/$HZ" -o none 2>/dev/null; then
  log "HorizonDB cluster $HZ (10-20 minutes)"
  az horizondb cluster create -g "$AZURE_RESOURCE_GROUP" -n "$HZ" -l "$AZURE_LOCATION" --version 17 \
    --public-access Enabled --geo-redundancy Disabled -o none
fi
if ! horizondb get "clusters/$HZ/pools/$POOL" -o none 2>/dev/null; then
  log "HorizonDB pool $POOL"
  az horizondb cluster pool create -g "$AZURE_RESOURCE_GROUP" --cluster-name "$HZ" -n "$POOL" \
    --compute-processor Intel --compute-generation 1 --v-cores 4 --node-count 1 --high-availability-mode Disabled -o none
fi

pool_ready() {
  [ "$(horizondb get "clusters/$HZ/pools/$POOL" --query "join('/', [properties.state, properties.parameterGroup.syncStatus])" -o tsv)" = "Ready/InSync" ]
}
# Pool creation accepts only the default parameter group, so the custom one is assigned afterwards.
group_id="$(horizondb_rid)/parameterGroups/$PG"
current="$(horizondb get "clusters/$HZ/pools/$POOL" --query properties.parameterGroup.parameterGroupResourceId -o tsv)"
if [ "$(lower "$current")" != "$(lower "$group_id")" ]; then
  log "Assigning $PG to $POOL (restarts the pool)"
  horizondb patch "clusters/$HZ/pools/$POOL" -o none --body "$(jq -nc --arg id "$group_id" \
    '{properties: {parameterGroup: {parameterGroupResourceId: $id, applyMethod: "Immediate"}}}')"
  sleep 30
fi
retry 60 20 pool_ready

log "HorizonDB administrator and firewall rules"
body="$(tmpfile)"
chmod 600 "$body"
jq -nc --arg login "$HORIZONDB_ADMIN" --arg password "$HORIZONDB_ADMIN_PASSWORD" \
  '{properties: {state: "Enabled", administratorLogin: $login, administratorLoginPassword: $password}}' > "$body"
horizondb put "clusters/$HZ/authentications/passwordMethod" --body "@$body" -o none
rm -f "$body"
# The response may not carry provisioningState; the administrator login appearing marks completion.
retry 30 20 sh -c "[ -n \"\$(az rest --method get --uri 'https://management.azure.com$(horizondb_rid)/clusters/$HZ/authentications/passwordMethod?$HORIZONDB_API' --query properties.administratorLogin -o tsv)\" ]"

egress_ip="$(az network public-ip show --ids "$AZURE_AKS_OUTBOUND_IP_ID" --query ipAddress -o tsv)"
for rule in "operator=$OPERATOR_IP" "aks-egress=$egress_ip"; do
  horizondb put "clusters/$HZ/pools/$POOL/firewallRules/${rule%%=*}" -o none --body "$(jq -nc --arg ip "${rule#*=}" \
    '{properties: {startIpAddress: $ip, endIpAddress: $ip}}')"
done
HORIZONDB_HOST="$(horizondb get "clusters/$HZ/endpoints" \
  --query "value[?properties.role=='ReadWrite'].properties.fullyQualifiedDomainName | [0]" -o tsv)"
azd env set HORIZONDB_HOST "$HORIZONDB_HOST"

log "Database movielog, app role and catalog schema"
# Firewall rules take a moment to apply.
retry 20 15 admin_psql -d postgres -qc 'SELECT 1' >/dev/null
APP_DB_PASSWORD="$APP_DB_PASSWORD" admin_psql -d postgres -q -f db/00-database.sql
admin_psql -d movielog -q -f db/10-schema.sql

log "Key Vault private endpoint in the AKS virtual network"
KV_ID="$(az keyvault show -n "$KEYVAULT_NAME" --query id -o tsv)"
VNET_ID="$(az network vnet list -g "$AZURE_AKS_NODE_RESOURCE_GROUP" --query "[0].id" -o tsv)"
ZONE=privatelink.vaultcore.azure.net
az network private-dns zone show -g "$AZURE_RESOURCE_GROUP" -n "$ZONE" -o none 2>/dev/null ||
  az network private-dns zone create -g "$AZURE_RESOURCE_GROUP" -n "$ZONE" -o none
az network private-dns link vnet show -g "$AZURE_RESOURCE_GROUP" -z "$ZONE" -n aks-vnet-link -o none 2>/dev/null ||
  az network private-dns link vnet create -g "$AZURE_RESOURCE_GROUP" -z "$ZONE" -n aks-vnet-link -v "$VNET_ID" -e false -o none
az network private-endpoint show -g "$AZURE_RESOURCE_GROUP" -n "pe-$KEYVAULT_NAME" -o none 2>/dev/null ||
  az network private-endpoint create -g "$AZURE_RESOURCE_GROUP" -n "pe-$KEYVAULT_NAME" -l "$AZURE_LOCATION" \
    --subnet "$VNET_ID/subnets/aks-subnet" --private-connection-resource-id "$KV_ID" --group-ids vault \
    --connection-name kv-conn -o none
# dns-zone-group show exits 0 when the group is missing, so check the list instead.
[ -n "$(az network private-endpoint dns-zone-group list -g "$AZURE_RESOURCE_GROUP" --endpoint-name "pe-$KEYVAULT_NAME" \
  --query "[?name=='default'].name" -o tsv)" ] ||
  az network private-endpoint dns-zone-group create -g "$AZURE_RESOURCE_GROUP" --endpoint-name "pe-$KEYVAULT_NAME" \
    -n default --private-dns-zone "$ZONE" --zone-name vault -o none

# Secrets go through the ARM control plane because the vault has no public data-plane access. Values are read from a
# 600 file, never from the command line. A missing value is stored empty: the app treats an empty key as unset.
secret_exists() {
  az rest --method get --uri "https://management.azure.com$KV_ID/secrets/$1?api-version=2023-07-01" -o none 2>/dev/null
}
put_secret() {
  local file tags="${4:-}"
  [ -n "$tags" ] || tags='{}'
  file="$(tmpfile)"
  printf '%s' "$2" | jq -Rs --arg type "${3:-text/plain}" --argjson tags "$tags" \
    '{tags: $tags, properties: {value: ., contentType: $type}}' > "$file"
  az rest --method put --uri "https://management.azure.com$KV_ID/secrets/$1?api-version=2023-07-01" \
    --body "@$file" -o none
  rm -f "$file"
}
for pair in "tmdb-api-key=TMDB_API_TOKEN" "omdb-api-key=OMDB_API_KEY"; do
  name="${pair%%=*}"
  value="$(printenv "${pair#*=}" || true)"
  if [ -n "$value" ] || ! secret_exists "$name"; then
    log "Key Vault secret $name"
    put_secret "$name" "$value"
  fi
done

# The ARM secret API never returns values, so the secret's tags record which Entra credential it holds and when that
# credential expires. A run renews the credential unless the stored one still exists and stays valid for 30 more days.
stored_credential_current() {
  local stored id end threshold
  stored="$(az rest --method get --uri "https://management.azure.com$KV_ID/secrets/entra-client-secret?api-version=2023-07-01" \
    --query "[tags.credentialId, tags.credentialEnd]" -o tsv 2>/dev/null || true)"
  read -r id end <<<"$stored"
  threshold="$(python3 -c 'import datetime as d; print((d.datetime.now(d.timezone.utc) + d.timedelta(days=30)).strftime("%Y-%m-%dT%H:%M:%S"))')"
  [ -n "$id" ] && [ "$id" != "None" ] && [[ "${end:0:19}" > "$threshold" ]] \
    && [ "$(az ad app credential list --id "$ENTRA_CLIENT_ID" --query "length([?keyId=='$id'])" -o tsv)" = "1" ]
}
# Each step is recorded as soon as it succeeds, so a rerun after a failure resumes instead of creating a second app.
if [ -n "${APP_HOST:-}" ]; then
  if [ -z "${ENTRA_CLIENT_ID:-}" ]; then
    log "Microsoft Entra ID app registration for https://$APP_HOST"
    ENTRA_CLIENT_ID="$(az ad app create --display-name "movielog-$AZURE_ENV_NAME" --sign-in-audience AzureADMyOrg \
      --web-redirect-uris "https://$APP_HOST/login/oauth2/code/entra" --query appId -o tsv)"
    azd env set ENTRA_CLIENT_ID "$ENTRA_CLIENT_ID"
    azd env set ENTRA_APP_CREATED true
  fi
  if ! az ad sp show --id "$ENTRA_CLIENT_ID" -o none 2>/dev/null; then
    az ad sp create --id "$ENTRA_CLIENT_ID" -o none
  fi
  if ! stored_credential_current; then
    log "Client secret for $ENTRA_CLIENT_ID"
    credential="$(az ad app credential reset --id "$ENTRA_CLIENT_ID" --display-name aks-movielog \
      --append --years 1 --query password -o tsv)"
    if [ -z "$credential" ]; then
      echo "az ad app credential reset returned no secret for $ENTRA_CLIENT_ID" >&2
      exit 1
    fi
    # The credential just appended is the newest one with this display name.
    issued="$(az ad app credential list --id "$ENTRA_CLIENT_ID" \
      --query "sort_by([?displayName=='aks-movielog'], &startDateTime)[-1].{credentialId: keyId, credentialEnd: endDateTime}" -o json)"
    put_secret entra-client-secret "$credential" text/plain "$issued"
    unset credential
  fi
elif ! secret_exists entra-client-secret; then
  put_secret entra-client-secret ""
fi

log "Kubernetes namespace, workload identity, instrumentation and secrets"
az aks get-credentials -g "$AZURE_RESOURCE_GROUP" -n "$AZURE_AKS_CLUSTER_NAME" --overwrite-existing -o none
export MI_CLIENT_ID APPLICATIONINSIGHTS_CONNECTION_STRING KEYVAULT_NAME
export KEYVAULT_TENANT_ID="$AZURE_TENANT_ID"
envsubst < k8s/00-namespace.yaml | kubectl apply -f -
# The Instrumentation CRD appears once the application monitoring add-on is running.
retry 30 20 sh -c 'envsubst < k8s/10-instrumentation.yaml | kubectl apply -f -'
kubectl create secret generic appinsights -n movielog \
  --from-literal=connection-string="$APPLICATIONINSIGHTS_CONNECTION_STRING" --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic movielog-db -n movielog \
  --from-literal=url="jdbc:postgresql://$HORIZONDB_HOST:5432/movielog?sslmode=require" \
  --from-literal=username=movielog --from-literal=password="$APP_DB_PASSWORD" --dry-run=client -o yaml |
  kubectl apply -f -
envsubst < k8s/24-keyvault-secrets.yaml | kubectl apply -f -
