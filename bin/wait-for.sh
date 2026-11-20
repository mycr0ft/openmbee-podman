#!/usr/bin/env bash
# wait-for.sh NAME URL [TRIES] [EXPECT]
# Waits until URL answers with an HTTP status matching EXPECT (a regex, e.g.
# '200|404'); with no EXPECT any non-000 status counts. podman-compose only
# orders startup, it never waits for readiness, so every script polls endpoints.
set -uo pipefail
name=$1 url=$2 tries=${3:-60} expect=${4:-}
for i in $(seq 1 "$tries"); do
  # curl prints 000 and exits non-zero when nothing is listening; `|| true`
  # keeps that from being appended to the code ('000000' would look like a hit).
  code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$url" 2>/dev/null) || true
  [ -z "$code" ] && code=000
  if [ -n "$expect" ]; then
    [[ $code =~ ^($expect)$ ]] && { printf '  %-16s up (%s)\n' "$name" "$code"; exit 0; }
  elif [ "$code" != "000" ]; then
    printf '  %-16s up (%s)\n' "$name" "$code"; exit 0
  fi
  sleep 1
done
echo "  $name FAILED: $url did not answer '${expect:-any}' after ${tries}s" >&2
exit 1
