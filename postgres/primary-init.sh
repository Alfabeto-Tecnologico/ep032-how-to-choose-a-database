#!/bin/bash
# Runs once, in the primary's initdb: replication user, slots and pg_hba.
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-SQL
  CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD '${REPLICATOR_PASSWORD}';
  SELECT pg_create_physical_replication_slot('replica1');
  SELECT pg_create_physical_replication_slot('replica2');
SQL

echo "host replication replicator all scram-sha-256" >> "$PGDATA/pg_hba.conf"
