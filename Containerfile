# syntax=docker/dockerfile:1.7
#
# PostgreSQL 18 golden image, Rocky Linux 10.2 base.
#
# Functional port of docker-library/postgres:18 (bookworm). Everything the
# reference image guarantees is preserved:
#   - postgres uid/gid 999, home /var/lib/postgresql mode 1777
#   - PGDATA=/var/lib/postgresql/18/docker, VOLUME /var/lib/postgresql  (18+ layout)
#   - /docker-entrypoint-initdb.d with .sh/.sql/.sql.gz/.sql.xz/.sql.zst support
#   - unmodified upstream docker-entrypoint.sh / docker-ensure-initdb.sh
#     (+ docker-enforce-initdb.sh symlink)
#   - gosu step-down from root, listen_addresses='*' in the shipped sample conf,
#     en_US.utf8 locale, /var/run/postgresql mode 3777, STOPSIGNAL SIGINT
#
# Divergences from upstream are marked "DIVERGENCE:" and listed in README.md.

ARG ROCKY_IMAGE=docker.io/rockylinux/rockylinux
# Pin to the dated tag, or better, to a digest: ROCKY_TAG=10.2@sha256:...
ARG ROCKY_TAG=10.2.20260525.

FROM ${ROCKY_IMAGE}:${ROCKY_TAG}

# re-declared so the LABEL block at the bottom can reference them
ARG ROCKY_IMAGE
ARG ROCKY_TAG

ARG PG_MAJOR=18
# Exact upstream minor. Bump deliberately; a golden image should never float.
ARG PG_VERSION=18.6
ARG GOSU_VERSION=1.19
# download | setpriv-shim  (setpriv-shim needs no egress to github.com)
ARG GOSU_STRATEGY=download
# JIT pulls the LLVM runtime (~200 MB). Upstream ships it; most OLTP fleets
# disable jit anyway. Opt in if you run analytic queries.
ARG WITH_JIT=1
# nss_wrapper is only needed if you run with an arbitrary --user uid that has
# no /etc/passwd entry (OpenShift-style). Comes from EPEL; verify availability
# for EL10 on your mirror before enabling.
ARG WITH_NSS_WRAPPER=0
# Strip setuid/setgid bits from the base OS (nothing here needs them).
ARG HARDEN=1
# Optional supply-chain pin for the PGDG repo RPM (sha256 of the .noarch.rpm).
ARG PGDG_REPO_RPM_SHA256=

# ---------------------------------------------------------------------------
# Base runtime packages
# ---------------------------------------------------------------------------
# gzip/xz/zstd: docker-entrypoint.sh decompresses *.sql.{gz,xz,zst} init files
# less:         psql's default pager
# glibc-langpack-en: provides en_US.utf8 (base image ships minimal-langpack only)
RUN set -eux; \
	dnf -y install \
		--setopt=install_weak_deps=False \
		--setopt=tsflags=nodocs \
		/usr/bin/curl \
		bash \
		ca-certificates \
		glibc-langpack-en \
		gzip \
		less \
		shadow-utils \
		tzdata \
		util-linux \
		xz \
		zstd \
	; \
	dnf clean all; \
	rm -rf /var/cache/dnf /var/cache/libdnf5

# make the "en_US.UTF-8" locale so postgres will be utf-8 enabled by default
RUN set -eux; locale -a | grep -q 'en_US.utf8'
ENV LANG=en_US.utf8

# ---------------------------------------------------------------------------
# Explicit user/group IDs — must exist BEFORE the PGDG RPMs run their %pre
# scriptlet, otherwise the RPM creates postgres as uid 26 (the EL convention)
# and the image stops being drop-in compatible with upstream volumes.
# ---------------------------------------------------------------------------
RUN set -eux; \
	groupadd -r postgres --gid=999; \
	useradd -r -g postgres --uid=999 --home-dir=/var/lib/postgresql --shell=/bin/bash postgres; \
# also create the postgres user's home directory with appropriate permissions
# see https://github.com/docker-library/postgres/issues/274
	install --verbose --directory --owner postgres --group postgres --mode 1777 /var/lib/postgresql; \
	[ "$(id -u postgres)" = '999' ]; \
	[ "$(id -g postgres)" = '999' ]

# ---------------------------------------------------------------------------
# gosu — easy step-down from root (https://github.com/tianon/gosu/releases)
# ---------------------------------------------------------------------------
ENV GOSU_VERSION=${GOSU_VERSION}
RUN set -eux; \
	case "$GOSU_STRATEGY" in \
		download) \
			dnf -y install --setopt=install_weak_deps=False --setopt=tsflags=nodocs gnupg2; \
			case "$(rpm -E '%{_arch}')" in \
				x86_64)  gosuArch='amd64' ;; \
				aarch64) gosuArch='arm64' ;; \
				ppc64le) gosuArch='ppc64el' ;; \
				s390x)   gosuArch='s390x' ;; \
				*) echo >&2 "unsupported arch: $(rpm -E '%{_arch}')"; exit 1 ;; \
			esac; \
			curl -fsSL -o /usr/local/bin/gosu     "https://github.com/tianon/gosu/releases/download/${GOSU_VERSION}/gosu-${gosuArch}"; \
			curl -fsSL -o /usr/local/bin/gosu.asc "https://github.com/tianon/gosu/releases/download/${GOSU_VERSION}/gosu-${gosuArch}.asc"; \
			GNUPGHOME="$(mktemp -d)"; export GNUPGHOME; \
			gpg --batch --keyserver hkps://keys.openpgp.org --recv-keys B42F6819007F00F88E364FD4036A9C25BF357DD4; \
			gpg --batch --verify /usr/local/bin/gosu.asc /usr/local/bin/gosu; \
			gpgconf --kill all; \
			rm -rf "$GNUPGHOME" /usr/local/bin/gosu.asc; \
			chmod +x /usr/local/bin/gosu; \
			dnf -y remove gnupg2; \
			dnf clean all; rm -rf /var/cache/dnf /var/cache/libdnf5; \
			;; \
		setpriv-shim) \
# DIVERGENCE (opt-in): air-gapped builds get a setpriv-backed gosu shim instead
# of the upstream binary. Same calling convention: gosu USER COMMAND [ARGS...]
			printf '%s\n' \
				'#!/bin/bash' \
				'set -Eeuo pipefail' \
				'if [ "$#" -eq 1 ] && [ "$1" = "--version" ]; then echo "gosu (setpriv shim)"; exit 0; fi' \
				'spec="$1"; shift' \
				'user="${spec%%:*}"; group="${spec#*:}"' \
				'if [ "$group" = "$spec" ]; then' \
				'  exec setpriv --reuid="$user" --regid="$user" --init-groups --inh-caps=-all -- "$@"' \
				'fi' \
				'exec setpriv --reuid="$user" --regid="$group" --clear-groups --inh-caps=-all -- "$@"' \
				> /usr/local/bin/gosu; \
			chmod +x /usr/local/bin/gosu; \
			;; \
		*) echo >&2 "unknown GOSU_STRATEGY: $GOSU_STRATEGY"; exit 1 ;; \
	esac; \
	gosu --version; \
	gosu nobody true

# ---------------------------------------------------------------------------
# PostgreSQL from the PGDG yum repository
# ---------------------------------------------------------------------------
# Trust model: the repo RPM is fetched over TLS from postgresql.org and carries
# the PGDG signing key; every package installed afterwards is GPG-verified
# against it. Set PGDG_REPO_RPM_SHA256 to also pin the repo RPM itself.
ENV PG_MAJOR=${PG_MAJOR}
ENV PG_VERSION=${PG_VERSION}
RUN set -eux; \
	case "$(rpm -E '%{_arch}')" in \
		x86_64|aarch64|ppc64le) elArch="$(rpm -E '%{_arch}')" ;; \
		*) echo >&2 "PGDG has no EL-10 repo for $(rpm -E '%{_arch}')"; exit 1 ;; \
	esac; \
	repoRpm="https://download.postgresql.org/pub/repos/yum/reporpms/EL-10-${elArch}/pgdg-redhat-repo-latest.noarch.rpm"; \
	curl -fsSL -o /tmp/pgdg-repo.rpm "$repoRpm"; \
	if [ -n "$PGDG_REPO_RPM_SHA256" ]; then \
		echo "${PGDG_REPO_RPM_SHA256}  /tmp/pgdg-repo.rpm" | sha256sum -c -; \
	else \
		echo "NOTE: unpinned PGDG repo RPM, sha256=$(sha256sum /tmp/pgdg-repo.rpm | cut -d' ' -f1)"; \
	fi; \
	dnf -y install --nogpgcheck /tmp/pgdg-repo.rpm; \
	rm -f /tmp/pgdg-repo.rpm; \
	rpm -q gpg-pubkey --qf '%{summary} %{version}-%{release}\n' | sort; \
	\
	dnf -y install \
		--setopt=install_weak_deps=False \
		--setopt=tsflags=nodocs \
		"postgresql${PG_MAJOR}-server-${PG_VERSION}" \
		"postgresql${PG_MAJOR}-${PG_VERSION}" \
		"postgresql${PG_MAJOR}-contrib-${PG_VERSION}" \
	; \
	if [ "$WITH_JIT" = '1' ]; then \
		dnf -y install --setopt=install_weak_deps=False --setopt=tsflags=nodocs \
			"postgresql${PG_MAJOR}-llvmjit-${PG_VERSION}"; \
	fi; \
	if [ "$WITH_NSS_WRAPPER" = '1' ]; then \
		dnf -y install --setopt=install_weak_deps=False --setopt=tsflags=nodocs \
			"https://dl.fedoraproject.org/pub/epel/epel-release-latest-10.noarch.rpm"; \
		dnf -y install --setopt=install_weak_deps=False --setopt=tsflags=nodocs nss_wrapper; \
		dnf -y remove epel-release; \
		ls -1 {/usr,}/lib{/*,}/libnss_wrapper.so 2>/dev/null | head -1; \
	fi; \
	\
	dnf clean all; \
	rm -rf /var/cache/dnf /var/cache/libdnf5 /var/log/dnf.* /var/log/hawkey.log

ENV PATH=$PATH:/usr/pgsql-${PG_MAJOR}/bin

RUN set -eux; \
	postgres --version; \
	postgres --version | grep -F "PostgreSQL) ${PG_VERSION}"; \
	initdb --version; \
	psql --version; \
	pg_isready --version

# make the sample config "correct by default" — the entrypoint copies this into
# a fresh PGDATA, so listen_addresses must be '*' for the container to be usable
RUN set -eux; \
	sample="/usr/pgsql-${PG_MAJOR}/share/postgresql.conf.sample"; \
	[ -f "$sample" ]; \
	cp -v "$sample" "${sample}.rpmorig"; \
	sed -ri "s!^#?(listen_addresses)\s*=\s*\S+.*!\1 = '*'!" "$sample"; \
	grep -F "listen_addresses = '*'" "$sample"

RUN mkdir /docker-entrypoint-initdb.d
RUN install --verbose --directory --owner postgres --group postgres --mode 3777 /var/run/postgresql

#
# NOTE: in 18+, PGDATA matches the pg_ctlcluster directory structure and the
# VOLUME moved from /var/lib/postgresql/data to /var/lib/postgresql.
# Mount your volume at /var/lib/postgresql, NOT at .../data.
#
ENV PGDATA=/var/lib/postgresql/${PG_MAJOR}/docker
VOLUME /var/lib/postgresql
# ("/var/lib/postgresql" is already pre-created with suitably usable permissions above)

COPY docker-entrypoint.sh docker-ensure-initdb.sh docker-healthcheck.sh /usr/local/bin/
RUN set -eux; \
	ln -sT docker-ensure-initdb.sh /usr/local/bin/docker-enforce-initdb.sh; \
	chmod 0755 /usr/local/bin/docker-entrypoint.sh /usr/local/bin/docker-ensure-initdb.sh /usr/local/bin/docker-healthcheck.sh; \
	bash -n /usr/local/bin/docker-entrypoint.sh; \
	bash -n /usr/local/bin/docker-ensure-initdb.sh

# ---------------------------------------------------------------------------
# Hardening / cleanup
# ---------------------------------------------------------------------------
RUN set -eux; \
	if [ "$HARDEN" = '1' ]; then \
		find / -xdev -type f -perm /6000 -exec chmod -v ug-s '{}' + || true; \
	fi; \
	rm -rf /tmp/* /var/tmp/* /root/.cache; \
	:

ENTRYPOINT ["docker-entrypoint.sh"]

# We set the default STOPSIGNAL to SIGINT, which corresponds to what PostgreSQL
# calls "Fast Shutdown mode" wherein new connections are disallowed and any
# in-progress transactions are aborted, allowing PostgreSQL to stop cleanly and
# flush tables to disk.
#
# Pair this with a generous --stop-timeout (or terminationGracePeriodSeconds);
# the PostgreSQL docs note that even 90 seconds is not always enough.
STOPSIGNAL SIGINT

EXPOSE 5432
CMD ["postgres"]

ARG IMAGE_SOURCE="https://github.com/boxtheta/psql-el-golden"
ARG IMAGE_REVISION=""
ARG IMAGE_CREATED=""
LABEL org.opencontainers.image.title="postgresql"
LABEL org.opencontainers.image.description="PostgreSQL ${PG_VERSION} on Rocky Linux 10.2"
LABEL org.opencontainers.image.version="${PG_VERSION}"
LABEL org.opencontainers.image.base.name="${ROCKY_IMAGE}:${ROCKY_TAG}"
LABEL org.opencontainers.image.licenses="PostgreSQL"
LABEL org.opencontainers.image.source="${IMAGE_SOURCE}"
LABEL org.opencontainers.image.revision="${IMAGE_REVISION}"
LABEL org.opencontainers.image.created="${IMAGE_CREATED}"
