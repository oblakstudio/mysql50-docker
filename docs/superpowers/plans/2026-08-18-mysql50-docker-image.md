# MySQL 5.0 Docker Image Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and publish a compact Debian Etch MySQL 5.0.32 image for `linux/amd64`, `linux/386`, and `linux/arm/v5` with an official-image-style initialization contract.

**Architecture:** One Dockerfile installs Debian's pinned MySQL packages before copying the small runtime configuration and entrypoint, maximizing cache reuse. A Bash entrypoint initializes empty datadirs through a socket-only temporary server, while focused Docker smoke tests validate initialization, authentication, init files, and persistence. Semantic-release and Buildx publish one three-platform image index.

**Tech Stack:** Docker/Buildx, Debian Etch APT, MySQL 5.0.32, Bash 3-compatible shell, GNU Make, GitHub Actions, semantic-release.

**Spec:** `docs/superpowers/specs/2026-08-18-mysql50-docker-image-design.md`

## Global Constraints

- Base image: `debian/eol:etch-slim`.
- Pin `mysql-server-5.0` and `mysql-client-5.0` to `5.0.32-7etch12`.
- Publish `linux/amd64`, `linux/386`, and `linux/arm/v5`; do not claim native arm64.
- Publish as `oblakstudio/mysql50` with `latest`, `5.0.32`, and semantic image tags.
- Default `old_passwords = 0` and `MYSQL_ROOT_HOST=%`.
- Follow Docker Official Image behavior where MySQL 5.0 permits; reject `MYSQL_ONETIME_PASSWORD`.
- Support `.sh`, `.sql`, `.sql.gz`, and `_FILE` secrets for the five documented variables.
- Keep APT installation before local `COPY`; remove APT data and the package-created datadir.
- Do not copy the sibling SQL dump or application-specific Compose file.
- Add no pull-request or `master` smoke-test matrix.
- Use non-interactive cleanup commands.

## File Map

- `Dockerfile`: pinned installation, runtime filesystem, and image contract.
- `my.cnf`: socket/network/datadir paths and password-hash default.
- `docker-entrypoint.sh`: validation, initialization, init files, and server execution.
- `tests/image-structure.sh`: package/configuration/cleanup assertions.
- `tests/smoke.sh`: runtime contract and persistence assertions for one platform.
- `Makefile`: single/multi-platform developer commands.
- `.dockerignore`, `.gitignore`: build-context and local-artifact hygiene.
- `.releaserc.json`, `.github/workflows/*.yml`: GitHub and Docker Hub releases.
- `README.md`, `LICENSE`, `CLAUDE.md`: operator and contributor documentation.

---

### Task 1: Package MySQL 5.0.32 on Debian Etch

**Bead:** `mysql50-99j.1`

**Files:**
- Create: `tests/image-structure.sh`
- Create: `Dockerfile`
- Create: `my.cnf`

**Interfaces:**
- Test inputs: `IMAGE` (default `oblakstudio/mysql50:test`) and `PLATFORM` (default `linux/amd64`).
- Produces MySQL executables, the `mysql` user, runtime directories, and configuration for Task 2.
- Leaves `/var/lib/mysql` without system tables so initialization happens at runtime.

- [ ] **Step 1: Claim the Bead**

```bash
bd update mysql50-99j.1 --claim
```

- [ ] **Step 2: Write the failing structure test**

Create executable `tests/image-structure.sh`:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE="${IMAGE:-oblakstudio/mysql50:test}"
PLATFORM="${PLATFORM:-linux/amd64}"

docker build --platform="$PLATFORM" -t "$IMAGE" .
docker run --rm --platform="$PLATFORM" --entrypoint /bin/sh "$IMAGE" -ec '
mysql --version | grep -F "Distrib 5.0.32"
mysqld --version | grep -F "Ver 5.0.32"
test -x /usr/bin/mysql_install_db
test -f /etc/mysql/my.cnf
grep -Eq "^[[:space:]]*bind-address[[:space:]]*=[[:space:]]*0.0.0.0$" /etc/mysql/my.cnf
grep -Eq "^[[:space:]]*old_passwords[[:space:]]*=[[:space:]]*0$" /etc/mysql/my.cnf
test ! -d /var/lib/mysql/mysql
if find /var/lib/apt/lists -type f | grep -q .; then
    echo "APT list files remain" >&2
    exit 1
fi
if find /var/cache/apt/archives -name "*.deb" | grep -q .; then
    echo "APT package archives remain" >&2
    exit 1
fi
'
```

```bash
chmod +x tests/image-structure.sh
./tests/image-structure.sh
```

Expected: FAIL because `Dockerfile` is absent.

- [ ] **Step 3: Create the packaged image**

Create `Dockerfile`:

```dockerfile
# Legacy MySQL 5.0 packaged from Debian Etch's archived repositories.
FROM debian/eol:etch-slim

ENV DEBIAN_FRONTEND=noninteractive

# Etch APT requires the configuration form of no-install-recommends.
RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d \
    && chmod +x /usr/sbin/policy-rc.d \
    && apt-get update \
    && apt-get install -y -o APT::Install-Recommends=false \
        mysql-server-5.0=5.0.32-7etch12 \
        mysql-client-5.0=5.0.32-7etch12 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
        /var/cache/apt/archives/*.deb \
        /var/cache/apt/archives/partial/* \
        /tmp/* /var/tmp/* /var/lib/mysql/* \
    && mkdir -p /var/lib/mysql /var/run/mysqld /docker-entrypoint-initdb.d \
    && chown -R mysql:mysql /var/lib/mysql /var/run/mysqld

COPY my.cnf /etc/mysql/my.cnf

EXPOSE 3306
VOLUME /var/lib/mysql
CMD ["/usr/sbin/mysqld", "--user=mysql"]
```

Create `my.cnf`:

```ini
# Container defaults for Debian Etch's MySQL 5.0 server.
[client]
port            = 3306
socket          = /var/run/mysqld/mysqld.sock

[mysqld]
user            = mysql
port            = 3306
socket          = /var/run/mysqld/mysqld.sock
pid-file        = /var/run/mysqld/mysqld.pid
datadir         = /var/lib/mysql
bind-address    = 0.0.0.0
old_passwords   = 0

[mysqld_safe]
socket          = /var/run/mysqld/mysqld.sock
```

- [ ] **Step 4: Verify package shape and cache ordering**

```bash
bash -n tests/image-structure.sh
./tests/image-structure.sh
docker image inspect oblakstudio/mysql50:test --format '{{.Size}}'
docker history --no-trunc oblakstudio/mysql50:test
```

Expected: tests pass; package installation precedes `COPY my.cnf`; no APT files or system tables remain. Record the measured byte count:

```bash
mysql50_packaged_size_bytes="$(docker image inspect oblakstudio/mysql50:test --format '{{.Size}}')"
bd update mysql50-99j.1 --append-notes="amd64 packaged image size: ${mysql50_packaged_size_bytes} bytes"
```

- [ ] **Step 5: Close and commit**

```bash
bd close mysql50-99j.1 --reason="Pinned compact Etch package image and structure test pass"
git add Dockerfile my.cnf tests/image-structure.sh
git commit -m "feat: package MySQL 5.0 on Debian Etch"
```

---

### Task 2: Implement the MySQL 5.0 Container Entrypoint

**Bead:** `mysql50-99j.2`

**Files:**
- Create: `tests/smoke.sh`
- Create: `docker-entrypoint.sh`
- Modify: `Dockerfile`

**Interfaces:**
- Consumes the MySQL executables, `mysql` user, directories, and config from Task 1.
- Exposes `MYSQLD`, `DATADIR`, and `SOCKET` to sourced `.sh` init files.
- Accepts the environment and `_FILE` variables in the spec.
- Produces first-run initialization and existing-datadir pass-through for Task 3.

- [ ] **Step 1: Claim the Bead**

```bash
bd update mysql50-99j.2 --claim
```

- [ ] **Step 2: Write the failing runtime smoke test**

Create executable `tests/smoke.sh`. It must use unique container/network/volume names, install an EXIT trap that uses `docker rm -f`, `docker network rm`, `docker volume rm -f`, and `rm -rf` on its own temporary directory, then perform these literal checks:

```bash
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
    local attempt
    for attempt in $(seq 1 120); do
        if docker exec "$CONTAINER" mysqladmin --protocol=socket \
            --socket=/var/run/mysqld/mysqld.sock --user=root \
            --password=smoke-root ping >/dev/null 2>&1; then
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
case "$version" in 5.0.32*) ;; *) echo "unexpected version: $version" >&2; exit 1 ;; esac
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
    echo "conflicting password variables succeeded" >&2; exit 1
fi
grep -F "both MYSQL_ROOT_PASSWORD and MYSQL_ROOT_PASSWORD_FILE are set" \
    "$INIT_DIR/conflict.log"

if docker run --rm --platform="$PLATFORM" -e MYSQL_ROOT_PASSWORD=secret \
    -e MYSQL_ONETIME_PASSWORD=1 "$IMAGE" 2>"$INIT_DIR/onetime.log"; then
    echo "MYSQL_ONETIME_PASSWORD succeeded" >&2; exit 1
fi
grep -F "MYSQL_ONETIME_PASSWORD is not supported by MySQL 5.0" \
    "$INIT_DIR/onetime.log"
echo "smoke test passed for $PLATFORM"
```

```bash
chmod +x tests/smoke.sh
./tests/smoke.sh
```

Expected: FAIL because the Task 1 image cannot initialize its empty datadir.

- [ ] **Step 3: Implement the entrypoint**

Create executable `docker-entrypoint.sh` using Bash 3-compatible constructs and this function contract:

```bash
#!/bin/bash
set -eo pipefail

MYSQLD=/usr/sbin/mysqld
DATADIR=/var/lib/mysql
SOCKET=/var/run/mysqld/mysqld.sock
TEMP_PID=
TEMP_PASSWORD_SET=0
export MYSQLD DATADIR SOCKET

log() { echo "[entrypoint] $*"; }
warn() { echo "[entrypoint] WARNING: $*" >&2; }
die() { echo "[entrypoint] ERROR: $*" >&2; exit 1; }

file_env() {
    local var="$1" file_var="${1}_FILE" default_value="${2:-}"
    local var_value="${!var:-}" file_value="${!file_var:-}" value="$default_value"
    if [ -n "$var_value" ] && [ -n "$file_value" ]; then
        die "both $var and $file_var are set (they are exclusive)"
    fi
    if [ -n "$var_value" ]; then
        value="$var_value"
    elif [ -n "$file_value" ]; then
        [ -r "$file_value" ] || die "cannot read $file_var path: $file_value"
        value="$(cat "$file_value")"
    fi
    export "$var=$value"
    unset "$file_var"
}

sql_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e "s/'/''/g"; }
ident_escape() { printf '%s' "$1" | sed 's/`/``/g'; }

mysql_root() {
    mysql --protocol=socket --socket="$SOCKET" --user=root \
        --password="$MYSQL_ROOT_PASSWORD" "$@"
}

mysqladmin_root() {
    if [ "$TEMP_PASSWORD_SET" = 1 ]; then
        mysqladmin --protocol=socket --socket="$SOCKET" --user=root \
            --password="$MYSQL_ROOT_PASSWORD" "$@"
    else
        mysqladmin --protocol=socket --socket="$SOCKET" --user=root "$@"
    fi
}
```

Complete `docker-entrypoint.sh` with these functions and call:

```bash
stop_temp_server() {
    [ -n "$TEMP_PID" ] || return 0
    if kill -0 "$TEMP_PID" 2>/dev/null; then
        mysqladmin_root shutdown >/dev/null 2>&1 \
            || kill "$TEMP_PID" 2>/dev/null \
            || true
    fi
    wait "$TEMP_PID" 2>/dev/null || true
    TEMP_PID=
}

docker_read_env() {
    file_env MYSQL_ROOT_PASSWORD
    file_env MYSQL_ROOT_HOST '%'
    file_env MYSQL_DATABASE
    file_env MYSQL_USER
    file_env MYSQL_PASSWORD

    [ -z "${MYSQL_ONETIME_PASSWORD:-}" ] \
        || die "MYSQL_ONETIME_PASSWORD is not supported by MySQL 5.0"
    if [ -z "$MYSQL_ROOT_PASSWORD" ] \
        && [ -z "${MYSQL_ALLOW_EMPTY_PASSWORD:-}" ] \
        && [ -z "${MYSQL_RANDOM_ROOT_PASSWORD:-}" ]; then
        die "database is uninitialized and no root password option is set"
    fi
    [ "$MYSQL_USER" != root ] \
        || die "MYSQL_USER=root is not allowed; use MYSQL_ROOT_PASSWORD"
    if [ -n "${MYSQL_RANDOM_ROOT_PASSWORD:-}" ]; then
        MYSQL_ROOT_PASSWORD="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
        export MYSQL_ROOT_PASSWORD
    fi
}

docker_process_init_files() {
    local file
    for file in /docker-entrypoint-initdb.d/*; do
        [ -e "$file" ] || continue
        case "$file" in
            *.sh)
                log "sourcing $file"
                . "$file"
                ;;
            *.sql)
                log "running $file"
                if [ -n "$MYSQL_DATABASE" ]; then
                    mysql_root --database="$MYSQL_DATABASE" < "$file"
                else
                    mysql_root < "$file"
                fi
                ;;
            *.sql.gz)
                log "running $file"
                if [ -n "$MYSQL_DATABASE" ]; then
                    gunzip -c "$file" | mysql_root --database="$MYSQL_DATABASE"
                else
                    gunzip -c "$file" | mysql_root
                fi
                ;;
            *) log "ignoring $file" ;;
        esac
    done
}

docker_init_database() {
    local attempt root_password root_host database user password
    docker_read_env

    log "initializing system tables"
    mysql_install_db --user=mysql --datadir="$DATADIR" >/dev/null

    log "starting temporary server"
    "$MYSQLD" --user=mysql --datadir="$DATADIR" --skip-networking \
        --socket="$SOCKET" --pid-file=/var/run/mysqld/mysqld.pid &
    TEMP_PID="$!"
    trap stop_temp_server EXIT INT TERM

    for attempt in $(seq 1 60); do
        mysqladmin_root ping >/dev/null 2>&1 && break
        [ "$attempt" != 60 ] || die "temporary server failed to start"
        sleep 1
    done

    root_password="$(sql_escape "$MYSQL_ROOT_PASSWORD")"
    root_host="$(sql_escape "$MYSQL_ROOT_HOST")"
    {
        echo "DELETE FROM mysql.user WHERE User='';"
        echo "DROP DATABASE IF EXISTS test;"
        echo "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';"
        echo "UPDATE mysql.user SET Password=PASSWORD('${root_password}') WHERE User='root';"
        if [ -n "$MYSQL_ROOT_HOST" ] && [ "$MYSQL_ROOT_HOST" != localhost ]; then
            echo "GRANT ALL PRIVILEGES ON *.* TO 'root'@'${root_host}' IDENTIFIED BY '${root_password}' WITH GRANT OPTION;"
        fi
        if [ -n "$MYSQL_DATABASE" ]; then
            database="$(ident_escape "$MYSQL_DATABASE")"
            echo "CREATE DATABASE IF NOT EXISTS \`${database}\`;"
        fi
        if [ -n "$MYSQL_USER" ] && [ -n "$MYSQL_PASSWORD" ]; then
            user="$(sql_escape "$MYSQL_USER")"
            password="$(sql_escape "$MYSQL_PASSWORD")"
            if [ -n "$MYSQL_DATABASE" ]; then
                database="$(ident_escape "$MYSQL_DATABASE")"
                echo "GRANT ALL PRIVILEGES ON \`${database}\`.* TO '${user}'@'%' IDENTIFIED BY '${password}';"
            else
                echo "GRANT USAGE ON *.* TO '${user}'@'%' IDENTIFIED BY '${password}';"
            fi
        elif [ -n "$MYSQL_USER" ] || [ -n "$MYSQL_PASSWORD" ]; then
            warn "MYSQL_USER and MYSQL_PASSWORD must both be set; skipping user creation"
        fi
        echo "FLUSH PRIVILEGES;"
    } | mysql --protocol=socket --socket="$SOCKET" --user=root
    TEMP_PASSWORD_SET=1

    if [ -z "${MYSQL_INITDB_SKIP_TZINFO:-}" ]; then
        log "loading timezone data"
        mysql_tzinfo_to_sql /usr/share/zoneinfo \
            | sed 's/Local time zone must be set--see zic manual page/FCTY/' \
            | mysql_root mysql
    fi
    if [ -n "${MYSQL_RANDOM_ROOT_PASSWORD:-}" ]; then
        log "GENERATED ROOT PASSWORD: $MYSQL_ROOT_PASSWORD"
    fi

    docker_process_init_files
    log "stopping temporary server"
    stop_temp_server
    trap - EXIT INT TERM
    log "initialization complete"
}

main() {
    if [ "${1:0:1}" = '-' ]; then
        set -- "$MYSQLD" "$@"
    fi
    if [ "$1" = mysqld ] || [ "$1" = "$MYSQLD" ]; then
        mkdir -p "$DATADIR" /var/run/mysqld
        if [ "$(id -u)" = 0 ]; then
            chown -R mysql:mysql "$DATADIR" /var/run/mysqld
        fi
        if [ ! -d "$DATADIR/mysql" ]; then
            docker_init_database
        else
            log "existing database found; skipping initialization"
        fi
        log "starting MySQL 5.0"
        exec "$@" --user=mysql
    fi
    exec "$@"
}

main "$@"
```

- [ ] **Step 4: Install the entrypoint in the image**

After `COPY my.cnf`, add:

```dockerfile
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh
```

Replace Task 1's `CMD` with:

```dockerfile
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["mysqld"]
```

- [ ] **Step 5: Run syntax, structure, and runtime checks**

```bash
chmod +x docker-entrypoint.sh
bash -n docker-entrypoint.sh tests/smoke.sh
./tests/image-structure.sh
./tests/smoke.sh
```

Expected: every command exits 0 and smoke ends with `smoke test passed for linux/amd64`. For an Etch-specific correction, preserve the interfaces above and attach the exact failing/passing command to the Bead.

- [ ] **Step 6: Close and commit**

```bash
bd close mysql50-99j.2 --reason="MySQL 5.0 initialization, validation, init-file, and persistence checks pass"
git add Dockerfile docker-entrypoint.sh tests/smoke.sh
git commit -m "feat: add MySQL 5.0 container entrypoint"
```

---

### Task 3: Add Multi-architecture Developer Tooling

**Bead:** `mysql50-99j.3`

**Files:**
- Create: `Makefile`
- Create: `.dockerignore`
- Modify: `.gitignore`

**Interfaces:**
- Consumes both test scripts.
- Produces `build`, `build-all`, `run`, `shell`, `structure`, `smoke`, `smoke-all`, `push`, `clean`, and `help` targets.
- Supports `IMAGE`, `VERSION`, `PLATFORM`, `PLATFORMS`, `ROOT_PASSWORD`, and `PORT` overrides.

- [ ] **Step 1: Claim the Bead and verify the interface is absent**

```bash
bd update mysql50-99j.3 --claim
make help
```

Expected: `make help` fails because no Makefile exists.

- [ ] **Step 2: Create the Makefile**

```makefile
IMAGE         ?= oblakstudio/mysql50
VERSION       ?= 5.0.32
PLATFORM      ?= linux/amd64
PLATFORMS     ?= linux/amd64,linux/386,linux/arm/v5
ROOT_PASSWORD ?= root
PORT          ?= 3306

.PHONY: build build-all run shell structure smoke smoke-all push clean help

build: ## Build the selected platform as :latest and :$(VERSION)
	docker build --platform=$(PLATFORM) \
		-t $(IMAGE):latest -t $(IMAGE):$(VERSION) .

build-all: ## Build all release platforms into the Buildx cache
	docker buildx build --platform=$(PLATFORMS) \
		-t $(IMAGE):latest -t $(IMAGE):$(VERSION) .

run: ## Run the selected platform locally
	docker run --rm -it --platform=$(PLATFORM) \
		-e MYSQL_ROOT_PASSWORD=$(ROOT_PASSWORD) \
		-p $(PORT):3306 $(IMAGE):latest

shell: ## Open a shell in the selected image
	docker run --rm -it --platform=$(PLATFORM) \
		--entrypoint /bin/bash $(IMAGE):latest

structure: ## Verify package, config, and cleanup invariants
	IMAGE=$(IMAGE):test PLATFORM=$(PLATFORM) ./tests/image-structure.sh

smoke: ## Build and smoke-test the selected platform
	IMAGE=$(IMAGE):test PLATFORM=$(PLATFORM) ./tests/smoke.sh

smoke-all: ## Build and smoke-test every release platform
	@set -e; \
	for platform in linux/amd64 linux/386 linux/arm/v5; do \
		suffix=$$(printf '%s' "$$platform" | tr '/' '-'); \
		tag="$(IMAGE):test-$$suffix"; \
		docker buildx build --load --platform="$$platform" -t "$$tag" .; \
		IMAGE="$$tag" PLATFORM="$$platform" SKIP_BUILD=1 ./tests/smoke.sh; \
	done

push: ## Build and publish the release platform index
	docker buildx build --push --platform=$(PLATFORMS) \
		-t $(IMAGE):latest -t $(IMAGE):$(VERSION) .

clean: ## Remove local development images without prompting
	-docker image rm -f $(IMAGE):latest $(IMAGE):$(VERSION) $(IMAGE):test \
		$(IMAGE):test-linux-amd64 $(IMAGE):test-linux-386 $(IMAGE):test-linux-arm-v5

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'
```

- [ ] **Step 3: Restrict Git and Docker build inputs**

Create `.dockerignore`:

```text
.git
.beads
.agents
.claude
.codex
.github
docs
tests
*.md
Makefile
LICENSE
.releaserc.json
```

Append to `.gitignore` without deleting the existing Beads entries:

```gitignore

# Local database dumps and smoke artifacts
/*.sql
/*.sql.gz
/mysql50-multiarch.tar
```

- [ ] **Step 4: Verify developer commands**

```bash
make help
make structure PLATFORM=linux/amd64
make smoke PLATFORM=linux/amd64
```

Expected: all targets are listed; structure and smoke pass.

- [ ] **Step 5: Close and commit**

```bash
bd close mysql50-99j.3 --reason="Multi-platform Make targets and build-context hygiene verified"
git add Makefile .dockerignore .gitignore
git commit -m "build: add multi-platform image tooling"
```

---

### Task 4: Adapt Semantic Release and Multi-platform Publishing

**Bead:** `mysql50-99j.4`

**Files:**
- Create: `.releaserc.json`
- Create: `.github/workflows/release.yml`
- Create: `.github/workflows/docker_build.yml`

**Interfaces:**
- Produces GitHub releases from `master` and three-platform Docker Hub manifests.
- Uses `OBLAKBOT_PAT`, `OBLAKBOT_GPG_KEY`, `OBLAKBOT_GPG_PASS`, `DOCKERHUB_USERNAME`, and `DOCKERHUB_PAT`.
- Consumes `README.md` from Task 5 when an actual release runs.

- [ ] **Step 1: Claim the Bead and verify files are absent**

```bash
bd update mysql50-99j.4 --claim
test -f .releaserc.json
```

Expected: the file assertion fails.

- [ ] **Step 2: Add semantic-release configuration**

Create `.releaserc.json`:

```json
{
  "branches": ["master"],
  "plugins": [
    "@semantic-release/commit-analyzer",
    "@semantic-release/release-notes-generator",
    "@semantic-release/github"
  ]
}
```

Create `.github/workflows/release.yml`:

```yaml
name: Release

on:
  push:
    branches:
      - master
  workflow_dispatch:

permissions:
  contents: write
  issues: write
  pull-requests: write

concurrency:
  group: release-${{ github.ref }}
  cancel-in-progress: false

jobs:
  release:
    name: Release
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          fetch-depth: 0
          token: ${{ secrets.OBLAKBOT_PAT }}

      - name: Import GPG key
        id: gpg
        uses: crazy-max/ghaction-import-gpg@v6
        with:
          gpg_private_key: ${{ secrets.OBLAKBOT_GPG_KEY }}
          passphrase: ${{ secrets.OBLAKBOT_GPG_PASS }}
          git_config_global: true
          git_user_signingkey: true
          git_commit_gpgsign: true

      - name: Semantic Release
        uses: cycjimmy/semantic-release-action@v4
        with:
          extra_plugins: |
            @semantic-release/github
        env:
          GIT_AUTHOR_NAME: ${{ steps.gpg.outputs.name }}
          GIT_AUTHOR_EMAIL: ${{ steps.gpg.outputs.email }}
          GIT_COMMITTER_NAME: ${{ steps.gpg.outputs.name }}
          GIT_COMMITTER_EMAIL: ${{ steps.gpg.outputs.email }}
          GITHUB_TOKEN: ${{ secrets.OBLAKBOT_PAT }}
```

- [ ] **Step 3: Add Docker publication**

Create `.github/workflows/docker_build.yml`:

```yaml
name: Docker builds

on:
  workflow_dispatch:
  release:
    types: [published]

permissions:
  contents: read

env:
  REGISTRY_IMAGE: oblakstudio/mysql50
  MYSQL_VERSION: "5.0.32"

jobs:
  build:
    name: Build image
    runs-on: ubuntu-latest
    steps:
      - name: Checkout code
        uses: actions/checkout@v4
      - name: Set up QEMU
        uses: docker/setup-qemu-action@v3
      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3
      - name: Docker Metadata
        id: meta
        uses: docker/metadata-action@v5
        with:
          images: ${{ env.REGISTRY_IMAGE }}
          tags: |
            type=semver,pattern={{version}}
            type=semver,pattern={{major}}.{{minor}}
            type=semver,pattern={{major}}
            type=raw,value=${{ env.MYSQL_VERSION }},enable=${{ github.event_name == 'release' }}
            type=ref,event=branch
          labels: |
            org.opencontainers.image.title=oblakstudio/mysql50
            org.opencontainers.image.description=Legacy MySQL 5.0 on Debian Etch for modern container workflows
            org.opencontainers.image.url=${{ github.event.repository.html_url }}
            org.opencontainers.image.source=${{ github.event.repository.clone_url }}
            org.opencontainers.image.revision=${{ github.sha }}
      - name: Login to Docker Hub
        uses: docker/login-action@v3
        with:
          username: ${{ secrets.DOCKERHUB_USERNAME }}
          password: ${{ secrets.DOCKERHUB_PAT }}
      - name: Build and push image
        uses: docker/build-push-action@v6
        with:
          context: .
          platforms: linux/amd64,linux/386,linux/arm/v5
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          provenance: false
          sbom: false
          cache-from: type=gha
          cache-to: type=gha,mode=max
      - name: Update Docker Hub description
        uses: peter-evans/dockerhub-description@v4
        with:
          username: ${{ secrets.DOCKERHUB_USERNAME }}
          password: ${{ secrets.DOCKERHUB_PAT }}
          repository: ${{ env.REGISTRY_IMAGE }}
          readme-filepath: ./README.md
          short-description: "Legacy MySQL 5.0 on Debian Etch for modern container workflows"
```

- [ ] **Step 4: Validate release facts**

```bash
python3 -m json.tool .releaserc.json >/dev/null
rg -n 'oblakstudio/mysql50|MYSQL_VERSION: "5\.0\.32"|linux/amd64,linux/386,linux/arm/v5' .github/workflows
! rg -n 'mysql41|4\.1\.11|sarge' .github .releaserc.json
```

Expected: JSON is valid; registry/version/platform lines exist; no sibling values remain.

- [ ] **Step 5: Close and commit**

```bash
bd close mysql50-99j.4 --reason="Semantic release and three-platform publication are statically validated"
git add .releaserc.json .github/workflows/release.yml .github/workflows/docker_build.yml
git commit -m "ci: publish multi-platform MySQL 5.0 image"
```

---

### Task 5: Document the Image and Repository

**Bead:** `mysql50-99j.6`

**Files:**
- Create: `README.md`
- Create: `LICENSE`
- Modify: `CLAUDE.md`

**Interfaces:**
- Documents every environment variable, command, platform, tag, and limitation from Tasks 1-4.
- `README.md` is consumed by the Docker Hub description action.

- [ ] **Step 1: Claim the Bead and verify docs are absent**

```bash
bd update mysql50-99j.6 --claim
test -f README.md
```

Expected: file assertion fails.

- [ ] **Step 2: Write the operator README**

Adapt the sibling README to `oblakstudio/mysql50`. Include all of these concrete sections and facts:

1. Badges for MySQL `5.0.32`, image version/pulls/size, GitHub releases, platforms, Debian Etch, and 2026 maintenance.
2. EOL warning: MySQL 5.0 and Debian Etch have unpatched vulnerabilities and must run only on trusted networks.
3. Tags: `latest`, `5.0.32`, `X.Y.Z`, `X.Y`, and `X`.
4. Platforms: `linux/amd64`, `linux/386`, `linux/arm/v5`; arm64 users explicitly request/emulate arm/v5.
5. Environment table: root password/allow-empty/random, root host, database, user/password, timezone skip, and supported `_FILE` forms.
6. `MYSQL_ROOT_HOST` defaults to `%`; `MYSQL_ONETIME_PASSWORD` fails on MySQL 5.0.
7. `.sh`, `.sql`, `.sql.gz` init files run only for an empty datadir.
8. Existing datadirs ignore initialization variables and preserve accounts/data.
9. `old_passwords=0` creates native 41-byte hashes; mount a replacement config before initialization to change it.
10. Server options pass through after the image name.
11. Commands: `make build`, `build-all`, `structure`, `smoke`, `smoke-all`, `run`, `shell`.
12. Implementation: `debian/eol:etch-slim`, pinned `5.0.32-7etch12` packages.
13. Release automation and fixed-upstream versus semantic image tags.
14. MIT license, Oblak Studio credit, and MySQL trademark statement.

Use these examples verbatim:

```bash
docker run --rm -d --name mysql50 \
  -e MYSQL_ROOT_PASSWORD=secret \
  -p 3306:3306 \
  oblakstudio/mysql50
```

```bash
docker run --rm --platform=linux/arm/v5 \
  -e MYSQL_ROOT_PASSWORD=secret \
  oblakstudio/mysql50
```

- [ ] **Step 3: Add the MIT license**

Create `LICENSE`:

```text
MIT License

Copyright (c) 2026 Oblak Studio

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

- [ ] **Step 4: Replace generic guidance in `CLAUDE.md`**

Preserve the Beads block. Replace only its generic project sections with this content (using valid nested Markdown fencing):

```text
## Build & Test

make build       # Build linux/amd64 by default
make structure   # Verify package, config, and image cleanup
make smoke       # Verify initialization and persistence
make smoke-all   # Build and smoke all release platforms
make build-all   # Build all platforms into Buildx cache

## Architecture Overview

The image packages Debian Etch's pinned MySQL 5.0.32 server/client packages.
docker-entrypoint.sh initializes empty datadirs through a socket-only temporary
server and leaves existing datadirs unchanged. Releases publish one manifest
for linux/amd64, linux/386, and linux/arm/v5.

## Conventions & Patterns

- Keep pinned APT installation before local COPY instructions.
- Keep shell compatible with Debian Etch's Bash 3 and validate with bash -n.
- Preserve Docker Official Image semantics where MySQL 5.0 supports them.
- Use non-interactive cleanup and never commit database dumps.
- Run make structure and make smoke after runtime changes.
```

- [ ] **Step 5: Check for stale or missing facts**

```bash
! rg -n 'mysql41|4\.1\.11|Debian Sarge|linux/386 only' README.md CLAUDE.md LICENSE
rg -n '5\.0\.32|linux/amd64|linux/386|linux/arm/v5|MYSQL_ROOT_HOST|old_passwords|make smoke' README.md CLAUDE.md
git diff --check
```

Expected: stale search finds nothing; required facts all appear; whitespace passes.

- [ ] **Step 6: Close and commit**

```bash
bd close mysql50-99j.6 --reason="README, license, and repository guidance cover the implemented contract"
git add README.md LICENSE CLAUDE.md
git commit -m "docs: document MySQL 5.0 image"
```

---

### Task 6: Verify and Finish the Image

**Bead:** `mysql50-99j.5`

**Files:**
- Modify only a tracked file for a concrete defect exposed below.

**Interfaces:**
- Consumes every artifact and command from Tasks 1-5.
- Produces final evidence and closes the parent only after acceptance passes.

- [ ] **Step 1: Claim the Bead**

```bash
bd update mysql50-99j.5 --claim
```

- [ ] **Step 2: Run static gates**

```bash
git diff --check
bash -n docker-entrypoint.sh tests/image-structure.sh tests/smoke.sh
python3 -m json.tool .releaserc.json >/dev/null
make help
```

Expected: every command exits 0.

- [ ] **Step 3: Clean-build and smoke amd64**

```bash
docker build --no-cache --platform=linux/amd64 -t oblakstudio/mysql50:test .
IMAGE=oblakstudio/mysql50:test PLATFORM=linux/amd64 ./tests/image-structure.sh
IMAGE=oblakstudio/mysql50:test PLATFORM=linux/amd64 ./tests/smoke.sh
```

Expected: build and both tests pass.

- [ ] **Step 4: Build and run every release platform**

```bash
make build-all
make smoke-all
```

Expected: Buildx completes amd64, 386, and arm/v5; every runnable platform reports `smoke test passed`. If the host lacks a binfmt handler, do not install privileged host components without approval: attach the exact runtime failure to the Bead and retain successful Buildx evidence.

- [ ] **Step 5: Inspect final size, metadata, and task state**

```bash
docker image inspect oblakstudio/mysql50:test --format 'size={{.Size}} entrypoint={{json .Config.Entrypoint}} cmd={{json .Config.Cmd}}'
docker history oblakstudio/mysql50:test
git status --short --branch
bd show mysql50-99j
```

Expected: entrypoint is `docker-entrypoint.sh`; command is `mysqld`; all prior child Beads are closed.

- [ ] **Step 6: Record exact evidence and close Beads**

```bash
mysql50_size_bytes="$(docker image inspect oblakstudio/mysql50:test --format '{{.Size}}')"
bd update mysql50-99j.5 --append-notes="amd64 structure/smoke passed; amd64,386,arm/v5 builds passed; cross-platform smoke results recorded in command log; amd64 size=${mysql50_size_bytes} bytes"
bd close mysql50-99j.5 --reason="Static gates, platform builds, and focused runtime verification complete"
bd close mysql50-99j --reason="MySQL 5.0.32 Etch image and repository complete"
```

- [ ] **Step 7: Commit concrete verification fixes if any**

If tracked fixes were required, stage the known implementation paths and commit:

```bash
if ! git diff --quiet; then
    git add Dockerfile my.cnf docker-entrypoint.sh Makefile \
        .dockerignore .gitignore .releaserc.json .github \
        tests README.md LICENSE CLAUDE.md
    git commit -m "fix: finish MySQL 5.0 image verification"
fi
```

Do not create an empty commit when no tracked file changed.

- [ ] **Step 8: Synchronize and verify**

```bash
git pull --rebase
bd dolt push
git push
git status --short --branch
```

Expected: Git shows `master...origin/master` with no changes or ahead/behind marker. Beads currently has no configured Dolt remote; if unchanged, preserve its local Dolt history and report that exact limitation instead of inventing a URL.
