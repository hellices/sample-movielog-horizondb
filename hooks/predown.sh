#!/usr/bin/env bash
# azd predown: remove what lives outside the resource group azd deletes — the DNS record and the Microsoft Entra ID
# app registration — when the hooks created them.
# shellcheck source=hooks/lib.sh
source "$(dirname "$0")/lib.sh"

# State is cleared only after a delete succeeds or the resource is already gone, so a failed run can be retried.
if [ "${DNS_RECORD_CREATED:-}" = "true" ] && [ -n "${APP_HOST:-}" ]; then
  log "Deleting the CNAME record $APP_HOST"
  dns=(--subscription "${DNS_ZONE_SUBSCRIPTION_ID:-$AZURE_SUBSCRIPTION_ID}" -g "$DNS_ZONE_RESOURCE_GROUP" -z "$DNS_ZONE_NAME"
    -n "${APP_HOST%."$DNS_ZONE_NAME"}")
  if az network dns record-set cname show "${dns[@]}" -o none 2>/dev/null; then
    az network dns record-set cname delete "${dns[@]}" --yes -o none
  fi
  azd env set DNS_RECORD_CREATED ""
fi
if [ "${ENTRA_APP_CREATED:-}" = "true" ] && [ -n "${ENTRA_CLIENT_ID:-}" ]; then
  log "Deleting the Microsoft Entra ID app registration $ENTRA_CLIENT_ID"
  if az ad app show --id "$ENTRA_CLIENT_ID" -o none 2>/dev/null; then
    az ad app delete --id "$ENTRA_CLIENT_ID"
  fi
  azd env set ENTRA_CLIENT_ID ""
  azd env set ENTRA_APP_CREATED ""
fi
azd env set HORIZONDB_HOST ""
azd env set TMDB_ENRICHED ""
