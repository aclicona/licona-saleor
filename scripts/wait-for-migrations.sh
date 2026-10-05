#!/bin/sh
# wait-for-migrations.sh — espera a que la base quede migrada a la altura del código.
#
# Es el `preDeployCommand` de saleor-worker y saleor-beat en Railway. Solo UN
# servicio migra: saleor-api, vía su propio preDeployCommand
# (`python manage.py migrate --noinput`). Worker y beat NO migran: esperan aquí
# a que la base esté al día antes de arrancar el código nuevo. Así se cierra la
# carrera "código nuevo sobre esquema viejo" (B-386/B-387).
#
# Nunca muta: jamás corre `migrate`. Solo pregunta, con `check-migrations.sh`,
# y reintenta mientras la respuesta no sea "al día".
#
# ─── Contrato de salida ──────────────────────────────────────────────────────
#   0 — La base está al día (check-migrations.sh devolvió 0).
#   1 — Se agotó la espera sin que la base llegara al día. El despliegue de
#       este servicio falla a propósito: es mejor no arrancar que arrancar
#       sobre un esquema viejo.
#
# ─── Variables ───────────────────────────────────────────────────────────────
#   MIGRATIONS_POLL_SECONDS  — pausa entre intentos (defecto 10).
#   MIGRATIONS_WAIT_SECONDS  — espera total máxima (defecto 600).
#   CHECK_MIGRATIONS         — guion a invocar; por defecto el check-migrations.sh
#                              que vive junto a este (override pensado para tests).
#
# ─── Convenciones ────────────────────────────────────────────────────────────
# · Tanto exit 1 (pendientes) como exit 2 (base inaccesible: "no sé") se tratan
#   como "todavía no": en un despliegue conjunto la base o la migración de la
#   api pueden tardar unos segundos. Su salida se imprime en cada intento.
# · El límite se aplica por reloj y también por número de intentos
#   (WAIT/POLL), para que no dependa solo del tiempo y no haya bucle infinito
#   con POLL=0.
# · sh POSIX puro (dash), igual que `check-migrations.sh` y `railway-entrypoint.sh`.
# · Sin `set -e` a propósito: los códigos distintos de cero son el dato a leer.

ETIQUETA="[wait-for-migrations]"
POLL="${MIGRATIONS_POLL_SECONDS:-10}"
ESPERA="${MIGRATIONS_WAIT_SECONDS:-600}"

DIR_GUION=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || {
  echo "$ETIQUETA No se pudo resolver la ruta del guion."
  exit 1
}
CHECK="${CHECK_MIGRATIONS:-$DIR_GUION/check-migrations.sh}"

case "$POLL" in ''|*[!0-9]*) echo "$ETIQUETA MIGRATIONS_POLL_SECONDS inválido: '$POLL'."; exit 1 ;; esac
case "$ESPERA" in ''|*[!0-9]*) echo "$ETIQUETA MIGRATIONS_WAIT_SECONDS inválido: '$ESPERA'."; exit 1 ;; esac

# Paso contable por intento: nunca 0, para garantizar que el bucle termine.
PASO=$POLL
[ "$PASO" -gt 0 ] || PASO=1
MAX_INTENTOS=$((ESPERA / PASO + 1))

INICIO=$(date +%s)
INTENTO=0
while :; do
  INTENTO=$((INTENTO + 1))
  SALIDA=$(sh "$CHECK" 2>&1)
  CODIGO=$?
  if [ "$CODIGO" -eq 0 ]; then
    printf '%s\n' "$SALIDA"
    echo "$ETIQUETA La base está al día (intento $INTENTO). Se puede arrancar."
    exit 0
  fi

  printf '%s\n' "$SALIDA"
  TRANSCURRIDO=$(($(date +%s) - INICIO))
  if [ "$INTENTO" -ge "$MAX_INTENTOS" ] || [ "$TRANSCURRIDO" -ge "$ESPERA" ]; then
    echo "$ETIQUETA Se agotó la espera ($ESPERA s, $INTENTO intento(s)): la base NO está al día"
    echo "$ETIQUETA (último código de check-migrations: $CODIGO). Arriba va su última respuesta."
    echo "$ETIQUETA No se arranca sobre un esquema viejo. Revisa el deploy de saleor-api,"
    echo "$ETIQUETA que es quien migra (preDeployCommand: python manage.py migrate --noinput)."
    exit 1
  fi

  echo "$ETIQUETA Código $CODIGO; reintento en $POLL s (intento $INTENTO de máx. $MAX_INTENTOS)."
  sleep "$POLL"
done
