#!/usr/bin/env bash
# Shared setup for the azd hooks: strict mode, the repository root as working directory and the current azd
# environment values (Bicep outputs and values set by earlier hooks) exported as variables.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

set -a
eval "$(azd env get-values)"
set +a
az account set --subscription "$AZURE_SUBSCRIPTION_ID"

HORIZONDB_API="api-version=2026-10-01-preview"
HORIZONDB_ADMIN=movielogadmin
# Released app version this checkout deploys; the release pull request bumps it with the tag.
MOVIELOG_VERSION="${MOVIELOG_VERSION:-2.7.0}"
# shellcheck disable=SC2034
GHCR_REPOSITORY=ghcr.io/hellices/sample-movielog-horizondb
# shellcheck disable=SC2034
AGENT_VERSION=3.7.10
# Image sources for az acr import; override to deploy from a mirror or another registry in the tenant.
# shellcheck disable=SC2034
APP_IMAGE_SOURCE="${APP_IMAGE_SOURCE:-$GHCR_REPOSITORY:$MOVIELOG_VERSION}"
# shellcheck disable=SC2034
VLLM_IMAGE_SOURCE="${VLLM_IMAGE_SOURCE:-docker.io/vllm/vllm-openai:v0.32.0}"
# shellcheck disable=SC2034
AGENT_IMAGE_SOURCE="${AGENT_IMAGE_SOURCE:-$GHCR_REPOSITORY/applicationinsights-agent:$AGENT_VERSION}"

log() { printf '\n==> %s\n' "$*"; }

need() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || { echo "missing required tool: $tool" >&2; exit 1; }
  done
}

# Retries a command until it succeeds: retry <attempts> <seconds> <command...>
retry() {
  local attempts=$1 delay=$2 n=1
  shift 2
  until "$@"; do
    if [ "$n" -ge "$attempts" ]; then
      echo "failed after $attempts attempts: $*" >&2
      return 1
    fi
    n=$((n + 1))
    sleep "$delay"
  done
}

horizondb_rid() {
  echo "/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/$AZURE_RESOURCE_GROUP/providers/Microsoft.HorizonDb"
}

# ARM call on a HorizonDB resource path: horizondb <method> <path below the provider> [az rest options...]
horizondb() {
  local method=$1 path=$2
  shift 2
  az rest --method "$method" --uri "https://management.azure.com$(horizondb_rid)/$path?$HORIZONDB_API" "$@"
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

admin_psql() {
  PGHOST="$HORIZONDB_HOST" PGUSER="$HORIZONDB_ADMIN" PGPASSWORD="$HORIZONDB_ADMIN_PASSWORD" PGSSLMODE=require \
    psql -v ON_ERROR_STOP=1 "$@"
}
