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
