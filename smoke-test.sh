#!/usr/bin/env bash
# Acceptance gate for the golden image. Run this before tagging/promoting.
#   ./smoke-test.sh myregistry/postgres:18.6-rocky10.2
set -Eeuo pipefail

IMAGE="${1:?usage: smoke-test.sh IMAGE[:TAG]}"
RUNTIME="${RUNTIME:-docker}"
NAME="pgsmoke-$$"
VOL="pgsmoke-vol-$$"

cleanup() {
	$RUNTIME rm -f "$NAME" >/dev/null 2>&1 || true
	$RUNTIME volume rm -f "$VOL" >/dev/null 2>&1 || true
}
trap cleanup EXIT

pass() { printf '  ok    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; exit 1; }

echo "== static checks =="
$RUNTIME run --rm --entrypoint bash "$IMAGE" -c '[ "$(id -u postgres)" = 999 ] && [ "$(id -g postgres)" = 999 ]' \
	&& pass 'postgres is uid/gid 999' || fail 'postgres uid/gid is not 999'

$RUNTIME run --rm --entrypoint bash "$IMAGE" -c '[ "$PGDATA" = /var/lib/postgresql/18/docker ]' \
	&& pass 'PGDATA matches upstream 18 layout' || fail 'PGDATA mismatch'

$RUNTIME run --rm --entrypoint bash "$IMAGE" -c "grep -qF \"listen_addresses = '*'\" /usr/pgsql-18/share/postgresql.conf.sample" \
	&& pass "sample conf has listen_addresses = '*'" || fail 'sample conf not patched'

$RUNTIME run --rm --entrypoint bash "$IMAGE" -c 'gosu nobody true' \
	&& pass 'gosu can step down' || fail 'gosu broken'

$RUNTIME run --rm --entrypoint bash "$IMAGE" -c 'command -v gzip xzcat zstd less >/dev/null' \
	&& pass 'init-script decompressors present' || fail 'missing gzip/xz/zstd/less'

$RUNTIME run --rm --entrypoint bash "$IMAGE" -c 'locale -a | grep -q en_US.utf8' \
	&& pass 'en_US.utf8 locale present' || fail 'locale missing'

$RUNTIME run --rm --entrypoint bash "$IMAGE" -c '[ -L /usr/local/bin/docker-enforce-initdb.sh ]' \
	&& pass 'docker-enforce-initdb.sh symlink present' || fail 'symlink missing'

echo "== runtime checks =="
mkdir -p /tmp/"$NAME"-init
cat > /tmp/"$NAME"-init/10-schema.sql <<'SQL'
CREATE TABLE smoke (id int primary key, note text);
INSERT INTO smoke VALUES (1, 'hello');
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
SQL
gzip -kf /tmp/"$NAME"-init/10-schema.sql && rm -f /tmp/"$NAME"-init/10-schema.sql

$RUNTIME volume create "$VOL" >/dev/null
$RUNTIME run -d --name "$NAME" \
	-e POSTGRES_PASSWORD=smoke \
	-e POSTGRES_DB=smokedb \
	-e POSTGRES_INITDB_ARGS='--data-checksums' \
	-v "$VOL":/var/lib/postgresql \
	-v /tmp/"$NAME"-init:/docker-entrypoint-initdb.d:ro,z \
	"$IMAGE" -c shared_preload_libraries=pg_stat_statements >/dev/null

for i in $(seq 1 60); do
	if $RUNTIME exec "$NAME" pg_isready -q -h 127.0.0.1 -U postgres -d smokedb; then break; fi
	sleep 2
	[ "$i" = 60 ] && { $RUNTIME logs "$NAME"; fail 'server never became ready'; }
done
pass 'server accepted TCP connections'

$RUNTIME exec -e PGPASSWORD=smoke "$NAME" psql -h 127.0.0.1 -U postgres -d smokedb -tAc \
	"select note from smoke where id=1" | grep -qx hello \
	&& pass 'gzip init script executed' || fail 'init script did not run'

$RUNTIME exec -e PGPASSWORD=smoke "$NAME" psql -h 127.0.0.1 -U postgres -d smokedb -tAc \
	"select extname from pg_extension where extname='pg_stat_statements'" | grep -qx pg_stat_statements \
	&& pass 'contrib extensions available' || fail 'pg_stat_statements missing'

$RUNTIME exec "$NAME" bash -c 'pg_controldata "$PGDATA" | grep -q "Data page checksum version: *[1-9]"' \
	&& pass 'data checksums enabled' || fail 'checksums off'

$RUNTIME exec "$NAME" bash -c '[ "$(stat -c %u "$PGDATA")" = 999 ]' \
	&& pass 'PGDATA owned by uid 999' || fail 'PGDATA ownership wrong'

$RUNTIME exec "$NAME" psql -U postgres -d smokedb -tAc 'select 1' >/dev/null \
	&& pass 'unix socket path works' || fail 'socket connection failed'

echo "== restart / persistence =="
$RUNTIME stop -t 60 "$NAME" >/dev/null
$RUNTIME start "$NAME" >/dev/null
for i in $(seq 1 30); do
	$RUNTIME exec "$NAME" pg_isready -q -h 127.0.0.1 -U postgres -d smokedb && break
	sleep 2
	[ "$i" = 30 ] && { $RUNTIME logs --tail 50 "$NAME"; fail 'did not come back after restart'; }
done
$RUNTIME exec -e PGPASSWORD=smoke "$NAME" psql -h 127.0.0.1 -U postgres -d smokedb -tAc \
	"select count(*) from smoke" | grep -qx 1 \
	&& pass 'data survived restart on the named volume' || fail 'data loss across restart'

# logging_collector is on in the PGDG sample conf, so server log lines go to
# $PGDATA/log/*.log, not container stdout — `docker logs` never sees them.
$RUNTIME exec "$NAME" bash -c 'grep -rq "received fast shutdown request" "$PGDATA/log/"' \
	&& pass 'SIGINT produced a fast shutdown' || fail 'STOPSIGNAL did not trigger fast shutdown'

echo
echo "ALL CHECKS PASSED for $IMAGE"
