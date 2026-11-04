#!/bin/bash
# Streaming replica: on first start, clones the primary with pg_basebackup and writes
# primary_conninfo with application_name = the service name.
set -euo pipefail

: "${REPLICA_NAME:?set REPLICA_NAME}"
PRIMARY_HOST="${PRIMARY_HOST:-primary-repl}"

if [ ! -s "$PGDATA/PG_VERSION" ]; then
  mkdir -p "$PGDATA"
  chown -R postgres:postgres "$(dirname "$PGDATA")"
  chmod 700 "$PGDATA"

  until pg_isready -h "$PRIMARY_HOST" -U postgres -q; do sleep 1; done

  export PGPASSWORD="$REPLICATOR_PASSWORD"
  gosu postgres pg_basebackup -h "$PRIMARY_HOST" -U replicator -D "$PGDATA" \
    -X stream -S "$REPLICA_NAME" -R --checkpoint=fast

  cat >> "$PGDATA/postgresql.auto.conf" <<-CONF
primary_conninfo = 'host=${PRIMARY_HOST} port=5432 user=replicator password=${REPLICATOR_PASSWORD} application_name=${REPLICA_NAME}'
primary_slot_name = '${REPLICA_NAME}'
CONF
fi

exec docker-entrypoint.sh "$@"
