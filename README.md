# OpenMBEE Flexo MMS + SysML v2 API, on Podman

A self-contained, reversible copy of the OpenMBEE "Flexo" stack: a SysML v2
repository with a REST API that accepts SysML v2 **textual notation** and gives
it back as JSON or text. Upstream ships `docker-compose` files in two repos
(`Open-MBEE/flexo-mms-deployment`, `Open-MBEE/flexo-mms-sysmlv2`); this project
is that topology translated to `podman-compose`, with the differences listed
below.

Verified here: 8 containers up, `make verify` 9 passed / 0 failed, models
survive `make down` + `make up`.

## Requirements

    podman            >= 4.4   (tested: 5.x, rootless, cgroup v2)
    podman-compose    >= 1.0   (tested: 1.3, the Python one, not the Go binary)
    python3, curl, make

About 6 GB of disk for images and first-start data, 4 GB RAM. No root, no
`sudo`, no Docker daemon. If `podman-compose` is missing:

    pip install --user podman-compose      # or: dnf/apt install podman-compose

Podman on a machine that also runs Docker needs nothing special: this stack
uses its own network, volumes and container names (`openmbee_*`).

This exists because a lot of shops (GTRI among them) standardise on rootless
Podman and will not accept a Docker daemon on developer workstations. Nothing
here needs root, a daemon socket, or the `docker` group: if `podman info` works
for your user, `make up` works. On an SELinux host the bind mounts already carry
`:Z`; on a machine behind a proxy set `HTTP_PROXY`/`HTTPS_PROXY` for the pulls
and everything else behaves the same.

## Quick start

    git clone https://github.com/mycr0ft/openmbee-podman.git
    cd openmbee-podman
    make up          # creates .env, mints a token, starts, seeds, waits
    make verify      # end-to-end gate, PASS/FAIL per check
    make down        # stop, keep data
    make reset       # stop and delete all data (LDAP, TDB2, MinIO)

`make up` is safe to re-run. First run generates `JWT_SECRET` and the MinIO
credentials into `.env` (mode 600, gitignored), mints a one-year SysML v2
token, starts the quad store first and waits for its SPARQL endpoint, then
starts the rest, then loads the access-control seed graph and creates the
`sysmlv2` org. Expect 60-90 seconds including image pulls.

Nothing needs root: everything runs rootless under your own uid, and every
published port binds `127.0.0.1` by default (`BIND_ADDR` in `.env`).

## First run: confirm it is actually working

Three checks, in order of what they prove. A 200 on the third one means the
whole chain works: LDAP, JWT, layer1 permissions, the SysML v2 API, TDB2 and
the OpenSysML parser.

**1. Log in against LDAP.** The seed graph ships two demo users, `user01`
(password `password1`) and `user02` (`password2`):

    curl -u user01:password1 http://127.0.0.1:8082/login

    {
      "token" : "eyJhbGciOiJIUzI1NiJ9.eyJhdWQiOiJmbGV4by1tbXMiLCJpc3MiOi..."
    }

That token is a layer1 credential, not a SysML v2 one. `make up` already minted
one for the SysML v2 API and stored it in `.env` as `FLEXO_AUTH`, so the
commands below need no token juggling.

**2. Read the org through layer1** (proves the token is accepted and the seed
graph is loaded):

    curl -s -H "Authorization: $(python3 bin/envset.py .env FLEXO_AUTH)" \
         http://127.0.0.1:8080/orgs/sysmlv2

You should get Turtle back: `@prefix m: <http://layer1-service/>`, then
`m:Cluster` and `m:Project` triples.

**3. Push a model in SysML v2 text and read it back** (proves the parser and
the graph store):

    make demo

    project  00c8abb2-27f5-4af5-9349-42cb0cc9291a  (podman-demo-1795145266)
    commit   5fc46e82-2269-4ced-b613-fd9c58dc59c9  from examples/hello.sysml
    rendered back as text:

      package HelloWorld {
          private import ScalarValues::*;

          part def Vehicle {
              attribute mass : Real;
              attribute wheelCount : Integer = 4;
          }
          ...
      }

`make demo` creates a throwaway project, POSTs `examples/hello.sysml` to it as
`text/plain`, and renders the resulting commit back as text. Parse -> graph ->
text in one command: if the text comes back, LDAP is serving, layer1 accepted
the token, OpenSysML parsed the notation, and TDB2 stored and returned it.

Then `make verify` for the full gate, `make graph` for the number of named
graphs in the quad store (it grows by four per demo run), and `make login` to
mint a layer1 token from LDAP by hand.

The same thing on the wire, if you want the shapes:

    AUTH="Authorization: $(python3 bin/envset.py .env FLEXO_AUTH)"
    SYS=http://127.0.0.1:$(python3 bin/envset.py .env SYSMLV2_PORT || echo 8083)

    PID=$(curl -s -X POST -H "$AUTH" -H 'Content-Type: application/json' \
            -d '{"@type":"Project","name":"hello"}' $SYS/projects \
          | python3 -c 'import json,sys; print(json.load(sys.stdin)["@id"].rsplit("/",1)[-1])')

    curl -s -X POST -H "$AUTH" -H 'Content-Type: text/plain' \
         --data-binary @examples/hello.sysml $SYS/projects/$PID/commits

    {
        "@id": "8b1c1e4a-...",
        "@type": "Commit",
        "owningProject": { "@id": "<the project id>" },
        "previousCommit": null
    }

    curl -s -H "$AUTH" -H 'Accept: text/plain' \
         $SYS/projects/$PID/commits/<commit-id>/elements

Use a fresh project per model: `develop-SNAPSHOT` fails inside its LDP parser
when identical text is committed twice into the same project, which is why
`make demo` starts from a new project every run.

## What runs

    127.0.0.1:8080  layer1-service          the MMS REST API (orgs, projects,
                                            users, groups, permissions)
    127.0.0.1:8082  auth-service            LDAP login -> JWT for layer1
    127.0.0.1:8083 sysmlv2-service         SysML v2 API: /projects, /commits,
                                            /elements, textual notation
    127.0.0.1:8081 store-service           blob/artifact store (MinIO backend)
    127.0.0.1:3030  quad-store-server       Fuseki + TDB2: the RDF graph store
    127.0.0.1:9000  minio-server            S3 API, used by store-service
    127.0.0.1:1389  openldap-server         demo directory (user01/user02)
      (internal)     opensysml              SysML v2 parser/validator over gRPC;
                                            this is what makes textual notation
                                            work

Data lives in named volumes (`openmbee_*`): TDB2 datasets, LDAP's database,
MinIO's objects. `make down` / `make up` therefore does not lose models;
`make reset` does.

## Ports

These are the defaults in `.env.example`. Every port in `compose.yaml` is a
`${*_PORT:-default}` variable, so if something is already listening, change the
value in `.env` and run `make up`; never edit the YAML. (The machine this was
built on had 8081 and 8083 taken, so its local, unshipped `.env` puts
store-service and sysmlv2-service on 18081/18083. The committed defaults are
the plain ones, so the commands above work on a clean host as written.)

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
arrives without an `Authorization` header, so `curl http://127.0.0.1:8083/projects`
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

`examples/hello.sysml` is a small two-part model (a package, a part def and a
comment). It parses through OpenSysML, so the 200 above proves the textual
notation path end to end, not just JSON round-tripping.

## License

Apache-2.0, the same license OpenMBEE uses upstream; the full text is in
`LICENSE`, taken verbatim from `Open-MBEE/flexo-mms-sysmlv2`. `NOTICE` records
that this is a derivative work of `Open-MBEE/flexo-mms-deployment` and
`Open-MBEE/flexo-mms-sysmlv2`, and lists the licenses of the third-party images
that are pulled at run time (none are redistributed here).

## Layout

    compose.yaml            the stack (8 services, network `openmbee`)
    .env.example            template; `make up` copies it to .env (mode 600)
    env/*.env               per-service non-secret environment
    mount/cluster.trig      Flexo access-control seed (orgs, users, groups)
    bin/bootstrap.sh        up: secrets, token, containers, seed, org
    bin/seed.sh             idempotent TriG load into TDB2
    bin/verify.sh           end-to-end gate
    bin/demo.sh             parse examples/hello.sysml into a new project,
                            render the commit back as text
    bin/graph-count.sh      named-graph count from the quad store
    bin/identity-probe.py   what the parser does to element identifiers
                            across projects, and on a package rename
    bin/mint-token.py       HS256 token minter (stdlib only)
    bin/wait-for.sh         poll a URL until it answers with an expected code
    bin/envset.py           read/replace one key in .env
    bin/lib.sh              dotenv()/load_urls() shared by the scripts
    examples/hello.sysml    notation round-trip fixture
    LICENSE                 Apache-2.0 (from flexo-mms-sysmlv2)
    NOTICE                  upstream attribution and image licenses

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
- Committing the *same* text twice into one project returns HTTP 500 from
  `develop-SNAPSHOT` (NPE in its LDP response parser, not a permission or
  notation problem). Use a new project per model until upstream fixes it.
- Element identifiers are name-based (UUIDv5) and stable across projects, but a
  commit records insertions only: rename a package and the new elements are
  added while the old ones stay, so that commit holds both. `bin/identity-probe.py`
  demonstrates it; do not read a commit's elements as a snapshot.
- Restart survival was checked by hand (`podman restart` of the quad store, then
  a SPARQL count), not by `verify.sh`.
