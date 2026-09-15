# PostgreSQL 18 on Rocky Linux 10.2 — golden image

A functional port of `docker-library/postgres:18` (bookworm) onto a Rocky Linux
10.2 base. `docker-entrypoint.sh` and `docker-ensure-initdb.sh` are byte-for-byte
upstream, so every documented environment variable and behaviour of the
reference image works unchanged.

## Published images

CI builds three flavors for `linux/amd64` + `linux/arm64` on every push to
`master` and publishes multi-arch manifests to `ghcr.io/<owner>/postgresql`.
Each (flavor, arch) build must pass `smoke-test.sh` on a native runner before
it's published — see the workflow file for the details.

| Flavor | Tag | Build args |
|---|---|---|
| default | `18.6-rocky10.2` | none |
| JIT | `18.6-rocky10.2-jit` | `WITH_JIT=1` |
| GIS | `18.6-rocky10.2-gis` | `WITH_GIS=1` |

The tag's version segment comes from `PG_VERSION`/`ROCKY_TAG` in the
Containerfile, so it can't drift from the pin. The first push creates the
GHCR package as **private** — flip it to public once, or nothing can pull it.

## Build

```bash
docker build \
  --build-arg ROCKY_TAG=10.2.20260525.0 \
  --build-arg PG_VERSION=18.6 \
  --build-arg IMAGE_REVISION="$(git rev-parse HEAD)" \
  --build-arg IMAGE_CREATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  -t registry.example.com/platform/postgresql:18.6-rocky10.2 .

./smoke-test.sh registry.example.com/platform/postgresql:18.6-rocky10.2
```

This builds for the local machine's architecture only. CI is what publishes
the multi-arch manifests; don't try to replicate that by hand.

Build args worth knowing:

| Arg | Default | Notes |
|---|---|---|
| `ROCKY_TAG` | `10.2.20260525.0` | prefer a digest for real reproducibility |
| `PG_VERSION` | `18.6` | exact PGDG minor; never leave this floating |
| `GOSU_STRATEGY` | `download` | `setpriv-shim` for builders with no github.com egress |
| `WITH_JIT` | `0` | `1` installs `postgresql18-llvmjit` (+~200 MB) |
| `WITH_NSS_WRAPPER` | `0` | only needed for arbitrary-uid runs; pulls EPEL |
| `WITH_GIS` | `0` | `1` installs PostGIS (`postgis${POSTGIS_MAJOR}_18`, +~150 MB) |
| `POSTGIS_MAJOR` | `35` | PostGIS release feeding the PGDG package name; only used when `WITH_GIS=1` |
| `HARDEN` | `1` | strips setuid/setgid bits from the base OS |
| `PGDG_REPO_RPM_SHA256` | *(empty)* | pin the PGDG repo RPM; the build prints the hash when unset |

On the first build, grab the printed PGDG repo RPM sha256 and pin it, and
resolve `ROCKY_TAG` to a digest — until both are pinned the build is
reproducible in intent but not in fact.

## What is preserved from upstream

- `postgres` uid/gid **999**, home `/var/lib/postgresql` mode `1777`
- `PGDATA=/var/lib/postgresql/18/docker`, `VOLUME /var/lib/postgresql` — the
  18+ layout, which is what makes `pg_upgrade --link` between majors possible
- `/docker-entrypoint-initdb.d` with `.sh`, `.sql`, `.sql.gz`, `.sql.xz`,
  `.sql.zst` support (hence gzip/xz/zstd in the image)
- `POSTGRES_PASSWORD[_FILE]`, `POSTGRES_USER`, `POSTGRES_DB`,
  `POSTGRES_INITDB_ARGS`, `POSTGRES_INITDB_WALDIR`, `POSTGRES_HOST_AUTH_METHOD`,
  `PGDATA` — all handled by the upstream entrypoint
- `gosu` step-down from root; `docker-ensure-initdb.sh` /
  `docker-enforce-initdb.sh`
- `listen_addresses = '*'` patched into the shipped `postgresql.conf.sample`
- `en_US.utf8` locale and `LANG`, `less` as psql's pager
- `/var/run/postgresql` mode `3777`, `STOPSIGNAL SIGINT`, `EXPOSE 5432`,
  `CMD ["postgres"]`

Because uid/gid and `PGDATA` match, a volume written by `postgres:18` can be
mounted by this image and vice versa.

## Deliberate divergences

1. **PGDG yum repo, not apt.** Binaries in `/usr/pgsql-18/bin` (on `PATH`),
   libraries and the sample config in `/usr/pgsql-18/share`.
2. **JIT is off by default** (`WITH_JIT=1` to enable). The LLVM runtime is the
   single largest optional add, and a net loss for most OLTP workloads.
3. **`nss_wrapper` is off by default** (`WITH_NSS_WRAPPER=1` to enable). Only
   needed for arbitrary-uid runs (OpenShift-style) with no `/etc/passwd`
   entry; without it those runs fail at `initdb`. Comes from EPEL — confirm
   it's on your EL10 mirror first.
4. **PostGIS is off by default** (`WITH_GIS=1` to enable). Upstream doesn't
   ship it at all — it's a PGDG extra, versioned via `POSTGIS_MAJOR`. Pulls in
   GEOS/GDAL/PROJ (+~150 MB); `shp2pgsql`/`raster2pgsql` live in a separate
   `-utils` package, not installed here.
5. **`logging_collector` is forced off**, matching upstream. The PGDG sample
   ships it `on`, which routes server logs to `$PGDATA/log/*.log` instead of
   stderr — invisible to `docker logs`/`kubectl logs`. This patches the
   *sample* conf, so it only affects freshly-initialized volumes; existing
   ones need `-c logging_collector=off` or a manual conf edit.
6. **No `HEALTHCHECK` instruction**, matching upstream. `docker-healthcheck.sh`
   still ships in the image (`pg_isready` over loopback TCP) but isn't wired
   up — Docker's `HEALTHCHECK` config isn't representable in a plain OCI
   image config, and this image targets full OCI compatibility. Wire it up
   yourself with `--health-cmd docker-healthcheck.sh` or an orchestrator-level
   probe if you want it.
7. **setuid/setgid bits are stripped** (`HARDEN=1`). Nothing PostgreSQL needs
   is setuid; this image isn't meant for installing packages at runtime.
8. **`/var/lib/pgsql` exists but is unused.** Left in place so `rpm -V` stays
   clean; `PGDATA` is elsewhere.
9. **`systemd` may be pulled in** as an RPM scriptlet dependency. Nothing
   runs it — a two-stage `dnf --installroot` build would avoid it, but that
   was skipped to keep the Containerfile auditable.

## Production notes

- **Volume path:** mount at `/var/lib/postgresql`, not `.../data` — the 18+
  `VOLUME` moved, and mounting the old path silently loses data on re-create.
- **Data checksums** are on by default in 18; `--data-checksums` is redundant
  but harmless.
- **`io_method=io_uring`** needs a custom seccomp profile (Docker's default
  blocks `io_uring_*`); `worker` (the default) is fine for most fleets.
- **`/dev/shm`:** Docker's 64 MB default breaks parallel queries — set
  `shm_size` (compose) or a `Memory`-medium `emptyDir` (Kubernetes).
- **Shutdown:** `SIGINT` is a fast shutdown; give it a long grace period
  (120s+) or a busy server gets SIGKILLed mid-checkpoint.
- **Non-root:** the entrypoint starts as root to chown `PGDATA`, then drops to
  999. Once initialized, pin `user: "999:999"` and `no-new-privileges`.
- **SELinux hosts:** bind mounts need `:Z`/`:z` or the container can't read
  `/docker-entrypoint-initdb.d`.
- **x86-64-v3 required on amd64** — Rocky 10 dropped v2 support. Doesn't
  apply to the `arm64` build.
- **Rebuild cadence:** pinned versions don't self-update. Rebuild on
  PGDG/Rocky advisories, run `smoke-test.sh`, then promote.

## Keeping in sync with upstream

```bash
curl -fsSL -o /tmp/dockerfile.new \
  https://raw.githubusercontent.com/docker-library/postgres/master/18/bookworm/Dockerfile
diff -u Dockerfile.upstream-bookworm /tmp/dockerfile.new
```

Re-pull `docker-entrypoint.sh` and `docker-ensure-initdb.sh` from the same
path whenever they change; they're meant to stay unmodified here.
