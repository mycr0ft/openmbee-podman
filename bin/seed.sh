#!/usr/bin/env bash
# Load the TriG access-control seed into the quad store, once.
#
# Upstream hands cluster.trig to Fuseki with --file, which builds an in-memory
# dataset that is thrown away on every container start. Here the store is TDB2
# on a named volume, so the seed is POSTed through the Graph Store Protocol and
# only when the cluster graph is still missing. Idempotent: safe on every `up`.
set -euo pipefail
cd "$(dirname "$0")/.."
. bin/lib.sh
load_urls
FUSEKI=${FUSEKI_URL:-$QUAD}
SEED=${SEED_FILE:-mount/cluster.trig}
ASK='ASK { GRAPH ?g { <http://layer1-service/> a <https://mms.openmbee.org/rdf/ontology/Cluster> } }'

ask() {
  curl -s -G "$FUSEKI/ds/sparql" -H 'Accept: application/sparql-results+json' \
    --data-urlencode "query=$ASK" | grep -q '"boolean" *: *true'
}

if ask; then
  echo "  seed               already present"
  exit 0
fi

code=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
  -H 'Content-Type: application/trig' --data-binary "@$SEED" "$FUSEKI/ds/data")
[ "$code" = "200" ] || [ "$code" = "204" ] || { echo "seed failed: HTTP $code" >&2; exit 1; }
# A GSP POST is acknowledged before TDB2 has finished indexing, so the graph can
# still be invisible for a moment. Poll rather than fail on the first look.
for _ in $(seq 1 15); do ask && break; sleep 1; done
ask || { echo "seed loaded but cluster graph is still absent" >&2; exit 1; }
echo "  seed               loaded $SEED (HTTP $code)"
