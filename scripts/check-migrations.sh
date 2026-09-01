#!/bin/sh
# check-migrations.sh — ¿la base de datos está migrada a la altura del código?
#
# Responde esa pregunta y NADA MÁS. Nunca muta: jamás corre `migrate`.
# La decisión de qué hacer con la respuesta es del llamador, no de este guion.
#
# ─── Contrato de salida ──────────────────────────────────────────────────────
#   0 — La base está al día. No hay migraciones pendientes.
#   1 — Hay migraciones pendientes. Situación ACCIONABLE: hay que migrar.
#   2 — NO SE PUDO RESPONDER la pregunta: base inaccesible o inexistente,
#       Postgres apagado, o el entorno Python roto.
#
#       OJO: 2 significa "no sé", NO significa "está mal". Conflar 2 con 1
#       llevaría al llamador a correr `migrate` contra una base apagada, que es
#       exactamente el error que este guion existe para evitar. Si distingues
#       los tres códigos, distingues "migra" de "arregla la base".
#
# ─── Por qué el guion habla ──────────────────────────────────────────────────
# `manage.py migrate --check` es MUDO: 0 bytes en stdout tanto en verde como en
# rojo, y solo comunica por exit code. Así que el mensaje lo generamos nosotros:
# ante pendientes decimos CUÁLES (vía `showmigrations --plan`) y el comando
# exacto para arreglarlo; ante base caída decimos que el problema es la base y
# citamos la línea reveladora del error.
#
# ─── Convenciones ────────────────────────────────────────────────────────────
# · Intérprete: ${PYTHON:-python}. `dev.sh` le pasa `.venv/bin/python`; dentro
#   de la imagen sirve el `python` del PATH sin adaptar nada.
# · Todo lo humano sale por stdout, en un solo flujo, para que ningún llamador
#   pierda la mitad del mensaje por capturar solo una de las dos salidas.
# · sh POSIX puro, sin bashismos: corre dentro de la imagen (Debian, /bin/sh es
#   dash), igual que `railway-entrypoint.sh` y `wait-for-db.sh`.
# · Sin `set -e` a propósito: aquí los códigos de salida distintos de cero son
#   el dato que venimos a leer, no una avería que deba abortar el guion.

PYTHON="${PYTHON:-python}"
ETIQUETA="[check-migrations]"

# Funcionar desde cualquier cwd: la raíz del repo (donde vive manage.py) es el
# padre de scripts/, resuelto desde $0.
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
  echo "$ETIQUETA No sé responder si la base está al día."
  exit 2
fi

if ! command -v "$PYTHON" >/dev/null 2>&1; then
  echo "$ETIQUETA El intérprete '$PYTHON' no existe o no es ejecutable."
  echo "$ETIQUETA Pásale uno con PYTHON=... (p. ej. PYTHON=.venv/bin/python)."
  echo "$ETIQUETA No sé responder si la base está al día."
  exit 2
fi

TMP=$(mktemp -d) || {
  echo "$ETIQUETA No se pudo crear un directorio temporal. No sé responder."
  exit 2
}
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

# Ruido cosmético de arranque de Saleor. Se filtra SOLO para lo que se le
# muestra al humano; no decide absolutamente nada.
sin_ruido() {
  grep -v -e 'AuthlibDeprecationWarning' \
          -e 'It will be compatible before version' \
          -e 'from authlib\.jose import' \
          -e '^ \[PID:' \
          -e '^[[:space:]]*$'
}

# ─── 1. La pregunta ──────────────────────────────────────────────────────────
"$PYTHON" manage.py migrate --check >"$TMP/check.out" 2>"$TMP/check.err"
CODIGO=$?

if [ "$CODIGO" -eq 0 ]; then
  echo "$ETIQUETA La base está al día: no hay migraciones pendientes."
  exit 0
fi

# ─── 2. ¿Es "faltan migraciones" o es "no pude preguntar"? ───────────────────
# Con migraciones pendientes, `migrate --check` sale 1 en silencio absoluto.
# Cualquier excepción no capturada (base caída, base inexistente, entorno roto)
# deja un traceback. Ese, y no el exit code, es el discriminante fiable.
# Un código distinto de 0 y 1 tampoco es "faltan migraciones": es una avería.
if grep -q 'Traceback (most recent call last)' "$TMP/check.err" \
   || grep -q 'CommandError\|ImproperlyConfigured\|ModuleNotFoundError' "$TMP/check.err" \
   || [ "$CODIGO" -ne 1 ]; then

  # La línea reveladora, por orden de utilidad: el FATAL de Postgres, si no la
  # excepción de conexión, si no la última línea con contenido.
  REVELADORA=$(sin_ruido <"$TMP/check.err" | grep 'FATAL:' | head -n 1)
  [ -n "$REVELADORA" ] || REVELADORA=$(sin_ruido <"$TMP/check.err" | grep 'OperationalError' | head -n 1)
  [ -n "$REVELADORA" ] || REVELADORA=$(sin_ruido <"$TMP/check.err" | tail -n 1)
  [ -n "$REVELADORA" ] || REVELADORA="(sin mensaje; exit code $CODIGO)"

  echo "$ETIQUETA NO SE PUDO RESPONDER si la base está al día."
  echo "$ETIQUETA Línea reveladora: $REVELADORA"

  # ¿La avería huele a base de datos o a entorno Python? Cambia el consejo, no
  # el veredicto: en ambos casos la respuesta es "no sé", nunca "faltan migraciones".
  if grep -q 'OperationalError\|FATAL:\|could not connect\|connection failed' "$TMP/check.err"; then
    echo "$ETIQUETA El problema es la BASE DE DATOS, no las migraciones."
    echo "$ETIQUETA Causa típica en local: Postgres apagado."
    echo "$ETIQUETA   brew services start postgresql@16"
    echo "$ETIQUETA Revisa también que DATABASE_URL apunte a la base correcta."
  else
    echo "$ETIQUETA El problema es el ENTORNO (Python/Django/settings), no las migraciones."
    echo "$ETIQUETA Revisa el intérprete ('$PYTHON'), las dependencias y las variables de entorno."
    echo "$ETIQUETA Si además Postgres está apagado: brew services start postgresql@16"
  fi

  echo "$ETIQUETA Esto NO quiere decir que falten migraciones. NO corras 'migrate'"
  echo "$ETIQUETA hasta que esto se arregle: migrar a ciegas no arregla nada y puede empeorarlo."
  exit 2
fi

# ─── 3. Hay pendientes: decir cuáles ─────────────────────────────────────────
# Desde aquí el veredicto ya está tomado y es exit 1. Si `showmigrations` se
# cae, se pierde el DETALLE, nunca el veredicto: degradar a 0 aquí convertiría
# una avería en un silencio, que es justo lo que este guion viene a impedir.
if "$PYTHON" manage.py showmigrations --plan >"$TMP/plan.out" 2>"$TMP/plan.err"; then
  grep '^\[ \]' "$TMP/plan.out" >"$TMP/pendientes.txt" 2>/dev/null
  TOTAL=$(wc -l <"$TMP/pendientes.txt" | tr -d ' ')
else
  TOTAL=""
fi

if [ -z "$TOTAL" ]; then
  echo "$ETIQUETA Hay migraciones PENDIENTES: 'migrate --check' salió con código 1."
  echo "$ETIQUETA No pude enumerarlas porque 'showmigrations --plan' falló:"
  sin_ruido <"$TMP/plan.err" | tail -n 5 | sed "s|^|$ETIQUETA   |"
elif [ "$TOTAL" -eq 0 ]; then
  # Contradicción entre los dos comandos. No se resuelve callando: el que dice
  # que algo va mal gana, porque el costo de un falso verde es una API en 500.
  echo "$ETIQUETA Hay migraciones PENDIENTES: 'migrate --check' salió con código 1,"
  echo "$ETIQUETA pero 'showmigrations --plan' no listó ninguna. Revísalo a mano:"
  echo "$ETIQUETA   $PYTHON manage.py showmigrations --plan"
else
  echo "$ETIQUETA Hay $TOTAL migración(es) PENDIENTE(S). La base está por detrás del código."
  head -n 10 "$TMP/pendientes.txt" | sed "s|^|$ETIQUETA   |"
  if [ "$TOTAL" -gt 10 ]; then
    echo "$ETIQUETA   ... y $((TOTAL - 10)) más (mostradas las 10 primeras del plan)."
  fi
fi

echo "$ETIQUETA Para aplicarlas:"
echo "$ETIQUETA   cd $RAIZ && $PYTHON manage.py migrate"
exit 1
