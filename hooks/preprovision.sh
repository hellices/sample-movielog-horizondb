#!/usr/bin/env bash
# azd preprovision: check the local tools, register the preview features and resource providers, and keep the
# operator IP and the database passwords in the azd environment (.azure/<env>/.env, never committed).
# shellcheck source=hooks/lib.sh
source "$(dirname "$0")/lib.sh"

need az jq curl openssl psql python3 kubectl envsubst
az extension add --name horizondb --upgrade --yes --only-show-errors
az extension add --name amg --upgrade --yes --only-show-errors

features=(AzureMonitorAppMonitoringPreview)
if [ "${GATEWAY_ENABLED:-true}" != "false" ]; then
  need helm
  features+=(ManagedGatewayAPIPreview ApplicationLoadBalancerPreview)
fi
registered_any=false
for feature in "${features[@]}"; do
  state="$(az feature show --namespace Microsoft.ContainerService --name "$feature" --query properties.state -o tsv)"
  if [ "$state" != "Registered" ]; then
    log "Registering Microsoft.ContainerService/$feature (takes a few minutes)"
    az feature register --namespace Microsoft.ContainerService --name "$feature" -o none
    retry 60 20 sh -c "[ \"\$(az feature show --namespace Microsoft.ContainerService --name $feature --query properties.state -o tsv)\" = Registered ]"
    registered_any=true
  fi
done

providers=(Microsoft.ContainerService Microsoft.HorizonDb Microsoft.CognitiveServices Microsoft.KeyVault
  Microsoft.Dashboard Microsoft.OperationalInsights Microsoft.Insights Microsoft.ContainerRegistry
  Microsoft.ManagedIdentity Microsoft.Network Microsoft.ServiceNetworking)
for provider in "${providers[@]}"; do
  state="$(az provider show --namespace "$provider" --query registrationState -o tsv)"
  if [ "$state" != "Registered" ] || { [ "$provider" = Microsoft.ContainerService ] && $registered_any; }; then
    log "Registering $provider"
    az provider register --namespace "$provider" --wait -o none
  fi
done

gpu_size="${GPU_VM_SIZE:-Standard_NC4as_T4_v3}"
log "Checking $gpu_size in $AZURE_LOCATION for the spot GPU node pool"
offered="$(az vm list-skus -l "$AZURE_LOCATION" --size "$gpu_size" --resource-type virtualMachines \
  --query "[?name=='$gpu_size' && length(restrictions)==\`0\`].name" -o tsv)"
if [ -z "$offered" ]; then
  echo "$gpu_size is not offered in $AZURE_LOCATION; set GPU_VM_SIZE to an NVIDIA size available there" >&2
  exit 1
fi
low_priority="$(az vm list-usage -l "$AZURE_LOCATION" --query "[?name.value=='lowPriorityCores'] | [0].[currentValue, limit]" -o tsv)"
echo "spot (low-priority) vCPU usage/limit in $AZURE_LOCATION: ${low_priority//$'\t'/\/}"

if [ -z "${OPERATOR_IP:-}" ]; then
  azd env set OPERATOR_IP "$(curl -fsS https://api.ipify.org)"
fi
# Letters and digits plus fixed classes, so the password meets complexity rules and needs no quoting.
new_password() { printf '%sAa1-' "$(openssl rand -base64 33 | tr -dc 'A-Za-z0-9' | cut -c1-24)"; }
if [ -z "${HORIZONDB_ADMIN_PASSWORD:-}" ]; then
  azd env set HORIZONDB_ADMIN_PASSWORD "$(new_password)"
fi
if [ -z "${APP_DB_PASSWORD:-}" ]; then
  azd env set APP_DB_PASSWORD "$(new_password)"
fi
