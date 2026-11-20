# OpenMBEE Flexo MMS + SysML v2 API, on Podman

A self-contained, reversible copy of the OpenMBEE "Flexo" stack: a SysML v2
repository with a REST API that accepts SysML v2 **textual notation** and gives
it back as JSON or text. Upstream ships `docker-compose` files in two repos
(`Open-MBEE/flexo-mms-deployment`, `Open-MBEE/flexo-mms-sysmlv2`); this project
is that topology translated to `podman-compose`, with the differences listed
below.

Verified on this box: 8 containers, `make verify` green (see *Verification*).

## Quick start

    make up          # creates .env, mints a token, starts, seeds, waits
    make verify      # end-to-end gate, PASS/FAIL per check
    make down        # stop, keep data
    make reset       # stop and delete all data (LDAP, TDB2, MinIO)

Nothing needs root: everything runs rootless under your own uid, and every
published port binds `127.0.0.1` by default (`BIND_ADDR` in `.env`).

## What runs

    127.0.0.1:8080  layer1-service          the MMS REST API (orgs, projects,
                                            users, groups, permissions)
    127.0.0.1:8082  auth-service            LDAP login -> JWT for layer1
    127.0.0.1:18083 sysmlv2-service         SysML v2 API: /projects, /commits,
                                            /elements, textual notation
    127.0.0.1:18081 store-service           blob/artifact store (MinIO backend)
    127.0.0.1:3030  quad-store-server       Fuseki + TDB2: the RDF graph store
    127.0.0.1:9000  minio-server            S3 API, used by store-service
    127.0.0.1:1389  openldap-server         demo directory (user01/user02)
      (internal)     opensysml              SysML v2 parser/validator over gRPC;
                                            this is what makes textual notation
                                            work

Data lives in named volumes (`openmbee_*`): TDB2 datasets, LDAP's database,
MinIO's objects. `make down` / `make up` therefore does not lose models;
`make reset` does.

## Ports that were moved

8081 and 8083 were already bound on this host, so store-service and the SysML v2
API publish on 18081 and 18083. Change `STORE_PORT` / `SYSMLV2_PORT` in `.env`
to move them; every port in `compose.yaml` is a `${*_PORT:-default}` variable so
a collision never needs a YAML edit.

The OpenSysML gRPC port is not published at all. Only sysmlv2-service talks to
it, over the private `openmbee` network.

## Deliberate differences from upstream

1. **`podman-compose`, not `docker-compose`.** Image names are fully qualified
   (`docker.io/...`) so rootless Podman never prompts for a registry, and every
   bind mount carries `:Z` for SELinux.
2. **TDB2 on a volume instead of `--file`.** Upstream starts Fuseki with
   `--file=/jena-fuseki/data/cluster.trig`, which builds an *in-memory* dataset:
   every restart silently drops the access-control graphs *and* every model.
   Here the store is TDB2 in a named volume, and `bin/seed.sh` POSTs
   `mount/cluster.trig` through the Graph Store Protocol, only when the cluster
   graph is absent. Idempotent, so `make up` is safe to re-run.
3. **Quad-store heap cut from 8 GiB to 2 GiB** (`QUAD_STORE_HEAP`). Upstream
   sets `-Xmx8192m -Xms8192m`, which makes JVM startup lazy and pointless on a
   dev box; 2 GiB with a 512 MiB initial heap starts in seconds.
4. **MinIO image moved.** `quay.io/minio/minio:latest` now requires a quay.io
   login; the Bitnami legacy build of the same server (`bitnamilegacy/minio`)
   is used instead, matching the LDAP image's provenance. Bitnami's data path
   is `/bitnami/minio/data`.
5. **No `depends_on`.** podman-compose 1.3 does not implement
   `condition: service_healthy`, and it resolves `depends_on` by looking up the
   dependency's *container* at creation time, which aborts the whole `up` when
   that container does not exist yet. Startup order is enforced instead by
   `bin/bootstrap.sh`, which starts the quad store, waits for a real 200 from
   its SPARQL endpoint, then starts the rest, then waits on layer1 and sysmlv2
   endpoints (`bin/wait-for.sh`).
6. **`up --no-recreate`.** Re-running `make up` on a live stack would otherwise
   try to `podman create` names that already exist. Consequence: after editing
   `compose.yaml` or an `env/*.env` file, run `make reset && make up` (or
   `podman rm -f` the affected container) to apply it.
7. **OpenSysML runs with `-allow-unauthenticated`.** sysml-grpc refuses to bind
   a non-loopback address without a bearer token. The port is unpublished, so
   the exposure is the private container network only; give it a token with
   `-token-file` if you ever publish it.
8. **sysmlv2-service pinned to `develop-SNAPSHOT`, not `v0.2.1`.** The `v0.2.1`
   image predates textual-notation support: it answers a `text/plain` commit
   with "Cannot transform this request's content to CommitRequest". Notation
   in and out is the whole point of bundling OpenSysML, so the tag tracks the
   branch that has it. Re-pin to a release tag once upstream cuts one.
9. **Secrets only in `.env`** (mode 600, gitignored). `env/*.env` carry topology
   and non-secret defaults. `bin/bootstrap.sh` generates `JWT_SECRET`,
   `S3_ACCESS_KEY`, `S3_SECRET_KEY` on first run and fills `FLEXO_AUTH`.

## Tokens

`auth-service` will mint a JWT from LDAP credentials:

    curl -u user01:password1 http://127.0.0.1:${AUTH_PORT:-8082}/login

`make up` also mints a one-year HS256 token with `bin/mint-token.py` and stores
it in `.env` as `FLEXO_AUTH`. The SysML v2 service uses it whenever a request
arrives without an `Authorization` header, so `curl http://127.0.0.1:18083/projects`
just works. The `username` claim must be an `mms:id` present in
`mount/cluster.trig` (`ldap/user/user01`), because layer1 resolves the caller as
`<root_context>/users/<username>`; a token naming a user that has no
`mms:User` node gets 401 even though the signature is valid.

    make token       # print it
    make login       # mint one from LDAP instead

## Verification

`bin/verify.sh` checks, printing PASS/FAIL and the evidence for each:

    auth login           LDAP credentials -> JWT
    org readable         GET /orgs/sysmlv2 with that JWT
    projects list        GET /projects with FLEXO_AUTH
    project create       POST a SysML v2 Project
    notation commit      POST text/plain SysML -> commit (needs opensysml)
    element tree         GET /commits/{c}/elements, expects >= 5 elements
    notation render      same URL as text/plain, expects 'part def'
    elements as JSON     same URL as application/json
    named graphs         SPARQL COUNT(DISTINCT ?g) on the quad store

Elements belong to a commit, not a project: the API is
`/projects/{p}/commits/{c}/elements`. A project-level `/elements` returns 404,
which looks like a broken service but is the spec.

The named-graphs check is the one that fails when the graph store is
misconfigured, which is the usual way this stack breaks. Each run leaves a
`podman-smoke-<epoch>` project in the store; they are throwaway, and
`make reset` clears them with everything else.

## Try it by hand

    make token > /tmp/tok
    curl -s -H "Authorization: $(cat /tmp/tok)" \
         -H 'Content-Type: text/plain' \
         --data-binary @examples/hello.sysml \
         http://127.0.0.1:18083/projects/sysmlv2/commits

    curl -s -H "Authorization: *** /tmp/tok)" -H 'Accept: text/plain' \
         http://127.0.0.1:18083/projects/sysmlv2/commits/<commit-id>/elements

`examples/hello.sysml` is a two-part model with a comment; it round-trips
through OpenSysML's parser, so a 200 there proves the textual-notation path.

## Layout

    compose.yaml            the stack (8 services, network `openmbee`)
    .env.example            template; `make up` copies it to .env (mode 600)
    env/*.env               per-service non-secret environment
    mount/cluster.trig      Flexo access-control seed (orgs, users, groups)
    bin/bootstrap.sh        up: secrets, token, containers, seed, org
    bin/seed.sh             idempotent TriG load into TDB2
    bin/verify.sh           end-to-end gate
    bin/mint-token.py       HS256 token minter (stdlib only)
    bin/wait-for.sh         poll a URL until it answers with an expected code
    bin/envset.py           read/replace one key in .env
    bin/lib.sh              dotenv()/load_urls() shared by the scripts
    examples/hello.sysml    notation round-trip fixture

`.env` is never `source`d: `FLEXO_AUTH` holds `Bearer eyJ...` with a space in
it, which the shell would try to run as a command. `bin/lib.sh` reads single
keys through `bin/envset.py` instead.

## Known limits

- Single-node, no HA, no TLS: this is a development/lab stack. Put a reverse
  proxy in front if it must face anything but loopback.
- `store-service` is wired to MinIO but the SysML v2 API does not yet push
  artifacts to it in this configuration; commits live in the quad store.
- Not quadlet/systemd-managed. `make up` after boot is the intended path;
  a `~/.config/containers/systemd` unit would need `podman-compose` replaced by
  explicit `podman run` lines, since quadlet does not consume compose files.
- Restart survival was checked by hand (`podman restart` of the quad store, then
  a SPARQL count), not by `verify.sh`.
