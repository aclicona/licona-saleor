#!/bin/sh
# test_wait_for_migrations.sh — pruebas de scripts/wait-for-migrations.sh (B-386).
#
# Sustituye a check-migrations.sh por un CHECK_MIGRATIONS falso que devuelve los
# códigos de $FAKE_SEQ (separados por espacios; el último se repite) y cuenta
# los intentos en $T/intentos. Sin esperas reales: MIGRATIONS_POLL_SECONDS=0.
# Uso: sh scripts/tests/test_wait_for_migrations.sh

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 2
GUION="$DIR/../wait-for-migrations.sh"

T=$(mktemp -d) || exit 2
trap 'rm -rf "$T"' EXIT HUP INT TERM

cat >"$T/fakecheck" <<'FAKE'
#!/bin/sh
N=$(cat "$T/intentos" 2>/dev/null || echo 0)
N=$((N + 1))
echo "$N" >"$T/intentos"
CODIGO=0
I=0
for C in $FAKE_SEQ; do
  I=$((I + 1))
  CODIGO=$C
  [ "$I" -ge "$N" ] && break
done
echo "respuesta falsa $N -> $CODIGO"
exit "$CODIGO"
FAKE

FALLOS=0
# caso <nombre> <secuencia> <wait> <exit esperado> <intentos esperados> <texto esperado>
caso() {
  rm -f "$T/intentos"
  SALIDA=$(T="$T" FAKE_SEQ="$2" CHECK_MIGRATIONS="$T/fakecheck" \
    MIGRATIONS_POLL_SECONDS=0 MIGRATIONS_WAIT_SECONDS="$3" sh "$GUION" 2>&1)
  COD=$?
  INT=$(cat "$T/intentos" 2>/dev/null || echo 0)
  if [ "$COD" -eq "$4" ] && [ "$INT" -eq "$5" ] && printf '%s\n' "$SALIDA" | grep -q -- "$6"; then
    echo "ok   - $1"
  else
    echo "FAIL - $1 (exit $COD, $INT intentos; esperaba $4 y $5 con '$6')"
    printf '%s\n' "$SALIDA" | sed 's/^/       | /'
    FALLOS=$((FALLOS + 1))
  fi
}

caso "1 al día a la primera -> 0 sin reintentar"   "0"     5 0 1 "al día"
caso "2 secuencia 2,1,0 -> 0 en 3 intentos"        "2 1 0" 10 0 3 "al día"
caso "3 siempre pendiente (1) -> 1 al vencer"      "1"     3 1 4 "Se agotó la espera"
caso "4 siempre inaccesible (2) -> 1 al vencer"    "2"     2 1 3 "Se agotó la espera"

if [ "$FALLOS" -ne 0 ]; then
  echo "$FALLOS caso(s) fallaron."
  exit 1
fi
echo "Todos los casos pasan."
exit 0
