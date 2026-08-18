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
