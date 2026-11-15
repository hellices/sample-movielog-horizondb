#!/usr/bin/env bash
# azd predown: remove what lives outside the resource group azd deletes — the DNS record and the Microsoft Entra ID
# app registration — when the hooks created them.
# shellcheck source=hooks/lib.sh
source "$(dirname "$0")/lib.sh"

# State is cleared only after a delete succeeds or a lookup reports the resource as gone; any other lookup error
# fails the hook and keeps the state, so the run can be retried.
gone_or_fail() {
  if grep -qiE 'not ?found|does not exist' <<<"$1"; then
    return 0
  fi
  printf '%s\n' "$1" >&2
  exit 1
}
if [ -n "${DNS_RECORD_CREATED:-}" ] && [ "$DNS_RECORD_CREATED" = "${APP_HOST:-}" ]; then
  log "Deleting the CNAME record $APP_HOST"
  dns=(--subscription "${DNS_ZONE_SUBSCRIPTION_ID:-$AZURE_SUBSCRIPTION_ID}" -g "$DNS_ZONE_RESOURCE_GROUP" -z "$DNS_ZONE_NAME"
    -n "${APP_HOST%."$DNS_ZONE_NAME"}")
  if lookup="$(az network dns record-set cname show "${dns[@]}" -o none 2>&1)"; then
    az network dns record-set cname delete "${dns[@]}" --yes -o none
  else
    gone_or_fail "$lookup"
  fi
  azd env set DNS_RECORD_CREATED ""
fi
if [ "${ENTRA_APP_CREATED:-}" = "true" ] && [ -n "${ENTRA_CLIENT_ID:-}" ]; then
  log "Deleting the Microsoft Entra ID app registration $ENTRA_CLIENT_ID"
  if lookup="$(az ad app show --id "$ENTRA_CLIENT_ID" -o none 2>&1)"; then
    az ad app delete --id "$ENTRA_CLIENT_ID"
  else
    gone_or_fail "$lookup"
  fi
  azd env set ENTRA_CLIENT_ID ""
  azd env set ENTRA_APP_CREATED ""
fi
azd env set HORIZONDB_HOST ""
azd env set TMDB_ENRICHED ""
