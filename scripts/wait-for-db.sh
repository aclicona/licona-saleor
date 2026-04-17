#!/bin/sh
# Espera a que Postgres acepte conexiones antes de continuar.
set -e

HOST=$(echo $DATABASE_URL | sed 's|.*@\([^:]*\).*|\1|')
PORT=$(echo $DATABASE_URL | sed 's|.*:\([0-9]*\)/.*|\1|')

echo "Waiting for PostgreSQL at $HOST:$PORT..."
until nc -z "$HOST" "$PORT"; do
  sleep 1
done
echo "PostgreSQL is ready."
