#!/bin/bash
# Runs once on the primary during initdb. Creates a replication role and a slot,
# and allows replication connections in pg_hba.conf.
set -e

psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<-EOSQL
  CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'replpass';
  SELECT pg_create_physical_replication_slot('replica1_slot');
EOSQL

# Allow the replica to connect for streaming replication.
echo "host replication replicator all scram-sha-256" >> "$PGDATA/pg_hba.conf"
