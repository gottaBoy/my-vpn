#!/bin/bash
# Create additional databases on first PostgreSQL start.
# POSTGRES_MULTIPLE_DATABASES=netbird,zitadel triggers this script via docker-entrypoint-initdb.d.
set -e

if [ -n "$POSTGRES_MULTIPLE_DATABASES" ]; then
    echo "==> Creating databases: $POSTGRES_MULTIPLE_DATABASES"
    for db in $(echo "$POSTGRES_MULTIPLE_DATABASES" | tr ',' ' '); do
        echo "  CREATE DATABASE $db OWNER $POSTGRES_USER;"
        psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<-EOSQL
            CREATE DATABASE "$db" OWNER "$POSTGRES_USER";
EOSQL
    done
    echo "==> Done."
fi
