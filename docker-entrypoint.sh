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
            *)
                log "ignoring $file"
                ;;
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
