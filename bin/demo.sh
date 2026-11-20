#!/usr/bin/env bash
# Round-trip examples/hello.sysml through the SysML v2 API: parse the textual
# notation into a commit, then render that commit back as text.
#
# A fresh project is created on every run. POSTing the same model text twice
# into one project makes flexo-sysmlv2 (develop-SNAPSHOT) NPE inside its LDP
# parser, so reusing a project would make this non-repeatable.
set -euo pipefail
cd "$(dirname "$0")/.."
. bin/lib.sh
load_urls

AUTH="Authorization: $(dotenv FLEXO_AUTH)"
[ -n "${FLEXO_AUTH:-}" ] || true

name="podman-demo-$(date +%s)"
proj=$(curl -s -H "$AUTH" -H 'Content-Type: application/json' \
  -d "{\"@type\":\"Project\",\"name\":\"$name\",\"description\":\"demo\"}" \
  "$SYS/projects")
pid=$(printf '%s' "$proj" | jget 'd.get("@id","").rsplit("/",1)[-1]')
if [ -z "$pid" ]; then
  echo "could not create a project: $(printf '%s' "$proj" | head -c 200)" >&2
  exit 1
fi

commit=$(curl -s -X POST -H "$AUTH" -H 'Content-Type: text/plain' \
  --data-binary @examples/hello.sysml "$SYS/projects/$pid/commits")
cid=$(printf '%s' "$commit" | jget '(d[0] if isinstance(d,list) else d).get("@id","")')
if [ -z "$cid" ]; then
  echo "parse failed: $(printf '%s' "$commit" | head -c 300)" >&2
  exit 1
fi

curl -s -H "$AUTH" -H 'Accept: text/plain' \
  "$SYS/projects/$pid/commits/$cid/elements" > /tmp/demo-text.sysml

echo "project  $pid  ($name)"
echo "commit   $cid  from examples/hello.sysml"
echo "rendered back as text:"
echo
sed 's/^/  /' /tmp/demo-text.sysml
echo
echo "the model is now in the graph store; 'make graph' counts named graphs,"
echo "'make reset' throws the demo project away with everything else."
