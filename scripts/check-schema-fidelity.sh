#!/bin/sh
# check-schema-fidelity.sh — ¿el esquema GraphQL commiteado es fiel al código?
#
# Responde esa pregunta y NADA MÁS. Nunca muta: jamás escribe sobre
# `saleor/graphql/schema.graphql`. Regenera a un temporal fuera del repo y lo
# borra al salir. La decisión de qué hacer con la respuesta es del llamador.
#
# ─── Contrato de salida ──────────────────────────────────────────────────────
#   0 — El esquema commiteado coincide byte a byte con el que genera el código.
#   1 — NO coincide (deriva real). Situación ACCIONABLE: hay que regenerarlo.
#   2 — NO SE PUDO RESPONDER: entorno Python roto, `manage.py` caído, Postgres
#       apagado, o salida vacía.
#
#       OJO: 2 significa "no sé", NO significa "está mal". Y aquí conflarlos es
#       especialmente fácil, porque el modo de fallo es silencioso: si
#       `manage.py` muere, su stdout sale VACÍO, y un `diff` contra un archivo
#       de ~30 000 líneas reporta el archivo ENTERO como diferente. Eso parece
#       una deriva catastrófica y es, en realidad, "no pude preguntar". Por eso
#       el guion comprueba el exit code Y que la salida no esté vacía Y que
#       parezca un esquema, ANTES de mirar el diff.
#
# ─── Por qué existe ──────────────────────────────────────────────────────────
# `saleor/graphql/schema.graphql` está COMMITEADO en el fork: es un artefacto
# derivado que vive en git, igual que las migraciones. Si un parche local toca
# la capa GraphQL y nadie regenera, el archivo MIENTE — y el storefront Nuxt
# vendoriza esa copia y genera sus tipos TypeScript contra ella. La mentira no
# se descubre en el fork: se descubre en el storefront, lejos y tarde.
#
# Es el hermano conceptual de `check-migrations.sh`: mismo tipo de pregunta
# (¿el artefacto derivado sigue sincronizado con el código?), mismo contrato de
# salida, mismo compromiso de no mutar nada.
#
# ─── Convenciones ────────────────────────────────────────────────────────────
# · Intérprete: ${PYTHON:-python}. En CI se le pasa el de `uv run`; en local,
#   `.venv/bin/python`; dentro de la imagen sirve el `python` del PATH.
# · Todo lo humano sale por stdout, en un solo flujo, para que ningún llamador
#   pierda la mitad del mensaje por capturar solo una de las dos salidas.
# · sh POSIX puro, sin bashismos, como los otros guiones de `scripts/`.
# · Sin `set -e` a propósito: aquí los códigos de salida distintos de cero son
#   el dato que venimos a leer, no una avería que deba abortar el guion.

PYTHON="${PYTHON:-python}"
ETIQUETA="[check-schema-fidelity]"
ESQUEMA="saleor/graphql/schema.graphql"

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
  echo "$ETIQUETA No sé responder si el esquema commiteado es fiel."
  exit 2
fi

if ! command -v "$PYTHON" >/dev/null 2>&1; then
  echo "$ETIQUETA El intérprete '$PYTHON' no existe o no es ejecutable."
  echo "$ETIQUETA Pásale uno con PYTHON=... (p. ej. PYTHON=.venv/bin/python)."
  echo "$ETIQUETA No sé responder si el esquema commiteado es fiel."
  exit 2
fi

TMP=$(mktemp -d) || {
  echo "$ETIQUETA No se pudo crear un directorio temporal. No sé responder."
  exit 2
}
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

# Ruido cosmético de arranque de Saleor, en stderr. Se filtra SOLO para lo que
# se le muestra al humano; no decide absolutamente nada. El esquema sale por
# stdout y nunca pasa por aquí.
sin_ruido() {
  grep -v -e 'AuthlibDeprecationWarning' \
          -e 'It will be compatible before version' \
          -e 'from authlib\.jose import' \
          -e '^ \[PID:' \
          -e '^[[:space:]]*$'
}

# Cómo se arregla una deriva. `build-schema` es la tarea canónica declarada en
# `pyproject.toml` ([tool.poe.tasks.build-schema]); el `>` de abajo es su
# equivalente literal, por si el llamador no tiene `poe` a mano.
consejo_regenerar() {
  echo "$ETIQUETA Para regenerarlo (tarea canónica de pyproject.toml):"
  echo "$ETIQUETA   cd $RAIZ && $PYTHON -m poethepoet build-schema"
  echo "$ETIQUETA Equivalente literal, sin poe:"
  echo "$ETIQUETA   cd $RAIZ && $PYTHON manage.py get_graphql_schema > $ESQUEMA"
  echo "$ETIQUETA Después, commitea el archivo junto al cambio de código que lo movió."
}

# ─── 1. ¿Existe el artefacto que venimos a verificar? ────────────────────────
# Falta el archivo, pero manage.py sí está: la raíz es la correcta y la
# respuesta se sabe — el esquema commiteado no es fiel, porque no hay esquema
# commiteado. Es accionable con el mismo comando de siempre, así que es 1.
if [ ! -f "$RAIZ/$ESQUEMA" ]; then
  echo "$ETIQUETA NO existe $ESQUEMA en $RAIZ."
  echo "$ETIQUETA El esquema commiteado no puede ser fiel: no está."
  consejo_regenerar
  exit 1
fi

# ─── 2. Generar el esquema desde el código, a un temporal fuera del repo ─────
"$PYTHON" manage.py get_graphql_schema >"$TMP/generado.graphql" 2>"$TMP/generado.err"
CODIGO=$?

# ─── 3. ¿Pude preguntar? Tres guardas ANTES de tocar el diff ─────────────────
# Este bloque es la razón de ser del guion. Sin él, cualquier avería del
# entorno se disfraza de deriva total del esquema.
MOTIVO=""
if [ "$CODIGO" -ne 0 ]; then
  MOTIVO="'manage.py get_graphql_schema' salió con código $CODIGO."
elif [ ! -s "$TMP/generado.graphql" ]; then
  MOTIVO="'manage.py get_graphql_schema' salió 0 pero no imprimió nada."
elif ! grep -q '^schema {' "$TMP/generado.graphql"; then
  # Salida no vacía pero que no empieza por el bloque `schema { ... }`: no es
  # un SDL de GraphQL. Comparar eso contra el archivo commiteado daría un
  # "diff" enorme y sin sentido.
  MOTIVO="la salida no parece un esquema GraphQL (no contiene 'schema {')."
fi

if [ -n "$MOTIVO" ]; then
  REVELADORA=$(sin_ruido <"$TMP/generado.err" | grep 'FATAL:' | head -n 1)
  [ -n "$REVELADORA" ] || REVELADORA=$(sin_ruido <"$TMP/generado.err" | grep 'OperationalError' | head -n 1)
  [ -n "$REVELADORA" ] || REVELADORA=$(sin_ruido <"$TMP/generado.err" | tail -n 1)
  [ -n "$REVELADORA" ] || REVELADORA="(sin mensaje en stderr; exit code $CODIGO)"

  echo "$ETIQUETA NO SE PUDO RESPONDER si el esquema commiteado es fiel."
  echo "$ETIQUETA Motivo: $MOTIVO"
  echo "$ETIQUETA Línea reveladora: $REVELADORA"

  if grep -q 'OperationalError\|FATAL:\|could not connect\|connection failed' "$TMP/generado.err"; then
    echo "$ETIQUETA El problema es la BASE DE DATOS, no el esquema."
    echo "$ETIQUETA Causa típica en local: Postgres apagado."
    echo "$ETIQUETA   brew services start postgresql@16"
  else
    echo "$ETIQUETA El problema es el ENTORNO (intérprete '$PYTHON', dependencias, settings),"
    echo "$ETIQUETA no el esquema."
  fi

  echo "$ETIQUETA Esto NO quiere decir que el esquema esté desactualizado. NO lo regeneres"
  echo "$ETIQUETA hasta arreglar esto: con el entorno roto escribirías un archivo vacío"
  echo "$ETIQUETA encima del bueno, y el storefront genera sus tipos contra ese archivo."
  exit 2
fi

# ─── 4. La comparación ───────────────────────────────────────────────────────
# Mismo orden de operandos que el hook de pre-commit (`gql-schema-check`):
# commiteado primero, generado después. Así '>' = líneas que le FALTAN al
# archivo commiteado y '<' = líneas que le SOBRAN.
if diff "$RAIZ/$ESQUEMA" "$TMP/generado.graphql" >"$TMP/diff.out" 2>"$TMP/diff.err"; then
  echo "$ETIQUETA El esquema commiteado es fiel al código: $ESQUEMA coincide"
  echo "$ETIQUETA byte a byte con la salida de 'manage.py get_graphql_schema'."
  exit 0
fi

# ─── 5. Hay deriva: decir cuánta y cómo se arregla ───────────────────────────
# Desde aquí el veredicto ya está tomado y es exit 1. Si el conteo falla, se
# pierde el DETALLE, nunca el veredicto.
# `grep -c` imprime un número (posiblemente 0) y sale 1 cuando no hay match.
# Ese 1 no es un error aquí, así que no se encadena con `||`: se ignora y se
# valida el contenido, que es el dato.
FALTAN=$(grep -c '^>' "$TMP/diff.out" 2>/dev/null)
SOBRAN=$(grep -c '^<' "$TMP/diff.out" 2>/dev/null)
[ -n "$FALTAN" ] || FALTAN="?"
[ -n "$SOBRAN" ] || SOBRAN="?"

echo "$ETIQUETA El esquema commiteado NO es fiel al código: $ESQUEMA MIENTE."
echo "$ETIQUETA Diferencias: +$FALTAN línea(s) que faltan · -$SOBRAN línea(s) que sobran."
echo "$ETIQUETA Primeras líneas del diff (commiteado < | > generado):"
head -n 20 "$TMP/diff.out" | sed "s|^|$ETIQUETA   |"
TOTAL_DIFF=$(wc -l <"$TMP/diff.out" | tr -d ' ')
if [ "$TOTAL_DIFF" -gt 20 ]; then
  echo "$ETIQUETA   ... y $((TOTAL_DIFF - 20)) línea(s) más de diff."
fi
echo "$ETIQUETA Cuidado: el storefront vendoriza este archivo y genera sus tipos"
echo "$ETIQUETA TypeScript contra él. Mientras mienta, miente también allí."
consejo_regenerar
exit 1
