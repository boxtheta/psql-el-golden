#!/bin/bash
# Not part of docker-library/postgres. Added for standalone Docker/Compose use.
#
# Deliberately probes 127.0.0.1 rather than the unix socket: during the
# initdb/init-scripts phase the entrypoint starts a temporary server that
# listens on the socket only, so a socket probe would report "healthy" while
# the database is still being bootstrapped and is not yet reachable by clients.
set -Eeuo pipefail

host="${POSTGRES_HEALTHCHECK_HOST:-127.0.0.1}"
port="${PGPORT:-5432}"
user="${POSTGRES_USER:-postgres}"
db="${POSTGRES_DB:-$user}"

# pg_isready exits 0 on a successful handshake, including when the server
# rejects the credentials — which is what we want: the server is accepting
# connections. Exit 1 (rejecting) / 2 (no response) / 3 (bad invocation).
exec pg_isready --quiet --host="$host" --port="$port" --username="$user" --dbname="$db"
