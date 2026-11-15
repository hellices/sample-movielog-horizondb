#!/usr/bin/env bash
# azd predown: remove what lives outside the resource group azd deletes — the DNS record and the Microsoft Entra ID
# app registration — when the hooks created them.
# shellcheck source=hooks/lib.sh
source "$(dirname "$0")/lib.sh"

if [ "${DNS_RECORD_CREATED:-}" = "true" ] && [ -n "${APP_HOST:-}" ]; then
  log "Deleting the CNAME record $APP_HOST"
  az network dns record-set cname delete --subscription "${DNS_ZONE_SUBSCRIPTION_ID:-$AZURE_SUBSCRIPTION_ID}" \
    -g "$DNS_ZONE_RESOURCE_GROUP" -z "$DNS_ZONE_NAME" \
    -n "${APP_HOST%."$DNS_ZONE_NAME"}" --yes -o none || true
  azd env set DNS_RECORD_CREATED ""
fi
if [ "${ENTRA_APP_CREATED:-}" = "true" ] && [ -n "${ENTRA_CLIENT_ID:-}" ]; then
  log "Deleting the Microsoft Entra ID app registration $ENTRA_CLIENT_ID"
  az ad app delete --id "$ENTRA_CLIENT_ID" || true
  azd env set ENTRA_CLIENT_ID ""
  azd env set ENTRA_APP_CREATED ""
fi
azd env set HORIZONDB_HOST ""
