#!/bin/sh
# check-invalid-indexes.sh — ¿hay índices INVALID en la base de datos? (B-1288)
#
# Responde esa pregunta y NADA MÁS. Solo LEE (`pg_index`): jamás borra ni crea
# nada. Qué hacer con la respuesta es del llamador (o de la persona).
#
# ─── Por qué existe ──────────────────────────────────────────────────────────
# Varias migraciones de upstream son `atomic = False` y hacen
# `CREATE UNIQUE INDEX CONCURRENTLY` seguido de `ADD CONSTRAINT ... USING INDEX`,
# SIN `IF NOT EXISTS`. Si el pre-deploy (`migrate --noinput`) se corta entre los
# dos pasos (deploy cancelado, OOM, reinicio), queda un índice con
# `indisvalid = false`. Todo despliegue posterior falla con «relation ... already
# exists» sin explicar el porqué. Este guion convierte ese misterio en un mensaje.
#
# ─── Contrato de salida ──────────────────────────────────────────────────────
#   0 — No hay índices inválidos.
#   1 — Hay índices con `NOT indisvalid`. ACCIONABLE: se listan y se da la receta.
#   2 — NO SE PUDO RESPONDER: base caída/inexistente o entorno Python roto.
#       OJO: 2 significa "no sé", NO "hay índices inválidos". Un llamador del
#       tipo `check-invalid-indexes.sh && migrate` NO migra con 0 ni con 2... y
#       tampoco con 1: en los tres casos se detiene hasta que alguien mire.
#
# ─── Cableado propuesto (pendiente de Andrés; NO está en railway.*.json) ─────
#   preDeployCommand:  sh scripts/check-invalid-indexes.sh && python manage.py migrate --noinput
#
# ─── Convenciones (iguales a check-migrations.sh) ────────────────────────────
# · Intérprete: ${PYTHON:-python}. Todo lo humano sale por stdout.
# · sh POSIX puro (dash). Sin `set -e`: los códigos distintos de 0 son el dato.

PYTHON="${PYTHON:-python}"
ETIQUETA="[check-invalid-indexes]"

DIR_GUION=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || {
  echo "$ETIQUETA No se pudo resolver la ruta del guion. No sé responder."
  exit 2
}
RAIZ=$(CDPATH= cd -- "$DIR_GUION/.." && pwd) || {
  echo "$ETIQUETA No se pudo resolver la raíz del repo. No sé responder."
  exit 2
}
cd "$RAIZ" || {
  echo "$ETIQUETA No se pudo entrar a $RAIZ. No sé responder."
  exit 2
}

if [ ! -f "$RAIZ/manage.py" ]; then
  echo "$ETIQUETA No hay manage.py en $RAIZ — esto no parece la raíz del fork."
  echo "$ETIQUETA No sé responder si hay índices inválidos."
  exit 2
fi

if ! command -v "$PYTHON" >/dev/null 2>&1; then
  echo "$ETIQUETA El intérprete '$PYTHON' no existe o no es ejecutable."
  echo "$ETIQUETA Pásale uno con PYTHON=... (p. ej. PYTHON=.venv/bin/python)."
  echo "$ETIQUETA No sé responder si hay índices inválidos."
  exit 2
fi

TMP=$(mktemp -d) || {
  echo "$ETIQUETA No se pudo crear un directorio temporal. No sé responder."
  exit 2
}
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

sin_ruido() {
  grep -v -e 'AuthlibDeprecationWarning' \
          -e 'It will be compatible before version' \
          -e 'from authlib\.jose import' \
          -e '^ \[PID:' \
          -e '^[[:space:]]*$'
}

# ─── 1. La consulta (solo lectura) ───────────────────────────────────────────
# Cada hallazgo sale como `INVALID_INDEX|esquema|indice|tabla`; el éxito se
# confirma con `CHECK_DONE` para que un crash silencioso nunca se lea como 0.
CONSULTA=$(cat <<'PY'
from django.db import connection
with connection.cursor() as c:
    c.execute(
        "SELECT n.nspname, i.relname, t.relname "
        "FROM pg_index x "
        "JOIN pg_class i ON i.oid = x.indexrelid "
        "JOIN pg_class t ON t.oid = x.indrelid "
        "JOIN pg_namespace n ON n.oid = i.relnamespace "
        "WHERE NOT x.indisvalid "
        "AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast') "
        "ORDER BY n.nspname, i.relname"
    )
    for esquema, indice, tabla in c.fetchall():
        print("INVALID_INDEX|%s|%s|%s" % (esquema, indice, tabla))
print("CHECK_DONE")
PY
)

"$PYTHON" manage.py shell -c "$CONSULTA" >"$TMP/q.out" 2>"$TMP/q.err"
CODIGO=$?

# ─── 2. ¿Respondió la base? ──────────────────────────────────────────────────
if [ "$CODIGO" -ne 0 ] || ! grep -q '^CHECK_DONE$' "$TMP/q.out"; then
  REVELADORA=$(sin_ruido <"$TMP/q.err" | grep 'FATAL:' | head -n 1)
  [ -n "$REVELADORA" ] || REVELADORA=$(sin_ruido <"$TMP/q.err" | grep 'OperationalError' | head -n 1)
  [ -n "$REVELADORA" ] || REVELADORA=$(sin_ruido <"$TMP/q.err" | tail -n 1)
  [ -n "$REVELADORA" ] || REVELADORA="(sin mensaje; exit code $CODIGO)"

  echo "$ETIQUETA NO SE PUDO RESPONDER si hay índices inválidos."
  echo "$ETIQUETA Línea reveladora: $REVELADORA"
  if grep -q 'OperationalError\|FATAL:\|could not connect\|connection failed' "$TMP/q.err"; then
    echo "$ETIQUETA El problema es la BASE DE DATOS (apagada, inexistente o inaccesible)."
    echo "$ETIQUETA Revisa que DATABASE_URL apunte a la base correcta."
  else
    echo "$ETIQUETA El problema es el ENTORNO (Python/Django/settings)."
    echo "$ETIQUETA Revisa el intérprete ('$PYTHON'), las dependencias y las variables de entorno."
  fi
  echo "$ETIQUETA Esto NO quiere decir que haya índices inválidos, ni que no los haya."
  exit 2
fi

# ─── 3. Veredicto ────────────────────────────────────────────────────────────
grep '^INVALID_INDEX|' "$TMP/q.out" >"$TMP/invalidos.txt"
TOTAL=$(wc -l <"$TMP/invalidos.txt" | tr -d ' ')

if [ "$TOTAL" -eq 0 ]; then
  echo "$ETIQUETA No hay índices inválidos."
  exit 0
fi

echo "$ETIQUETA Hay $TOTAL índice(s) INVÁLIDO(S) (NOT indisvalid):"
while IFS='|' read -r _ ESQUEMA INDICE TABLA; do
  echo "$ETIQUETA   $ESQUEMA.$INDICE ($TABLA)"
done <"$TMP/invalidos.txt"

echo "$ETIQUETA Causa típica: un 'CREATE INDEX CONCURRENTLY' de una migración se cortó"
echo "$ETIQUETA a medias; el siguiente 'migrate' falla con «already exists»."
echo "$ETIQUETA ANTES de borrar nada: un CREATE INDEX CONCURRENTLY EN CURSO también aparece"
echo "$ETIQUETA como inválido. Si hay una migración corriendo ahora mismo, NO lo borres: espera."
echo "$ETIQUETA Si no hay ninguna corriendo, para cada índice (este guion NO borra nada):"
while IFS='|' read -r _ ESQUEMA INDICE TABLA; do
  echo "$ETIQUETA   DROP INDEX CONCURRENTLY IF EXISTS \"$ESQUEMA\".\"$INDICE\";"
done <"$TMP/invalidos.txt"
echo "$ETIQUETA y después vuelve a desplegar para que 'migrate' lo recree."
exit 1
