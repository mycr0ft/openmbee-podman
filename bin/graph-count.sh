#!/usr/bin/env bash
# Print the number of named graphs with at least one triple in the quad store.
set -euo pipefail
cd "$(dirname "$0")/.."
. bin/lib.sh
load_urls
curl -s -G "$QUAD/ds/sparql" -H 'Accept: application/sparql-results+json' \
  --data-urlencode 'query=SELECT (COUNT(DISTINCT ?g) AS ?n) WHERE { GRAPH ?g { ?s ?p ?o } }' \
  | python3 -c 'import json,sys
try: print(json.load(sys.stdin)["results"]["bindings"][0]["n"]["value"])
except Exception: print(0)'
