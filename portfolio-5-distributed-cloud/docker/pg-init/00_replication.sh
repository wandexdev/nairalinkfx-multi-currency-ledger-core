#!/bin/bash
# runs once, when the primary container initialises its data directory
set -e
echo "host replication pguser all scram-sha-256" >> "$PGDATA/pg_hba.conf"
