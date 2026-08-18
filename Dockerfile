# Legacy MySQL 5.0 packaged from Debian Etch's archived repositories.
FROM debian/eol:etch-slim

ENV DEBIAN_FRONTEND=noninteractive

# Etch APT requires the configuration form of no-install-recommends. Divert
# mysqld while dpkg runs its postinst: that script bootstraps a throwaway data
# directory several times, which is both slow under emulation and deleted below.
RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d \
    && chmod +x /usr/sbin/policy-rc.d \
    && dpkg-divert --add --rename --divert /usr/sbin/mysqld.distrib /usr/sbin/mysqld \
    && printf '#!/bin/sh\nexit 0\n' > /usr/sbin/mysqld \
    && chmod +x /usr/sbin/mysqld \
    && apt-get update \
    && apt-get install -y -o APT::Install-Recommends=false \
        mysql-server-5.0=5.0.32-7etch12 \
        mysql-client-5.0=5.0.32-7etch12 \
    && rm -f /usr/sbin/mysqld \
    && dpkg-divert --rename --remove /usr/sbin/mysqld \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
        /var/cache/apt/archives/*.deb \
        /var/cache/apt/archives/partial/* \
        /tmp/* /var/tmp/* /var/lib/mysql/* \
    && mkdir -p /var/lib/mysql /var/run/mysqld /docker-entrypoint-initdb.d \
    && chown -R mysql:mysql /var/lib/mysql /var/run/mysqld

COPY my.cnf /etc/mysql/my.cnf
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

EXPOSE 3306
VOLUME /var/lib/mysql
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["mysqld"]
