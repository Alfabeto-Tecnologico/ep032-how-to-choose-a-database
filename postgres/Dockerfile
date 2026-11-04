# Official PostgreSQL 18 + iproute2 (tc netem, to simulate network delay) and procps (pkill).
FROM postgres:18.6

RUN apt-get update \
 && apt-get install -y --no-install-recommends iproute2 procps \
 && rm -rf /var/lib/apt/lists/*

COPY primary-init.sh /docker-entrypoint-initdb.d/10-replication.sh
COPY replica-entrypoint.sh /usr/local/bin/replica-entrypoint.sh
COPY net.sh /usr/local/bin/net.sh
RUN chmod +x /usr/local/bin/replica-entrypoint.sh /usr/local/bin/net.sh
