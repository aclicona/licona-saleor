#!/bin/sh
# test_railway_entrypoint.sh — pruebas de scripts/railway-entrypoint.sh (B-386).
#
# Con `python` falso en el PATH y un wait-for-db falso (override WAIT_FOR_DB),
# afirma que el entrypoint NO migra, que sí espera a la DB y que hace
# `exec "$@"` del comando recibido. Uso: sh scripts/tests/test_railway_entrypoint.sh

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 2
GUION="$DIR/../railway-entrypoint.sh"

T=$(mktemp -d) || exit 2
trap 'rm -rf "$T"' EXIT HUP INT TERM
mkdir -p "$T/bin"

# python falso: registra sus argumentos.
cat >"$T/bin/python" <<'FAKE'
#!/bin/sh
echo "python $*" >>"$T/llamadas"
exit 0
FAKE
chmod +x "$T/bin/python"
cat >"$T/waitdb.sh" <<'FAKE'
echo "wait-for-db" >>"$T/llamadas"
FAKE

FALLOS=0
verifica() { # <nombre> <condición como exit code>
  if [ "$2" -eq 0 ]; then echo "ok   - $1"; else echo "FAIL - $1"; FALLOS=$((FALLOS + 1)); fi
}
corre() { # <env...> -- ejecuta el entrypoint con comando "echo ejecutado"
  : >"$T/llamadas"
  SALIDA=$(env PATH="$T/bin:$PATH" T="$T" WAIT_FOR_DB="$T/waitdb.sh" "$@" sh "$GUION" echo ejecutado 2>&1)
  COD=$?
}

corre
verifica "1 sale 0 y exec ejecuta el comando pasado" "$([ "$COD" -eq 0 ] && printf '%s' "$SALIDA" | grep -q '^ejecutado$'; echo $?)"
verifica "2 wait-for-db corre" "$(grep -q '^wait-for-db$' "$T/llamadas"; echo $?)"
verifica "3 NO invoca migrate (SKIP_MIGRATIONS ausente)" "$(! grep -q migrate "$T/llamadas"; echo $?)"

corre SKIP_MIGRATIONS=false
verifica "4 NO invoca migrate (SKIP_MIGRATIONS=false)" "$(! grep -q migrate "$T/llamadas"; echo $?)"

corre CREATE_SUPERUSER=true DJANGO_SUPERUSER_EMAIL=a@b.c DJANGO_SUPERUSER_PASSWORD=x
verifica "5 CREATE_SUPERUSER=true sigue usando manage.py shell, sin migrate" \
  "$(grep -q 'manage.py shell' "$T/llamadas" && ! grep -q migrate "$T/llamadas"; echo $?)"

if [ "$FALLOS" -ne 0 ]; then
  echo "$FALLOS caso(s) fallaron."
  exit 1
fi
echo "Todos los casos pasan."
exit 0
