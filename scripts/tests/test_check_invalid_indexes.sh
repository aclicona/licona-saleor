#!/bin/sh
# test_check_invalid_indexes.sh — pruebas de scripts/check-invalid-indexes.sh (B-1288).
#
# No necesita Postgres ni venv: PYTHON falso (guion sh) controlado por:
#   FAKE_MODE: none | invalid | operational | modulenotfound | silentfail | nodone
# Uso: sh scripts/tests/test_check_invalid_indexes.sh [ruta/al/check-invalid-indexes.sh]
# El caso contra Postgres real está en test_check_invalid_indexes_pg.sh. sh POSIX (dash).

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 2
GUION_ORIGEN="${1:-$DIR/../check-invalid-indexes.sh}"

T=$(mktemp -d) || exit 2
trap 'rm -rf "$T"' EXIT HUP INT TERM

mkdir -p "$T/scripts"
cp "$GUION_ORIGEN" "$T/scripts/check-invalid-indexes.sh"
: >"$T/manage.py"

cat >"$T/fakepython" <<'FAKE'
#!/bin/sh
# Se invoca como: fakepython manage.py shell -c <codigo>
case "$FAKE_MODE" in
  none) echo 'CHECK_DONE'; exit 0 ;;
  invalid)
    echo 'INVALID_INDEX|public|product_sku_uniq|product_productvariant'
    echo 'INVALID_INDEX|app|otro_idx|app_tabla'
    echo 'CHECK_DONE'; exit 0 ;;
  operational)
    echo 'Traceback (most recent call last):' >&2
    echo 'django.db.utils.OperationalError: connection failed: Connection refused' >&2
    exit 1 ;;
  modulenotfound)
    echo 'Traceback (most recent call last):' >&2
    echo "ModuleNotFoundError: No module named 'orjson'" >&2
    exit 1 ;;
  silentfail) exit 1 ;;
  nodone) exit 0 ;;
esac
exit 0
FAKE
chmod +x "$T/fakepython"

FALLOS=0
# caso <nombre> <modo> <exit esperado> <texto esperado> [<texto esperado 2>]
caso() {
  SALIDA=$(PYTHON="$T/fakepython" FAKE_MODE="$2" sh "$T/scripts/check-invalid-indexes.sh" 2>&1)
  COD=$?
  if [ "$COD" -eq "$3" ] && printf '%s\n' "$SALIDA" | grep -q -- "$4" \
     && { [ -z "$5" ] || printf '%s\n' "$SALIDA" | grep -q -- "$5"; }; then
    echo "ok   - $1"
  else
    echo "FAIL - $1 (exit $COD, esperaba $3 con '$4' '$5')"
    printf '%s\n' "$SALIDA" | sed 's/^/       | /'
    FALLOS=$((FALLOS + 1))
  fi
}

caso "1 sin inválidos -> 0"                                 none 0 "No hay índices inválidos"
caso "2 inválidos -> 1, lista esquema.indice (tabla)"       invalid 1 'public.product_sku_uniq (product_productvariant)' 'app.otro_idx (app_tabla)'
caso "3 inválidos -> 1, receta literal DROP ... CONCURRENTLY" invalid 1 'DROP INDEX CONCURRENTLY IF EXISTS "public"."product_sku_uniq";' 're-desplegar\|vuelve a desplegar'
caso "4 inválidos -> 1, advierte de migración en curso"      invalid 1 'EN CURSO' 'NO lo borres'
caso "5 OperationalError -> 2 BASE DE DATOS"                 operational 2 "BASE DE DATOS"
caso "6 ModuleNotFoundError -> 2 ENTORNO"                    modulenotfound 2 "ENTORNO"
caso "7 fallo silencioso (exit 1 sin traza) -> 2"            silentfail 2 "NO SE PUDO RESPONDER"
caso "8 exit 0 pero sin CHECK_DONE -> 2 (no se lee como verde)" nodone 2 "NO SE PUDO RESPONDER"

if [ "$FALLOS" -ne 0 ]; then
  echo "$FALLOS caso(s) fallaron."
  exit 1
fi
echo "Todos los casos pasan."
exit 0
