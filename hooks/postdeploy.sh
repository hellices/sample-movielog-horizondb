#!/usr/bin/env bash
# azd postdeploy: deploy the released MovieLog image and fill the catalog.
#   1. Copy the release image, the Application Insights agent init image and the vLLM image into ACR (az acr import)
#   2. Start vLLM with bge-m3-ko on the GPU spot node, then apply the app Deployment; switch to the 3.7.10 agent init image when the managed injection is older than 3.7.9
#   3. On the first run load the catalog, embed it with both models and build the vector indexes and the AGE graph
#   4. Optional load generator, Grafana dashboard and HTTPS endpoint (APP_HOST)
# shellcheck source=hooks/lib.sh
source "$(dirname "$0")/lib.sh"

# A deploy-only run (azd deploy) must not rely on a kubeconfig left by postprovision.
az aks get-credentials -g "$AZURE_RESOURCE_GROUP" -n "$AZURE_AKS_CLUSTER_NAME" --overwrite-existing -o none

log "Importing $APP_IMAGE_SOURCE and $AGENT_IMAGE_SOURCE into $AZURE_CONTAINER_REGISTRY_NAME"
az acr import -n "$AZURE_CONTAINER_REGISTRY_NAME" --source "$APP_IMAGE_SOURCE" \
  --image "movielog:$MOVIELOG_VERSION" --force -o none
az acr import -n "$AZURE_CONTAINER_REGISTRY_NAME" --source "$AGENT_IMAGE_SOURCE" \
  --image "observability/applicationinsights-agent:$AGENT_VERSION" --force -o none
az acr import -n "$AZURE_CONTAINER_REGISTRY_NAME" --source "$VLLM_IMAGE_SOURCE" \
  --image "vllm/vllm-openai:${VLLM_IMAGE_SOURCE##*:}" --force -o none
digest_of() { az acr repository show -n "$AZURE_CONTAINER_REGISTRY_NAME" --image "$1" --query digest -o tsv; }
APP_IMAGE="$AZURE_CONTAINER_REGISTRY_ENDPOINT/movielog@$(digest_of "movielog:$MOVIELOG_VERSION")"
AGENT_IMAGE="$AZURE_CONTAINER_REGISTRY_ENDPOINT/observability/applicationinsights-agent@$(digest_of "observability/applicationinsights-agent:$AGENT_VERSION")"
VLLM_IMAGE="$AZURE_CONTAINER_REGISTRY_ENDPOINT/vllm/vllm-openai@$(digest_of "vllm/vllm-openai:${VLLM_IMAGE_SOURCE##*:}")"
export APP_IMAGE AGENT_IMAGE VLLM_IMAGE
echo "app image: $APP_IMAGE"

export AZURE_OPENAI_ENDPOINT ENTRA_TENANT_ID="$AZURE_TENANT_ID" ENTRA_CLIENT_ID="${ENTRA_CLIENT_ID:-}"
export SPRING_PROFILES_ACTIVE=aks
if [ -n "$ENTRA_CLIENT_ID" ]; then
  SPRING_PROFILES_ACTIVE=aks,entra
fi

log "Starting vLLM with dragonkue/BGE-m3-ko on the GPU spot node (first start downloads the model)"
# shellcheck disable=SC2016
envsubst '$VLLM_IMAGE' < k8s/40-embeddings-vllm.yaml | kubectl apply -f -
kubectl rollout status deploy/embeddings -n movielog --timeout=25m

injection="$(kubectl get deploy movielog -n movielog -o jsonpath='{.spec.template.metadata.annotations.instrumentation\.opentelemetry\.io/inject-java}' 2>/dev/null || true)"
if [ "$injection" = "false" ]; then
  # Already switched to the custom agent init image: kubectl apply would be rejected, so only roll the image.
  log "Updating the app image"
  kubectl set image deploy/movielog -n movielog "movielog=$APP_IMAGE"
  kubectl set env deploy/movielog -n movielog EMBEDDINGS_BGE_URL=http://embeddings.movielog.svc.cluster.local \
    EMBEDDING_DEFAULT_MODEL=bge
  # Keep the custom agent init image at the digest imported above.
  patch="$(tmpfile)"
  envsubst < k8s/21-agent-3.7.10.patch.yaml > "$patch"
  kubectl patch deployment movielog -n movielog --type strategic --patch-file "$patch"
  rm -f "$patch"
else
  log "Deploying MovieLog"
  envsubst < k8s/20-movielog.yaml | kubectl apply -f -
fi
kubectl rollout status deploy/movielog -n movielog --timeout=10m

injected="$(kubectl get pods -n movielog -l app=movielog -o jsonpath='{.items[0].spec.initContainers[*].image}')"
injected_version="$(printf '%s' "$injected" | sed -nE 's/.*auto-?instrumentation[^:]*:([0-9]+\.[0-9]+\.[0-9]+).*/\1/p')"
if [ -n "$injected_version" ] && [ "$(printf '%s\n3.7.9\n' "$injected_version" | sort -V | head -1)" != "3.7.9" ]; then
  # Micrometer metrics need agent 3.7.9+; replace the managed injection in the two steps 21-agent-*.yaml describes.
  log "Managed agent $injected_version is older than 3.7.9: switching to the $AGENT_VERSION init image"
  kubectl patch deployment movielog -n movielog --type merge \
    -p '{"spec":{"template":{"metadata":{"annotations":{"instrumentation.opentelemetry.io/inject-java":"false"}}}}}'
  kubectl rollout status deploy/movielog -n movielog --timeout=10m
  patch="$(tmpfile)"
  envsubst < k8s/21-agent-3.7.10.patch.yaml > "$patch"
  kubectl patch deployment movielog -n movielog --type strategic --patch-file "$patch"
  rm -f "$patch"
  kubectl rollout status deploy/movielog -n movielog --timeout=10m
fi

# Idempotent; adds the columns a newer release needs when only azd deploy runs.
admin_psql -d movielog -q -f db/10-schema.sql
movies="$(admin_psql -d movielog -Atc 'SELECT count(*) FROM catalog.movie_docs')"
if [ "$movies" = "0" ]; then
  log "Loading the catalog (Wikidata and Wikipedia, about 10 minutes)"
  python3 data/build_catalog.py
  admin_psql -d movielog -q -f data/out/catalog.sql
  TMDB_ENRICHED=""   # a freshly loaded catalog has no posters, whatever an earlier environment recorded
fi
# TMDB enrichment is tracked on its own, so a failed run or a token added later is retried on the next deploy.
if [ -n "${TMDB_API_TOKEN:-}" ] && [ "${TMDB_ENRICHED:-}" != "true" ]; then
  log "Filling posters from TMDB"
  if [ ! -f data/out/catalog.json ]; then
    python3 data/build_catalog.py   # regenerates the TMDB id list; UPDATEs skip movies that are not loaded
  fi
  python3 data/enrich_tmdb.py
  admin_psql -d movielog -q -f data/out/tmdb.sql
  azd env set TMDB_ENRICHED true
fi
# Each step checks what is already in the database, so a rerun after a failure resumes where it stopped.
missing() { admin_psql -d movielog -Atc "SELECT count(*) FROM catalog.movie_docs WHERE $1 IS NULL"; }
embed() {
  PGHOST="$HORIZONDB_HOST" PGUSER="$HORIZONDB_ADMIN" PGPASSWORD="$HORIZONDB_ADMIN_PASSWORD" PGDATABASE=movielog \
    PGSSLMODE=require EMBEDDINGS_BGE_URL=http://localhost:18081 python3 data/embed_catalog.py "$@"
}
missing_openai="$(missing embedding)"
if [ "$missing_openai" != "0" ]; then
  log "Embedding $missing_openai documents with Azure OpenAI"
  # The operator's Cognitive Services OpenAI User role can take a few minutes to apply.
  retry 10 60 embed --model openai
fi
missing_bge="$(missing embedding_bge)"
if [ "$missing_bge" != "0" ]; then
  log "Embedding $missing_bge documents with bge-m3-ko through vLLM"
  # The subshell stops its port-forward on exit, also when the retries are exhausted.
  (
    kubectl port-forward -n movielog svc/embeddings 18081:80 >/dev/null 2>&1 &
    trap 'kill $! 2>/dev/null || true' EXIT
    retry 5 15 embed --model bge
  )
fi

indexes="$(admin_psql -d movielog -Atc "SELECT count(*) FROM pg_indexes WHERE schemaname = 'catalog'
  AND indexname IN ('movie_docs_embedding_diskann', 'movie_docs_embedding_bge_diskann')")"
if [ "$indexes" != "2" ]; then
  log "DiskANN vector indexes"
  admin_psql -d movielog -q -f db/20-vector-index.sql
fi
graph="$(admin_psql -d movielog -Atc "SELECT count(*) FROM ag_catalog.ag_graph WHERE name = 'movie_graph'")"
rebuilt=false
if [ "$graph" = "0" ] || [ "$missing_bge" != "0" ]; then
  # SIMILAR_TO follows the bge embeddings, so the graph is rebuilt whenever they change.
  log "Building the AGE graph"
  admin_psql -d movielog -q -f db/30-graph.sql
  rebuilt=true
fi
sync="$(admin_psql -d movielog -Atc "SELECT to_regprocedure('catalog.process_graph_queue(integer,boolean)') IS NOT NULL")"
if [ "$sync" != "t" ] || [ "$rebuilt" = "true" ]; then
  log "Installing the graph sync"
  admin_psql -d movielog -q -f db/40-graph-sync.sql
fi
kubectl scale deploy/movielog -n movielog --replicas=2

if [ "${ENABLE_LOADGEN:-true}" != "false" ]; then
  log "Load generator"
  kubectl create configmap loadgen -n movielog --from-file=loadgen/loadgen.py --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -f k8s/30-loadgen.yaml
fi

log "Grafana dashboard"
dashboard="$(tmpfile)"
python3 - "$APPLICATIONINSIGHTS_ID" > "$dashboard" <<'PY'
import json, sys
d = json.load(open("grafana/movielog-horizondb-dashboard.json", encoding="utf-8"))
for v in d["templating"]["list"]:
    if v["name"] == "appinsights":
        v.update(query=sys.argv[1], current={"text": sys.argv[1], "value": sys.argv[1]}, hide=2)
json.dump(d, sys.stdout, ensure_ascii=False)
PY
# The operator's Grafana Admin role can take a few minutes to apply.
retry 10 30 az grafana dashboard create -g "$AZURE_RESOURCE_GROUP" -n "$AZURE_GRAFANA_NAME" \
  --definition "@$dashboard" --overwrite true -o none
rm -f "$dashboard"

if [ -n "${APP_HOST:-}" ]; then
  bash hooks/https.sh
else
  log "Done. Open the app with: kubectl port-forward -n movielog deploy/movielog 8080:8080"
fi
