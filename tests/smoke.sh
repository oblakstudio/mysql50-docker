#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE="${IMAGE:-oblakstudio/mysql50:test}"
PLATFORM="${PLATFORM:-linux/amd64}"
SMOKE_ID="mysql50-smoke-$$"
CONTAINER="${SMOKE_ID}-db"
NETWORK="${SMOKE_ID}-net"
VOLUME="${SMOKE_ID}-data"
INIT_DIR="$(mktemp -d)"

if [ "${SKIP_BUILD:-0}" != 1 ]; then
    docker build --platform="$PLATFORM" -t "$IMAGE" .
fi

cleanup() {
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    docker network rm "$NETWORK" >/dev/null 2>&1 || true
    docker volume rm -f "$VOLUME" >/dev/null 2>&1 || true
    rm -rf "$INIT_DIR"
}
trap cleanup EXIT

wait_for_mysql() {
    local attempt running
    for attempt in $(seq 1 120); do
        running="$(docker inspect --format '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)"
        if [ "$running" != true ]; then
            docker logs "$CONTAINER" >&2 || true
            return 1
        fi
        if query_from_peer root smoke-root 'SELECT 1' >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    docker logs "$CONTAINER" >&2
    return 1
}

query_from_peer() {
    docker run --rm --platform="$PLATFORM" --network="$NETWORK" \
        --entrypoint mysql "$IMAGE" --protocol=TCP --host=db \
        --user="$1" --password="$2" --batch --skip-column-names \
        --execute="$3"
}

cat >"$INIT_DIR/01-schema.sql" <<'SQL'
CREATE TABLE initialized (source VARCHAR(16) NOT NULL);
INSERT INTO initialized VALUES ('sql');
SQL

cat >"$INIT_DIR/02-shell.sh" <<'SH'
mysql --protocol=socket --socket="$SOCKET" --user=root \
    --password="$MYSQL_ROOT_PASSWORD" --database="$MYSQL_DATABASE" \
    --execute="INSERT INTO initialized VALUES ('shell')"
SH

printf "INSERT INTO initialized VALUES ('gzip');\n" \
    | gzip -c >"$INIT_DIR/03-data.sql.gz"

docker network create "$NETWORK" >/dev/null
docker volume create "$VOLUME" >/dev/null

docker run -d --name="$CONTAINER" --hostname=db --network="$NETWORK" \
    --platform="$PLATFORM" -e MYSQL_ROOT_PASSWORD=smoke-root \
    -e MYSQL_DATABASE=smoke_db -e MYSQL_USER=smoke_user \
    -e MYSQL_PASSWORD=smoke-pass -v "$VOLUME:/var/lib/mysql" \
    -v "$INIT_DIR:/docker-entrypoint-initdb.d:ro" "$IMAGE" >/dev/null

wait_for_mysql

version="$(query_from_peer root smoke-root 'SELECT VERSION()')"
case "$version" in
    5.0.32*) ;;
    *) echo "unexpected version: $version" >&2; exit 1 ;;
esac

sources="$(query_from_peer smoke_user smoke-pass \
    "SELECT GROUP_CONCAT(source ORDER BY source SEPARATOR ',') FROM smoke_db.initialized")"
test "$sources" = "gzip,shell,sql"

docker rm -f "$CONTAINER" >/dev/null
printf "CREATE TABLE should_not_run (id INT);\n" >"$INIT_DIR/99-should-not-run.sql"

docker run -d --name="$CONTAINER" --hostname=db --network="$NETWORK" \
    --platform="$PLATFORM" -e MYSQL_ROOT_PASSWORD=ignored-on-existing-data \
    -v "$VOLUME:/var/lib/mysql" \
    -v "$INIT_DIR:/docker-entrypoint-initdb.d:ro" "$IMAGE" >/dev/null

wait_for_mysql
test "$(query_from_peer root smoke-root \
    'SELECT COUNT(*) FROM smoke_db.initialized')" = 3
test "$(query_from_peer root smoke-root \
    "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='smoke_db' AND table_name='should_not_run'")" = 0

secret_file="$INIT_DIR/root-password"
printf '%s' secret >"$secret_file"
if docker run --rm --platform="$PLATFORM" -e MYSQL_ROOT_PASSWORD=direct \
    -e MYSQL_ROOT_PASSWORD_FILE=/run/secrets/root \
    -v "$secret_file:/run/secrets/root:ro" "$IMAGE" \
    2>"$INIT_DIR/conflict.log"; then
    echo "conflicting password variables succeeded" >&2
    exit 1
fi
grep -qF "both MYSQL_ROOT_PASSWORD and MYSQL_ROOT_PASSWORD_FILE are set" \
    "$INIT_DIR/conflict.log"

if docker run --rm --platform="$PLATFORM" -e MYSQL_ROOT_PASSWORD=secret \
    -e MYSQL_ONETIME_PASSWORD=1 "$IMAGE" 2>"$INIT_DIR/onetime.log"; then
    echo "MYSQL_ONETIME_PASSWORD succeeded" >&2
    exit 1
fi
grep -qF "MYSQL_ONETIME_PASSWORD is not supported by MySQL 5.0" \
    "$INIT_DIR/onetime.log"

echo "smoke test passed for $PLATFORM"
