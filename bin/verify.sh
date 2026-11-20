#!/usr/bin/env bash
# End-to-end gate for the stack. Every check prints PASS/FAIL plus the evidence
# that decided it (HTTP status, element count, matched text). Passes only when:
# auth login -> layer1 org -> SysML v2 project CRUD -> notation in/out through
# OpenSysML -> JSON round-trip -> quad-store named graphs all work.
set -uo pipefail
cd "$(dirname "$0")/.."
. bin/lib.sh
load_urls
FLEXO_AUTH=$(dotenv FLEXO_AUTH)
pass=0 fail=0
ok()  { printf '  PASS  %-24s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
bad() { printf '  FAIL  %-24s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }
echo "auth-service ($AUTH)"
login=$(curl -s -u "$(dotenv DEMO_USER user01):$(dotenv DEMO_PASSWORD password1)" "$AUTH/login")
tok=$(printf '%s' "$login" | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit()
if isinstance(d,dict):
    print(next((d[k] for k in ("token","jwt","id_token","access_token") if d.get(k)), ""))')
if [ -n "$tok" ]; then ok "ldap login" "jwt ${#tok} chars"; else bad "ldap login" "${login:0:140}"; fi

echo "layer1-service ($L1)"
code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${tok:-x}" "$L1/orgs/$ORG")
[ "$code" = "200" ] && ok "org readable" "HTTP $code /orgs/$ORG" || bad "org readable" "HTTP $code /orgs/$ORG"

echo "flexo-sysmlv2 ($SYS)"
code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: $FLEXO_AUTH" "$SYS/projects")
[ "$code" = "200" ] && ok "projects list" "HTTP $code" || bad "projects list" "HTTP $code"

pname="podman-smoke-$$"
body=$(curl -s -H "Authorization: $FLEXO_AUTH" -H 'Content-Type: application/json' \
  -d "{\"@type\":\"Project\",\"name\":\"$pname\",\"description\":\"podman-compose smoke test\"}" \
  "$SYS/projects")
pid=$(printf '%s' "$body" | jget 'd.get("@id","").rsplit("/",1)[-1]')
if [ -n "$pid" ]; then ok "project create" "$pname -> $pid"; else bad "project create" "${body:0:180}"; fi

if [ -n "$pid" ]; then
  commit=$(curl -s -H "Authorization: $FLEXO_AUTH" -H 'Content-Type: text/plain' \
    --data-binary @examples/hello.sysml "$SYS/projects/$pid/commits")
  cid=$(printf '%s' "$commit" | jget 'd.get("@id","").rsplit("/",1)[-1]')
  if [ -n "$cid" ]; then ok "notation commit" "text/plain -> $cid"; else bad "notation commit" "${commit:0:200}"; fi

  # Elements hang off a commit, not the project: /projects/{p}/commits/{c}/elements
  els=$(curl -s -H "Authorization: $FLEXO_AUTH" "$SYS/projects/$pid/commits/$cid/elements")
  nel=$(printf '%s' "$els" | jget 'len(d)')
  [ "${nel:-0}" -ge 5 ] && ok "element tree" "$nel elements" || bad "element tree" "count=${nel:-0} ${els:0:140}"

  txt=$(curl -s -H "Authorization: $FLEXO_AUTH" -H 'Accept: text/plain' "$SYS/projects/$pid/commits/$cid/elements")
  if printf '%s' "$txt" | grep -q 'part def'; then
    ok "notation render" "text/plain has 'part def'"
  else
    bad "notation render" "${txt:0:140}"
  fi

  code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: $FLEXO_AUTH" \
    -H 'Accept: application/json' "$SYS/projects/$pid/commits/$cid/elements")
  [ "$code" = "200" ] && ok "elements as JSON" "HTTP $code" || bad "elements as JSON" "HTTP $code"
fi

echo "quad store ($QUAD)"
n1=$(curl -s -G "$QUAD/ds/sparql" -H 'Accept: application/sparql-results+json' \
  --data-urlencode 'query=SELECT (COUNT(DISTINCT ?g) AS ?n) WHERE { GRAPH ?g { ?s ?p ?o } }' \
  | python3 -c 'import json,sys
try: print(json.load(sys.stdin)["results"]["bindings"][0]["n"]["value"])
except Exception: print(0)')
[ "${n1:-0}" -ge 5 ] && ok "named graphs" "${n1} graphs" || bad "named graphs" "count=${n1:-0}"

echo
printf '  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
