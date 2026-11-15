#!/usr/bin/env python3
"""Embed catalog.movie_docs.doc with one embedding model and store the vectors in HorizonDB.

--model openai (default) uses Azure OpenAI text-embedding-3-large shortened to 1,536 dimensions and fills the
embedding column. Authentication uses a Microsoft Entra token from the Azure CLI (role: Cognitive Services OpenAI
User), so the Azure OpenAI account can keep key authentication disabled.

--model bge uses the Korean BGE-M3 (dragonkue/BGE-m3-ko, 1,024 dimensions) served by an OpenAI-compatible embeddings
server (vLLM in the sample) at EMBEDDINGS_BGE_URL (/v1/embeddings, no authentication) and fills embedding_bge. The
request names EMBEDDINGS_BGE_MODEL (default dragonkue/BGE-m3-ko), which must equal the served model name.

Only rows whose column of the selected model is NULL are processed (new or changed documents); --all re-embeds
every row, which is required after changing the model or dimensions. psql must be on PATH; connection settings come
from the standard PGHOST, PGDATABASE, PGUSER, PGPASSWORD and PGSSLMODE variables.

  AZURE_OPENAI_ENDPOINT=https://<name>.openai.azure.com/ python3 data/embed_catalog.py
  EMBEDDINGS_BGE_URL=http://localhost:8081 python3 data/embed_catalog.py --model bge
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

DEPLOYMENT = os.environ.get("AZURE_OPENAI_EMBEDDING_DEPLOYMENT", "text-embedding-3-large")
# text-embedding-3-large is shortened to the vector(1536) column; the app requests the same size.
DIMENSIONS = 1536
API_VERSION = "2024-10-21"
BGE_MODEL = os.environ.get("EMBEDDINGS_BGE_MODEL", "").strip() or "dragonkue/BGE-m3-ko"
# Inputs per request, the same as the app.
BATCH = 32
# Column of catalog.movie_docs and vector size per model; the column name never comes from user input.
MODELS = {"openai": ("embedding", DIMENSIONS), "bge": ("embedding_bge", 1024)}


def psql(*args: str) -> str:
    return subprocess.run(["psql", "-X", "-v", "ON_ERROR_STOP=1", *args], check=True, capture_output=True,
                          text=True).stdout


def token() -> str:
    return subprocess.run(["az", "account", "get-access-token", "--resource", "https://cognitiveservices.azure.com",
                           "--query", "accessToken", "-o", "tsv"], check=True, capture_output=True,
                          text=True).stdout.strip()


def embed(url: str, headers: dict[str, str], payload: dict) -> list[list[float]]:
    body = json.dumps(payload).encode()
    for attempt in range(6):
        request = urllib.request.Request(url, data=body, method="POST",
                                         headers={**headers, "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                data = json.load(response)["data"]
                return [item["embedding"] for item in sorted(data, key=lambda item: item["index"])]
        except urllib.error.HTTPError as ex:
            if ex.code in (429, 500, 503) and attempt < 5:
                time.sleep(int(ex.headers.get("retry-after", 2 ** attempt)))
                continue
            raise
    raise RuntimeError("unreachable")


def sql_text(text: str) -> str:
    # Dollar quoting avoids escaping; the tag is chosen to not occur in the text.
    tag = "$doc$"
    while tag in text:
        tag = tag[:-1] + "x$"
    return tag + text + tag


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--model", choices=sorted(MODELS), default="openai", help="embedding model (default: openai)")
    parser.add_argument("--all", action="store_true", help="re-embed every row, not only rows without a vector")
    args = parser.parse_args()
    column, dimensions = MODELS[args.model]
    env = "AZURE_OPENAI_ENDPOINT" if args.model == "openai" else "EMBEDDINGS_BGE_URL"
    endpoint = os.environ.get(env)
    if not endpoint:
        print(f"{env} is required", file=sys.stderr)
        return 2
    where = "" if args.all else f" WHERE {column} IS NULL"
    rows = json.loads(psql("-Atc", "SELECT coalesce(json_agg(json_build_object('id', tmdb_id, 'doc', doc)"
                                   " ORDER BY tmdb_id), '[]') FROM catalog.movie_docs" + where))
    print(f"{len(rows)} documents to embed", file=sys.stderr)
    if not rows:
        return 0
    if args.model == "openai":
        url = f"{endpoint.rstrip('/')}/openai/deployments/{DEPLOYMENT}/embeddings?api-version={API_VERSION}"
        headers = {"Authorization": f"Bearer {token()}"}
        options = {"dimensions": DIMENSIONS}
    else:
        url = f"{endpoint.rstrip('/')}/v1/embeddings"
        headers = {}
        options = {"model": BGE_MODEL}
    # The file holds partial vectors until psql loads it, so remove it on every exit path.
    fd, path = tempfile.mkstemp(suffix=".sql")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as out:
            out.write("BEGIN;\n")
            for start in range(0, len(rows), BATCH):
                batch = rows[start:start + BATCH]
                vectors = embed(url, headers, {"input": [row["doc"] for row in batch], **options})
                if len(vectors) != len(batch) or any(len(vector) != dimensions for vector in vectors):
                    raise RuntimeError(f"{args.model} returned an unexpected number or size of embeddings")
                for row, vector in zip(batch, vectors):
                    literal = "[" + ",".join(f"{v:.7g}" for v in vector) + "]"
                    # Matching the embedded text too leaves a row reloaded meanwhile NULL for the next run.
                    out.write(f"UPDATE catalog.movie_docs SET {column} = '{literal}'::vector, embedded_at = now()"
                              f" WHERE tmdb_id = {int(row['id'])} AND doc = {sql_text(row['doc'])};\n")
                print(f"  embedded {min(start + BATCH, len(rows))}/{len(rows)}", file=sys.stderr)
            out.write("COMMIT;\n")
        psql("-q", "-f", path)
    finally:
        os.unlink(path)
    print(psql("-Atc", f"SELECT count(*) || ' documents, ' || count({column}) || ' embedded with {args.model}'"
                       " FROM catalog.movie_docs"), end="", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
