#!/bin/sh
# smoke-imagen.sh — humo de la imagen Docker del fork contra un Postgres real (B-911).
#
# B-877 demostró A MANO, con la imagen real, hechos que el despliegue en Railway
# da por ciertos y que ningún test unitario puede ver porque dependen del ENTRYPOINT y de
# lo que la imagen trae dentro. Este guion los convierte en comprobación repetible (cinco comprobaciones):
#   1. El ENTRYPOINT (`railway-entrypoint.sh`) NO migra: tras arrancar un contenedor por
#      el ENTRYPOINT sobre una base vacía, la base sigue sin migrar.
#   2. `wait-for-migrations.sh` sale 1 con la base vacía sin migrar (falla a propósito,
#      no arranca sobre un esquema viejo).
#   3. `python manage.py migrate --noinput` sale 0 envuelto por el ENTRYPOINT
#      (`exec "$@"`) y también con `--entrypoint` sobrescrito (el preDeployCommand).
#   4. `wait-for-migrations.sh` sale 0 con la base ya migrada.
#
# Uso:   sh scripts/smoke-imagen.sh <imagen>      (p. ej. licona-saleor:smoke)
# Salida: 0 si todo se cumple; 1 si alguno falla; 2 si no se pudo
#         preparar el entorno (sin docker, sin imagen, Postgres que no arranca).
# No toca nada fuera de su red y su contenedor Postgres (nombres con el PID), y los
# borra al salir. sh POSIX, sin set -e: los códigos distintos de cero son el dato.

ETIQUETA="[smoke-imagen]"
IMAGEN="$1"
PG_IMAGEN="${PG_IMAGEN:-postgres:15-alpine}"

if [ -z "$IMAGEN" ]; then
  echo "$ETIQUETA Uso: sh scripts/smoke-imagen.sh <imagen>"
  exit 2
fi
if ! command -v docker >/dev/null 2>&1 || ! docker image inspect "$IMAGEN" >/dev/null 2>&1; then
  echo "$ETIQUETA No hay docker o la imagen '$IMAGEN' no existe localmente (hay que construirla antes)."
  exit 2
fi

SUFIJO="$$"
RED="smoke-imagen-red-$SUFIJO"
PG="smoke-imagen-pg-$SUFIJO"
FALLOS=0

limpiar() {
  docker rm -f "$PG" >/dev/null 2>&1
  docker network rm "$RED" >/dev/null 2>&1
}
trap limpiar EXIT HUP INT TERM

docker network create "$RED" >/dev/null || { echo "$ETIQUETA No se pudo crear la red."; exit 2; }
docker run -d --name "$PG" --network "$RED" \
  -e POSTGRES_USER=saleor -e POSTGRES_PASSWORD=saleor -e POSTGRES_DB=saleor \
  "$PG_IMAGEN" >/dev/null || { echo "$ETIQUETA No arrancó Postgres."; exit 2; }

LISTO=""
for _ in $(seq 1 30); do
  if docker exec "$PG" pg_isready -U saleor -d saleor >/dev/null 2>&1; then LISTO=1; break; fi
  sleep 1
done
[ -n "$LISTO" ] || { echo "$ETIQUETA Postgres no quedó listo en 30 s."; exit 2; }

# Un contenedor de la imagen con la configuración mínima. Todo arg tras la imagen va tal
# cual al ENTRYPOINT (o al comando, si se pasa --entrypoint antes). Wait-for-migrations
# con espera 0: un solo intento, sin reintentos de 10 s.
correr() {
  docker run --rm --network "$RED" \
    -e DATABASE_URL="postgres://saleor:saleor@$PG:5432/saleor" \
    -e SECRET_KEY=smoke -e MIGRATIONS_WAIT_SECONDS=0 -e MIGRATIONS_POLL_SECONDS=0 \
    "$@"
}

esperar() {  # esperar <descripción> <código esperado> <código real>
  if [ "$3" -eq "$2" ]; then
    echo "$ETIQUETA OK   $1 (exit $3)"
  else
    echo "$ETIQUETA FALLO $1: esperaba exit $2, obtuve $3"
    FALLOS=$((FALLOS + 1))
  fi
}

# 1+2. Por el ENTRYPOINT sobre base vacía; luego la base debe seguir sin migrar.
correr "$IMAGEN" true >/dev/null 2>&1
esperar "el ENTRYPOINT arranca y ejecuta el comando" 0 $?
correr "$IMAGEN" sh scripts/wait-for-migrations.sh >/dev/null 2>&1
esperar "wait-for-migrations con la base vacía sin migrar (el ENTRYPOINT no migró)" 1 $?

# 3. migrate envuelto por el ENTRYPOINT, y con --entrypoint sobrescrito (idempotente).
correr "$IMAGEN" python manage.py migrate --noinput >/dev/null 2>&1
esperar "migrate --noinput envuelto por el ENTRYPOINT" 0 $?
correr --entrypoint python "$IMAGEN" manage.py migrate --noinput >/dev/null 2>&1
esperar "migrate --noinput con --entrypoint sobrescrito" 0 $?

# 4. Con la base migrada, wait-for-migrations pasa.
correr "$IMAGEN" sh scripts/wait-for-migrations.sh >/dev/null 2>&1
esperar "wait-for-migrations con la base migrada" 0 $?

if [ "$FALLOS" -gt 0 ]; then
  echo "$ETIQUETA $FALLOS comprobación(es) fallaron."
  exit 1
fi
echo "$ETIQUETA Las cinco comprobaciones de la imagen '$IMAGEN' se cumplen."
exit 0
