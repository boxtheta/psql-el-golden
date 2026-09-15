# PostgreSQL 18 on Rocky Linux 10.2 — golden image

A functional port of `docker-library/postgres:18` (bookworm) onto a Rocky Linux
10.2 base. `docker-entrypoint.sh` and `docker-ensure-initdb.sh` are byte-for-byte
upstream, pulled from `docker-library/postgres@master` (`18/bookworm/`), so every
documented environment variable and behaviour of the reference image works
unchanged.

## Contents

| File | Purpose |
|---|---|
| `Containerfile` | the image |
| `docker-entrypoint.sh` | **unmodified upstream** |
| `docker-ensure-initdb.sh` | **unmodified upstream** |
| `docker-healthcheck.sh` | added — `pg_isready` over loopback TCP |
| `smoke-test.sh` | acceptance gate; run before promoting a build |
| `compose.yaml` | reference runtime config |
| `Dockerfile.upstream-bookworm` | the upstream Dockerfile, kept for diffing |
| `.github/workflows/build-publish.yml` | builds and publishes the three flavors below, amd64+arm64 |

## Published images

CI builds three flavors, each for `linux/amd64` and `linux/arm64`, on every
push to `master`, and publishes them to `ghcr.io/<owner>/postgresql` as
multi-arch manifests:

| Flavor | Tag | Build args |
|---|---|---|
| default | `18.6-rocky10.2` | none |
| JIT | `18.6-rocky10.2-jit` | `WITH_JIT=1` |
| GIS | `18.6-rocky10.2-gis` | `WITH_GIS=1` |

Every (flavor, arch) pair is built and gated behind `smoke-test.sh` on a
natively-architected runner — no QEMU — before it's published. Passing legs
are pushed as untagged, digest-only images; a merge step then runs
`docker buildx imagetools create` to assemble the amd64 + arm64 digests for
each flavor into one OCI manifest list under that flavor's tag, so
`docker pull ghcr.io/<owner>/postgresql:18.6-rocky10.2` resolves to the right
architecture automatically on either host.

The version segment of the tag is read from `PG_VERSION`/`ROCKY_TAG` in the
Containerfile, so it moves in lockstep with the pin — the workflow never
hardcodes it. The first push creates the GHCR package as **private**; flip it
to public in the package settings once, or `docker pull`/the sample
`compose.yaml` won't work for anyone else.

## Build

Single-arch, for the machine you're building on:

```bash
docker build \
  --build-arg ROCKY_TAG=10.2.20260525.0 \
  --build-arg PG_VERSION=18.6 \
  --build-arg IMAGE_REVISION="$(git rev-parse HEAD)" \
  --build-arg IMAGE_CREATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  -t registry.example.com/platform/postgresql:18.6-rocky10.2 .

./smoke-test.sh registry.example.com/platform/postgresql:18.6-rocky10.2
```

Multi-arch, producing one manifest list covering both architectures (what CI
does, minus the per-arch smoke-test gate — see the caveat below):

```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --build-arg ROCKY_TAG=10.2.20260525.0 \
  --build-arg PG_VERSION=18.6 \
  --build-arg IMAGE_REVISION="$(git rev-parse HEAD)" \
  --build-arg IMAGE_CREATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  -t registry.example.com/platform/postgresql:18.6-rocky10.2 \
  --push .
```

`buildx` builds both platforms and pushes a single manifest list under that
tag; `docker pull` then resolves the right architecture on either host. The
caveat: `docker buildx build ... --push` with multiple `--platform` values
can't also `--load` into your local daemon, so there's nothing to point
`smoke-test.sh` at from this one command — either run it per-arch first (see
`.github/workflows/build-publish.yml` for the build → smoke-test → push
sequence CI follows), or accept that this path skips the acceptance gate.
Building the non-native platform also runs under QEMU unless you're on real
arm64 hardware, which is slow and, for the reasons above, untested here —
prefer letting CI publish multi-arch tags and use this only for one-off local
builds.

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

Two things to do on the first build: grab the printed PGDG repo RPM sha256 and
pin it, and resolve `ROCKY_TAG` to a digest. Until both are pinned the build is
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

1. **Packages come from the PGDG yum repo**, not apt. Binaries live in
   `/usr/pgsql-18/bin` (appended to `PATH`, mirroring upstream's approach),
   libraries and the sample config in `/usr/pgsql-18/share`.
2. **JIT is off by default.** Upstream installs `postgresql-18-jit` when
   available. The LLVM runtime is the single largest thing you can add to this
   image, and JIT is a net loss for most OLTP workloads. Set `WITH_JIT=1` if you
   run analytics.
3. **`nss_wrapper` is off by default.** Upstream always installs
   `libnss-wrapper`, which lets the entrypoint fake a passwd entry when the
   container runs under an arbitrary uid with no `/etc/passwd` record
   (OpenShift's random-uid model). On EL it comes from EPEL — confirm it exists
   in your EL10 mirror before enabling, and if it doesn't, either run as
   `999:999` or build it from source (cwrap.org, small CMake project). Without
   it, arbitrary-uid runs fail at `initdb`.
4. **PostGIS is off by default.** Upstream doesn't ship it at all; it's a
   PGDG extra here. Set `WITH_GIS=1` to install it — the package name is
   versioned as `postgis${POSTGIS_MAJOR}_18`, so bump `POSTGIS_MAJOR` if your
   mirror only carries a newer PostGIS for PG 18. Pulls in GEOS/GDAL/PROJ
   (+~150 MB). `shp2pgsql`/`raster2pgsql` and friends live in a separate
   `-utils` PGDG package, not installed here.
5. **`logging_collector` is forced off**, matching upstream. The PGDG sample
   conf ships it `on`, which sends server log lines to `$PGDATA/log/*.log`
   instead of stderr — invisible to `docker logs`/`kubectl logs` and any log
   shipper reading container output. This is patched into the *sample* conf
   at build time, the same way `listen_addresses` is, so it only takes effect
   for a freshly-initialized `PGDATA`. Volumes initialized before this change
   keep `logging_collector = on`; override it explicitly
   (`-c logging_collector=off`) or edit `postgresql.conf` in the volume.
6. **A `HEALTHCHECK` is defined.** Upstream ships none on purpose. It probes
   loopback TCP so it can't report healthy during bootstrap. On Kubernetes,
   override it away and use a real readiness probe.
7. **setuid/setgid bits are stripped** from the base OS (`HARDEN=1`). Nothing
   PostgreSQL needs is setuid. This does mean the image is not intended for
   installing packages at runtime — which is the point of a golden image.
8. **`/var/lib/pgsql` exists but is unused.** The PGDG RPMs own it. It's left in
   place so `rpm -V` stays clean; ignore it, `PGDATA` is elsewhere.
9. **`systemd` may be pulled in** as an RPM scriptlet dependency of
   `postgresql18-server`. Nothing runs it. If image size matters more than a
   clean rpmdb, the usual fix is a two-stage build with
   `dnf --installroot`; that was left out here to keep the Containerfile auditable.

## Production notes

**Volume path.** The number one way to lose data with 18 is mounting at
`/var/lib/postgresql/data` out of habit. `VOLUME /var/lib/postgresql` means
Docker silently creates an *anonymous* volume there, your named volume sits empty
at `.../data`, and the database disappears on re-create. Mount at
`/var/lib/postgresql`.

**Data checksums** are enabled by `initdb` by default in 18, so
`POSTGRES_INITDB_ARGS=--data-checksums` is no longer needed (harmless if kept).

**`io_method`.** 18 introduces async I/O. The default is `worker`, which is safe
everywhere. If you want `io_method=io_uring`, the container runtime has to permit
the `io_uring_*` syscalls — Docker's default seccomp profile blocks them, so
you'd need a custom profile. Benchmark before doing that; `worker` is fine for
most fleets.

**`/dev/shm`.** Docker's 64 MB default causes parallel-query failures. Set
`shm_size` (compose) or an `emptyDir` medium `Memory` volume (Kubernetes).

**Shutdown.** `SIGINT` = fast shutdown. Pair with a long grace period
(`stop_grace_period: 120s`, `terminationGracePeriodSeconds: 120`); 10 s defaults
will SIGKILL a busy server mid-checkpoint.

**Non-root.** The entrypoint starts as root so it can chown `PGDATA`, then drops
to 999. Once the volume is initialised you can pin `user: "999:999"` and add
`no-new-privileges`.

**SELinux hosts.** Bind mounts need `:Z` (private) or `:z` (shared) or the
container can't read `/docker-entrypoint-initdb.d`. Named volumes are relabelled
for you.

**Rocky 10 requires x86-64-v3 on amd64.** Support for x86-64-v2 was dropped in
Rocky 10. Anything older than roughly Haswell / Zen will not boot the amd64
image. Doesn't apply to the `arm64` build.

**Rebuild cadence.** Pinning `PG_VERSION` and `ROCKY_TAG` means the image does
not pick up CVE fixes on its own. Rebuild on a schedule and on PGDG/Rocky
advisories, run `smoke-test.sh`, then promote.

## Keeping in sync with upstream

Upstream regenerates its Dockerfiles from templates and bumps `PG_VERSION` on
every minor release. Diff periodically:

```bash
curl -fsSL -o /tmp/dockerfile.new \
  https://raw.githubusercontent.com/docker-library/postgres/master/18/bookworm/Dockerfile
diff -u Dockerfile.upstream-bookworm /tmp/dockerfile.new
```

Re-pull `docker-entrypoint.sh` and `docker-ensure-initdb.sh` from the same path
whenever they change; they are meant to stay unmodified here.
