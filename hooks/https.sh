#!/usr/bin/env bash
# HTTPS endpoint (called by postdeploy when APP_HOST is set): Application Gateway for Containers listeners,
# frontend NSG rules, cert-manager with Gateway API support, a Let's Encrypt certificate and, when the DNS zone is
# given, the CNAME record. The HTTP listener only answers HTTP-01 challenges and redirects everything else to HTTPS.
#   APP_HOST                                  host name for the app, for example movielog.example.com
#   DNS_ZONE_NAME, DNS_ZONE_RESOURCE_GROUP    optional Azure DNS zone that holds APP_HOST
#   DNS_ZONE_SUBSCRIPTION_ID                  subscription of that zone when it differs from the deployment
# shellcheck source=hooks/lib.sh
source "$(dirname "$0")/lib.sh"
need helm

log "Application Gateway for Containers frontend for $APP_HOST"
export APP_HOST
ALB_SUBNET_ID="$(az network vnet list -g "$AZURE_AKS_NODE_RESOURCE_GROUP" \
  --query "[].subnets[?name=='aks-appgateway'][].id | [0]" -o tsv)"
export ALB_SUBNET_ID
# The subnet NSG (when one is attached, for example by policy) applies to the association, so it needs the frontend
# ports. A subnet without an NSG needs no rules.
nsg="$(az network vnet subnet show --ids "$ALB_SUBNET_ID" --query networkSecurityGroup.id -o tsv)"
if [ -n "$nsg" ] && [ "$nsg" != "None" ]; then
  nsg_group="$(cut -d/ -f5 <<< "$nsg")"
  for rule in http:200:80 https:210:443; do
    IFS=: read -r name priority port <<< "$rule"
    az network nsg rule create -g "$nsg_group" --nsg-name "${nsg##*/}" -n "allow-agfc-frontend-$name" \
      --priority "$priority" --direction Inbound --access Allow --protocol Tcp \
      --source-address-prefixes Internet --source-port-ranges '*' \
      --destination-address-prefixes '*' --destination-port-ranges "$port" -o none
  done
fi

# Install once: AKS admissions enforcer co-owns the webhook namespaceSelector, so a helm upgrade conflicts.
if ! helm status cert-manager -n cert-manager >/dev/null 2>&1; then
  helm install cert-manager oci://quay.io/jetstack/charts/cert-manager --version v1.19.3 \
    --namespace cert-manager --create-namespace \
    --set config.enableGatewayAPI=true --set crds.enabled=true --wait
fi
# shellcheck disable=SC2016 # envsubst variable list, expanded by envsubst
envsubst '$APP_HOST $ALB_SUBNET_ID' < k8s/26-agfc.yaml | kubectl apply -f -
gateway_address() { kubectl get gateway movielog -n movielog -o jsonpath='{.status.addresses[0].value}'; }
# shellcheck disable=SC2016 # expanded by the inner sh on every attempt
retry 40 15 sh -c '[ -n "$(kubectl get gateway movielog -n movielog -o jsonpath="{.status.addresses[0].value}")" ]'
fqdn="$(gateway_address)"

if [ -n "${DNS_ZONE_NAME:-}" ] && [ -n "${DNS_ZONE_RESOURCE_GROUP:-}" ]; then
  record="${APP_HOST%."$DNS_ZONE_NAME"}"
  dns=(--subscription "${DNS_ZONE_SUBSCRIPTION_ID:-$AZURE_SUBSCRIPTION_ID}" -g "$DNS_ZONE_RESOURCE_GROUP" -z "$DNS_ZONE_NAME")
  existing="$(az network dns record-set cname show "${dns[@]}" -n "$record" \
    --query CNAMERecord.cname -o tsv 2>/dev/null || true)"
  if [ -z "$existing" ]; then
    # Refuse to take over a name that already has other records.
    if [ -n "$(az network dns record-set list "${dns[@]}" \
      --query "[?name=='$record'].name" -o tsv)" ]; then
      echo "$APP_HOST already has DNS records; choose an unused name" >&2
      exit 1
    fi
    azd env set DNS_RECORD_CREATED true
  fi
  # A CNAME this environment did not create must not be repointed: it may serve another application.
  if [ -n "$existing" ] && [ "$existing" != "$fqdn" ] && [ "${DNS_RECORD_CREATED:-}" != "true" ]; then
    echo "$APP_HOST already points at $existing, which this environment did not create; choose an unused name" >&2
    exit 1
  fi
  if [ "$existing" != "$fqdn" ]; then
    log "CNAME $APP_HOST -> $fqdn"
    az network dns record-set cname set-record "${dns[@]}" -n "$record" \
      -c "$fqdn" --ttl 300 -o none
  fi
else
  log "Point a CNAME record for $APP_HOST at $fqdn, then run: azd hooks run postdeploy"
fi

# shellcheck disable=SC2016
envsubst '$APP_HOST' < k8s/27-tls.yaml | kubectl apply -f -
if kubectl wait certificate/movielog-tls -n movielog --for=condition=Ready --timeout=10m; then
  log "Done. https://$APP_HOST"
else
  echo "The certificate is not ready; check that $APP_HOST resolves to $fqdn, then run: azd hooks run postdeploy" >&2
  exit 1
fi
