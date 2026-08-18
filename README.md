# oblakstudio/mysql50

[![MySQL Version](https://img.shields.io/badge/MySQL-5.0.32-00758F?logo=mysql&logoColor=white)](https://hub.docker.com/r/oblakstudio/mysql50)
[![Docker Image Version](https://img.shields.io/docker/v/oblakstudio/mysql50?sort=semver&logo=docker&logoColor=white&label=image&color=2496ED)](https://hub.docker.com/r/oblakstudio/mysql50/tags)
[![Docker Pulls](https://img.shields.io/docker/pulls/oblakstudio/mysql50?logo=docker&logoColor=white&color=2496ED)](https://hub.docker.com/r/oblakstudio/mysql50)
[![Docker Image Size](https://img.shields.io/docker/image-size/oblakstudio/mysql50/latest?logo=docker&logoColor=white&label=size&color=2496ED)](https://hub.docker.com/r/oblakstudio/mysql50/tags)
[![Release](https://img.shields.io/github/actions/workflow/status/oblakstudio/mysql50-docker/release.yml?branch=master&logo=githubactions&logoColor=white&label=release)](https://github.com/oblakstudio/mysql50-docker/actions/workflows/release.yml)
![Platform](https://img.shields.io/badge/platform-amd64%20%7C%20386%20%7C%20arm%2Fv5-2496ED?logo=linux&logoColor=white)
![Base](https://img.shields.io/badge/base-Debian%20Etch%204.0-A81D33?logo=debian&logoColor=white)
![Maintenance](https://img.shields.io/maintenance/yes/2026)

---

Legacy **MySQL 5.0** packaged for modern container workflows. The image uses
Debian Etch's archived `5.0.32-7etch12` packages and follows the Docker Official
Image's first-run environment contract where MySQL 5.0 supports it.

> [!WARNING]
> MySQL 5.0 and Debian Etch are end-of-life software with known, unpatched
> security issues. This image exists for trusted legacy workloads. Never expose
> it directly to the public internet or another untrusted network.

## Tags

The wrapped MySQL version is fixed; image releases are versioned independently
with semantic-release.

| Tag | Description |
| --- | --- |
| `latest` | Newest image release |
| `5.0.32` | Fixed wrapped MySQL version |
| `X.Y.Z` | Exact image release, such as `1.0.0` |
| `X.Y`, `X` | Moving semantic image-release aliases |

All tags contain MySQL 5.0.32 on Debian Etch.

## Architectures

The image index publishes these Etch-supported platforms:

- `linux/amd64`
- `linux/386`
- `linux/arm/v5`

There is no native `linux/arm64` image. An ARM64 host must explicitly request
and emulate the 32-bit ARM image when its Docker/QEMU setup supports it.
Buildx can build the artifact, but current user-mode QEMU may fail MySQL 5.0's
threaded bootstrap with `Can't create interrupt-thread`; treat emulated runs as
best effort and validate production use on native compatible ARM32 hardware.

```bash
docker run --rm --platform=linux/arm/v5 \
  -e MYSQL_ROOT_PASSWORD=secret \
  oblakstudio/mysql50
```

## Quick start

```bash
docker run --rm -d --name mysql50 \
  -e MYSQL_ROOT_PASSWORD=secret \
  -p 3306:3306 \
  oblakstudio/mysql50
```

Connect from a client with MySQL's native password protocol:

```bash
mysql -h127.0.0.1 -P3306 -uroot -psecret
```

## Environment variables

First-run initialization accepts the familiar official-image variables:

| Variable | Description |
| --- | --- |
| `MYSQL_ROOT_PASSWORD` | Password for `root` |
| `MYSQL_ALLOW_EMPTY_PASSWORD` | Allow an empty root password when non-empty; insecure |
| `MYSQL_RANDOM_ROOT_PASSWORD` | Generate a root password and print it once |
| `MYSQL_ROOT_HOST` | Additional root host; defaults to `%` |
| `MYSQL_DATABASE` | Database to create |
| `MYSQL_USER` / `MYSQL_PASSWORD` | Non-root user to create; both are required |
| `MYSQL_INITDB_SKIP_TZINFO` | Skip loading timezone tables when non-empty |

One of `MYSQL_ROOT_PASSWORD`, `MYSQL_ALLOW_EMPTY_PASSWORD`, or
`MYSQL_RANDOM_ROOT_PASSWORD` is required for an empty datadir.

`MYSQL_ROOT_PASSWORD`, `MYSQL_ROOT_HOST`, `MYSQL_DATABASE`, `MYSQL_USER`, and
`MYSQL_PASSWORD` also accept mutually exclusive `*_FILE` forms for Docker
secrets:

```bash
docker run -d --name mysql50 \
  -e MYSQL_ROOT_PASSWORD_FILE=/run/secrets/mysql-root \
  -v ./mysql-root-password:/run/secrets/mysql-root:ro \
  oblakstudio/mysql50
```

`MYSQL_ROOT_HOST` defaults to `%`, matching the current Docker Official Image,
so root can connect across a Docker network. Protect the container at the
network boundary or set `MYSQL_ROOT_HOST=localhost` when remote root access is
not needed.

MySQL 5.0 cannot expire an account password using the newer official-image
mechanism. Setting `MYSQL_ONETIME_PASSWORD` therefore produces an explicit
error rather than being silently ignored.

## Initialization files

Files in `/docker-entrypoint-initdb.d/` run in glob order only when the datadir
is empty:

- `*.sh` files are sourced.
- `*.sql` files are executed by the MySQL client.
- `*.sql.gz` files are decompressed and executed.

When `MYSQL_DATABASE` is set, SQL files run with that database selected.

```bash
docker run -d --name mysql50 \
  -e MYSQL_ROOT_PASSWORD=secret \
  -e MYSQL_DATABASE=legacy_app \
  -v ./seed.sql:/docker-entrypoint-initdb.d/seed.sql:ro \
  oblakstudio/mysql50
```

## Data persistence

The image declares `/var/lib/mysql` as a volume. Mount a named volume to retain
data across containers:

```bash
docker run -d --name mysql50 \
  -e MYSQL_ROOT_PASSWORD=secret \
  -v mysql50-data:/var/lib/mysql \
  oblakstudio/mysql50
```

If `/var/lib/mysql/mysql` already exists, initialization variables and init
files are ignored. Existing databases, accounts, and passwords are not changed.

## Password hashing

`my.cnf` defaults to `old_passwords = 0`, so accounts created during
initialization use MySQL 5.0's native 41-byte hashes. This is more compatible
with later clients than the pre-4.1 16-byte format.

Applications that require old hashes can mount a replacement `/etc/mysql/my.cnf`
before initializing a new datadir. Changing the option does not rewrite hashes
already stored in an existing datadir.

## Configuration and server options

The bundled `my.cnf` sets the socket, PID file, datadir, port, password-hash
mode, and `bind-address = 0.0.0.0`. Mount a complete replacement at
`/etc/mysql/my.cnf` to override it.

Arguments beginning with `-` are passed to `mysqld`:

```bash
docker run -d -e MYSQL_ROOT_PASSWORD=secret \
  oblakstudio/mysql50 --max-connections=200
```

## Building and testing

```bash
make build       # Build linux/amd64 by default
make build-all   # Build all release platforms into the Buildx cache
make structure   # Verify package, config, and image cleanup
make smoke       # Verify initialization, TCP auth, init files, and persistence
make smoke-all   # Attempt the lifecycle smoke test on every release platform
make run         # Run the selected image locally
make shell       # Open Bash in the selected image
```

Override `PLATFORM`, `IMAGE`, `VERSION`, `ROOT_PASSWORD`, or `PORT` as needed.
Multi-platform targets require a Buildx builder with the corresponding QEMU
handlers. `make smoke-all` fails honestly when the host emulator cannot run an
architecture's MySQL bootstrap; this is a known possibility for `arm/v5`.

## Releases

Pushes to `master` run semantic-release using Conventional Commits. A published
GitHub release triggers Buildx, which publishes one manifest containing amd64,
386, and arm/v5 images. Image release tags (`1.0.0`, `1.0`, `1`) evolve while
the fixed upstream tag remains `5.0.32`.

## How it works

MySQL 5.0 is no longer available from current distribution repositories. The
Dockerfile starts from `debian/eol:etch-slim` and installs the archived,
architecture-specific `mysql-server-5.0` and `mysql-client-5.0` packages pinned
to Debian revision `5.0.32-7etch12`.

The package-created datadir is deleted in the installation layer. On first
container start, `docker-entrypoint.sh` creates system tables, configures
accounts through a socket-only temporary server, processes init files, shuts
the temporary server down, and finally starts the networked server as `mysql`.

## Credits and license

Built and maintained by [Oblak Studio](https://oblak.studio). MySQL is a
trademark of Oracle Corporation. This repository packages already released
legacy software and is not affiliated with or endorsed by Oracle.

The Dockerfile, entrypoint, tests, and workflow files are released under the
[MIT License](LICENSE).
