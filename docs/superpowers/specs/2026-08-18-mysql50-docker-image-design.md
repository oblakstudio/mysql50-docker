# MySQL 5.0 Docker Image Design

## Status

Approved in conversation on 2026-08-18. Implementation is tracked by Beads issue
`mysql50-99j`.

## Purpose

Create `oblakstudio/mysql50`, a compact multi-architecture container image for
Debian Etch's MySQL 5.0 packages. The repository will reuse the proven shape of
the neighboring MySQL 4.1 image while updating package installation, server
configuration, entrypoint behavior, documentation, verification, and release
metadata for MySQL 5.0.

The image is intended for trusted legacy workloads. MySQL 5.0 and Debian Etch
are end-of-life and must not be presented as suitable for exposure to untrusted
networks.

## Goals

- Package Debian Etch's MySQL `5.0.32-7etch12` server and client.
- Publish one image index for `linux/amd64`, `linux/386`, and `linux/arm/v5`.
- Follow the Docker Official Image's MySQL initialization contract wherever
  MySQL 5.0 supports it.
- Keep the Dockerfile cache-friendly and the runtime image small.
- Provide focused, repeatable smoke verification without adding a pull-request
  CI matrix.
- Publish Docker Hub tags for the fixed upstream version and independent
  semantic image releases.

## Non-goals

- Building MySQL from source or vendoring Debian packages.
- Supporting native `linux/arm64`; Debian Etch provides a 32-bit ARM v5 image
  and package set, not an arm64 variant.
- Backporting MySQL features introduced after 5.0.
- Shipping application-specific database dumps or Compose configuration.
- Maintaining a comprehensive database test suite or per-commit CI matrix.

## Base Image and Package Installation

The Dockerfile will use `debian/eol:etch-slim`. Its published image index
contains `linux/amd64`, `linux/386`, and `linux/arm/v5`, matching the target
platforms and the architecture-specific packages in Debian's archive.

The image will install `mysql-server-5.0` and `mysql-client-5.0`, pinned to
Debian revision `5.0.32-7etch12`. A `policy-rc.d` file will prevent the package
post-install script from trying to start a service during the image build.

The Dockerfile will optimize cache reuse and size as follows:

- Keep stable base and package-installation instructions before local `COPY`
  instructions so entrypoint and configuration edits do not reinstall MySQL.
- Run APT update, pinned installation, and cleanup in the same layer.
- Use Etch APT's `--no-install-recommends` option.
- Remove APT lists, downloaded package archives, temporary files, and the
  package-created datadir in the layers that create them.
- Copy only files needed at runtime: `my.cnf` and `docker-entrypoint.sh`.
- Do not install compilers or debugging tools and do not risk corrupting the
  legacy runtime by stripping packaged binaries.

After installation, the Dockerfile will recreate the datadir and socket
directories with `mysql:mysql` ownership, create
`/docker-entrypoint-initdb.d`, expose port 3306, and declare `/var/lib/mysql`
as a volume.

## Server Configuration

`my.cnf` will define the container paths for the socket, PID file, and datadir,
and bind MySQL to `0.0.0.0` so it is reachable over Docker networks.

The default will be `old_passwords = 0`. Accounts created during first-run
initialization will therefore use MySQL 5.0's native 41-byte password hashes.
Operators who need pre-4.1 hashes can mount a replacement configuration before
initializing a datadir.

## Entrypoint Contract

The entrypoint will accept `mysqld` as the default command and prepend `mysqld`
when the first argument is a server option. Non-server commands will execute
without database initialization.

The following variables will follow Docker Official Image semantics where
MySQL 5.0 permits:

- `MYSQL_ROOT_PASSWORD`
- `MYSQL_ALLOW_EMPTY_PASSWORD`
- `MYSQL_RANDOM_ROOT_PASSWORD`
- `MYSQL_ROOT_HOST`, defaulting to `%`
- `MYSQL_DATABASE`
- `MYSQL_USER`
- `MYSQL_PASSWORD`
- `MYSQL_INITDB_SKIP_TZINFO`

`MYSQL_ROOT_PASSWORD`, `MYSQL_ROOT_HOST`, `MYSQL_DATABASE`, `MYSQL_USER`, and
`MYSQL_PASSWORD` will accept mutually exclusive `_FILE` variants for Docker
secrets.

`MYSQL_ONETIME_PASSWORD` is not supported by MySQL 5.0. Setting it will produce
a clear error rather than being ignored.

### First-run flow

When `/var/lib/mysql/mysql` does not exist, the entrypoint will:

1. Read `_FILE` values and validate the initialization environment.
2. Require a root-password mode and reject `MYSQL_USER=root`.
3. Create a random root password when requested and print it once.
4. Initialize the system tables with `mysql_install_db` as `mysql`.
5. Start a temporary server on the Unix socket with networking disabled.
6. Wait for the server to accept connections, failing with a bounded timeout.
7. Remove anonymous users and the test database.
8. Set the local root password and create `root@$MYSQL_ROOT_HOST` with grant
   privileges when the host is not `localhost`.
9. Create the optional application database and non-root application user.
10. Load system timezone data unless `MYSQL_INITDB_SKIP_TZINFO` is set.
11. Process `/docker-entrypoint-initdb.d` files in lexical glob order:
    source `.sh`, execute `.sql`, and decompress/execute `.sql.gz`.
12. Shut down and reap the temporary server.
13. Execute the requested server as the `mysql` user.

SQL string values and identifiers will be escaped independently. A partial
`MYSQL_USER`/`MYSQL_PASSWORD` pair will produce a warning and will not create a
user, matching the neighboring image's established behavior.

### Existing datadir flow

When the system-table directory already exists, the entrypoint will not apply
initialization environment variables or init scripts. It will fix only the
runtime directory permissions needed to start the process, then execute the
requested server without modifying stored accounts or databases.

### Failure behavior

Conflicting variable and `_FILE` values, missing root-password configuration,
unsupported one-time-password configuration, invalid root-as-application-user
configuration, startup timeout, or failed bootstrap SQL will terminate the
container with a specific error. If initialization fails after the temporary
server starts, the entrypoint will attempt to stop and reap it before exiting.

## Repository Contents

The repository will contain:

- `Dockerfile` for the three target platforms.
- `docker-entrypoint.sh` for initialization and process startup.
- `my.cnf` for container-specific server defaults.
- `Makefile` with build, run, shell, smoke, push, clean, and help targets.
- A small smoke-test script used locally during development.
- `README.md` covering risks, tags, quick start, environment variables,
  initialization files, persistence, configuration, architectures, builds,
  and releases.
- A standard MIT `LICENSE` consistent with the README.
- `.dockerignore`, `.gitignore`, and `.releaserc.json`.
- GitHub Actions workflows for semantic releases and multi-platform Docker Hub
  publication.
- Updated `CLAUDE.md` build, verification, architecture, and convention notes.

The neighboring repository's private SQL dump and application-specific local
Compose file will not be copied.

## Verification

Verification will be focused rather than exhaustive. The implementation will:

- Build the image for `linux/amd64`, `linux/386`, and `linux/arm/v5`.
- Run containers under available native execution or QEMU emulation.
- Confirm that the server starts and reports a Debian MySQL 5.0.32 version.
- Confirm TCP root authentication with the default `%` root host.
- Confirm optional database and user creation.
- Confirm execution of an initialization file.
- Restart against the same datadir and confirm that stored data remains while
  initialization is skipped.

The reusable smoke script will automate the runtime checks. No pull-request or
`master` smoke-test matrix will be added.

## Release and Tagging

The existing sibling release shape will be adapted rather than redesigned.
Pushes to `master` will run semantic-release. A published GitHub release will
trigger Docker Buildx to create and push a single multi-platform manifest for:

- `linux/amd64`
- `linux/386`
- `linux/arm/v5`

The Docker Hub repository will be `oblakstudio/mysql50`. Tags will include:

- `latest`
- `5.0.32`, representing the fixed upstream MySQL version
- Exact semantic image releases such as `1.0.0`
- Moving semantic aliases such as `1.0` and `1`

The workflow will update the Docker Hub description from `README.md`. It will
not add a separate pull-request CI workflow.

## Accepted Tradeoffs

- Archived Debian infrastructure is an external build dependency. Pinning the
  package revision makes package selection deterministic, but the packages are
  not vendored into this repository.
- ARM support targets `arm/v5`, not arm64, and commonly requires emulation on
  current ARM64 systems.
- Defaulting `MYSQL_ROOT_HOST` to `%` matches the current Docker Official Image
  and improves container usability, but operators must protect this legacy
  database at the network boundary.
- The image favors a small, auditable adaptation and focused verification over
  broader CI or modernization of end-of-life software.
