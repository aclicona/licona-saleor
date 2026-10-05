#!/bin/sh
# test_check_migrations.sh — pruebas de scripts/check-migrations.sh (B-383).
#
# No necesita Postgres ni venv: sustituye al intérprete por un PYTHON falso
# (un guion sh) cuyo comportamiento se controla con variables:
#   FAKE_PROBE: ok | operational | modulenotfound   (la sonda `manage.py shell`)
#   FAKE_CHECK: 0 | silent1 | trace1 | code3        (`manage.py migrate --check`)
# Uso: sh scripts/tests/test_check_migrations.sh [ruta/al/check-migrations.sh]
# Sin argumento prueba el guion del repo. sh POSIX puro (dash).

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 2
GUION_ORIGEN="${1:-$DIR/../check-migrations.sh}"

T=$(mktemp -d) || exit 2
trap 'rm -rf "$T"' EXIT HUP INT TERM

# Réplica mínima del repo: guion en scripts/ y un manage.py a su lado.
mkdir -p "$T/scripts"
cp "$GUION_ORIGEN" "$T/scripts/check-migrations.sh"
: >"$T/manage.py"

cat >"$T/fakepython" <<'FAKE'
#!/bin/sh
case "$2" in
  shell)
    case "$FAKE_PROBE" in
      operational)
        echo 'Traceback (most recent call last):' >&2
        echo 'django.db.utils.OperationalError: connection failed: Connection refused' >&2
        exit 1 ;;
      modulenotfound)
        echo 'Traceback (most recent call last):' >&2
        echo "ModuleNotFoundError: No module named 'orjson'" >&2
        exit 1 ;;
    esac
    exit 0 ;;
  migrate)
    case "$FAKE_CHECK" in
      0) exit 0 ;;
      silent1) exit 1 ;;
      trace1)
        echo 'Traceback (most recent call last):' >&2
        echo 'RuntimeError: boom' >&2
        exit 1 ;;
      code3) exit 3 ;;
    esac ;;
  showmigrations)
    echo '[X] app.0000_initial'
    echo '[ ] app.0001_pendiente'
    exit 0 ;;
esac
exit 0
FAKE
chmod +x "$T/fakepython"

FALLOS=0
# caso <nombre> <probe> <check> <exit esperado> <texto esperado en la salida>
caso() {
  SALIDA=$(PYTHON="$T/fakepython" FAKE_PROBE="$2" FAKE_CHECK="$3" sh "$T/scripts/check-migrations.sh" 2>&1)
  COD=$?
  if [ "$COD" -eq "$4" ] && printf '%s\n' "$SALIDA" | grep -q -- "$5"; then
    echo "ok   - $1"
  else
    echo "FAIL - $1 (exit $COD, esperaba $4 con '$5')"
    printf '%s\n' "$SALIDA" | sed 's/^/       | /'
    FALLOS=$((FALLOS + 1))
  fi
}

caso "1 sonda OK + check 0 -> 0"                              ok 0 0 "al día"
caso "2 sonda OK + check 1 silencioso -> 1 y lista pendientes" ok silent1 1 "app.0001_pendiente"
caso "3 sonda OperationalError + check 1 silencioso -> 2 (B-383)" operational silent1 2 "BASE DE DATOS"
caso "4 sonda ModuleNotFoundError -> 2 ENTORNO"                modulenotfound silent1 2 "ENTORNO"
caso "5 sonda OK + check 1 con Traceback -> 2 (respaldo)"      ok trace1 2 "NO SE PUDO RESPONDER"
caso "6 sonda OK + check código 3 -> 2"                        ok code3 2 "NO SE PUDO RESPONDER"

if [ "$FALLOS" -ne 0 ]; then
  echo "$FALLOS caso(s) fallaron."
  exit 1
fi
echo "Todos los casos pasan."
exit 0
