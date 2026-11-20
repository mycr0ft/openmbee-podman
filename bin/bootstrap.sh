#!/usr/bin/env bash
# Bring the stack up from nothing: secrets, token, containers, seed, org.
# Idempotent; re-run it after `make down` or a reboot.
set -euo pipefail
cd "$(dirname "$0")/.."
. bin/lib.sh

COMPOSE=(podman-compose -p openmbee)
say() { printf '\n%s\n' "$*"; }

say "1/7 environment"
if [ ! -f .env ]; then
  cp .env.example .env
  chmod 600 .env
  echo "  created .env from .env.example"
fi
cur=$(dotenv JWT_SECRET)
if [ "$cur" = "CHANGEME" ] || [ -z "$cur" ]; then
  python3 bin/envset.py .env JWT_SECRET "$(openssl rand -hex 32)"
  echo "  generated JWT_SECRET"
fi
for key in S3_ACCESS_KEY S3_SECRET_KEY; do
  cur=$(dotenv "$key")
  if [ "$cur" = "CHANGEME" ] || [ -z "$cur" ]; then
    python3 bin/envset.py .env "$key" "flexo$(openssl rand -hex 8)"
    echo "  generated $key"
  fi
done
load_urls

say "2/7 long-lived bearer token"
tok=$(python3 bin/mint-token.py --secret "$(dotenv JWT_SECRET)" \
        --audience "$(dotenv JWT_AUDIENCE flexo-mms-audience)" \
        --issuer "$(dotenv JWT_DOMAIN http://flexo-mms-services)" \
        --user "ldap/user/$(dotenv DEMO_USER user01)" --groups super_admins)
python3 bin/envset.py .env FLEXO_AUTH "$tok"
export FLEXO_AUTH="$tok"
echo "  FLEXO_AUTH minted: ldap/user/$(dotenv DEMO_USER user01) in super_admins, 1 year"

say "3/7 quad store"
# --no-recreate: re-running `make up` on a live stack must be a no-op, and
# podman-compose otherwise tries to `podman create` a name that already exists.
"${COMPOSE[@]}" up -d --no-recreate quad-store-server
bin/wait-for.sh quad-store "$QUAD/ds/sparql?query=ASK%7B%7D" 90 '200'

say "4/7 access-control seed"
# Before layer1 starts, like upstream's --file: layer1 answers 403 to every
# request from a user whose mms:User / policy graph is not in the store yet.
bin/seed.sh

say "5/7 remaining services"
# By name, excluding the quad store: passing it again makes podman-compose try
# to create a container that already exists (it prints an error and carries on,
# but the noise hides real failures).
mapfile -t rest < <("${COMPOSE[@]}" config --services | grep -vx quad-store-server)
"${COMPOSE[@]}" up -d --no-recreate "${rest[@]}"
bin/wait-for.sh layer1 "$L1/" 120
bin/wait-for.sh sysmlv2 "$SYS/" 180 '404'

say "6/7 org '$ORG'"
code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: $FLEXO_AUTH" "$L1/orgs/$ORG")
if [ "$code" = "200" ]; then
  echo "  org exists"
else
  code=$(curl -s -o /dev/null -w '%{http_code}' -X PUT \
    -H "Authorization: $FLEXO_AUTH" -H 'Content-Type: text/turtle' --data-binary @- \
    "$L1/orgs/$ORG" <<TTL
@prefix dct: <http://purl.org/dc/terms/> .
<> dct:title "$ORG"@en .
TTL
  )
  case "$code" in
    200|201|204) echo "  org created (HTTP $code)" ;;
    *) echo "  org create failed: HTTP $code (see: make logs)" >&2; exit 1 ;;
  esac
fi

say "7/7 demo project"
demo=$(dotenv DEMO_PROJECT "")
if [ -n "$demo" ]; then
  echo "  project hello ($demo)"
else
  # sysmlv2-service creates the backing project through store-service, which can
  # still be warming up: a 500 here is transient, so retry rather than fail.
  for i in 1 2 3 4 5; do
    body=$(curl -s -H "Authorization: $(dotenv FLEXO_AUTH)" -H 'Content-Type: application/json' \
      -d '{"@type":"Project","name":"hello","description":"first-run demo"}' \
      "$SYS/projects")
    demo=$(printf '%s' "$body" | jget 'd.get("@id","").rsplit("/",1)[-1]')
    [ -n "$demo" ] && break
    echo "  project create attempt $i/5 failed, retrying in 3s"
    sleep 3
  done
  if [ -n "$demo" ]; then
    printf 'DEMO_PROJECT=%s\n' "$demo" >> .env
    echo "  created project hello ($demo, saved as .env DEMO_PROJECT)"
  else
    echo "  project create failed: ${body:0:160} (see: make logs)" >&2
  fi
fi

say "ready"
cat <<EOF
  layer1      $L1
  auth        $AUTH/login   (curl -u $(dotenv DEMO_USER user01):$(dotenv DEMO_PASSWORD password1))
  store       $STORE
  sysmlv2     $SYS/projects
  quad store  $QUAD
  notation    opensysml:50051 (internal network only)

  token:  make token      (.env FLEXO_AUTH, Bearer, 1 year)
  gate:   make verify
EOF
