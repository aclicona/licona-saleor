#!/bin/sh
# test_check_invalid_indexes_pg.sh — check-invalid-indexes.sh contra un Postgres REAL (B-1288).
#
# Levanta un cluster efímero (initdb en un temporal, 127.0.0.1:55437, apagado por trap; nunca
# toca otros Postgres), fabrica un índice INVALID de forma determinista y comprueba el guion:
#   1) base vacía                      -> exit 0
#   2) CREATE UNIQUE INDEX CONCURRENTLY sobre duplicados (falla y deja INVALID) -> exit 1 y lo nombra
#   3) DROP INDEX CONCURRENTLY         -> exit 0
#   4) base apagada                    -> exit 2
# No necesita migrar Saleor: el guion solo consulta pg_index. Sí necesita un PYTHON con Django y
# el fork importable (PYTHON=...), y initdb/pg_ctl/psql (brew postgresql@16/17 o Postgres.app).
# Si falta alguno de los dos: sale 0 con «SKIP» (no es un fallo del código).
# Uso: PYTHON=.venv/bin/python sh scripts/tests/test_check_invalid_indexes_pg.sh

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 2
GUION="$DIR/../check-invalid-indexes.sh"
PYTHON="${PYTHON:-python}"
PUERTO="${PG_TEST_PORT:-55437}"

BIN=""
for c in ${PG_BIN:+"$PG_BIN"} /Applications/Postgres.app/Contents/Versions/latest/bin \
         /opt/homebrew/opt/postgresql@17/bin /opt/homebrew/opt/postgresql@16/bin /usr/lib/postgresql/16/bin; do
  if [ -x "$c/initdb" ] && [ -x "$c/pg_ctl" ] && [ -x "$c/psql" ]; then BIN="$c"; break; fi
done
[ -n "$BIN" ] || { echo "SKIP - no hay initdb/pg_ctl/psql"; exit 0; }
command -v "$PYTHON" >/dev/null 2>&1 || { echo "SKIP - no hay intérprete '$PYTHON'"; exit 0; }

T=$(mktemp -d) || exit 2
PG_ARRANCADO=0
parar_pg() { [ "$PG_ARRANCADO" -eq 1 ] && "$BIN/pg_ctl" -D "$T/data" -m immediate stop >/dev/null 2>&1; PG_ARRANCADO=0; }
trap 'parar_pg; rm -rf "$T"' EXIT HUP INT TERM

export LC_ALL="${LC_ALL:-en_US.UTF-8}"
"$BIN/initdb" -D "$T/data" -U postgres --auth=trust -E UTF8 >"$T/initdb.out" 2>&1 </dev/null \
  || { echo "FAIL - initdb"; tail -n 5 "$T/initdb.out"; exit 1; }
"$BIN/pg_ctl" -D "$T/data" -l "$T/pg.log" -w \
  -o "-p $PUERTO -c listen_addresses=127.0.0.1 -c unix_socket_directories= -c fsync=off" \
  start >"$T/start.out" 2>&1 </dev/null || { echo "FAIL - pg_ctl start"; tail -n 5 "$T/pg.log"; exit 1; }
PG_ARRANCADO=1
psql_() { "$BIN/psql" -h 127.0.0.1 -p "$PUERTO" -U postgres -d postgres -v ON_ERROR_STOP=0 -Atq -c "$1" >>"$T/psql.out" 2>&1 </dev/null; }

export DATABASE_URL="postgres://postgres@127.0.0.1:$PUERTO/postgres"
FALLOS=0
# paso <nombre> <exit esperado> <texto esperado>
paso() {
  SALIDA=$(PYTHON="$PYTHON" sh "$GUION" 2>&1)
  COD=$?
  if [ "$COD" -eq "$2" ] && printf '%s\n' "$SALIDA" | grep -q -- "$3"; then
    echo "ok   - $1"
  else
    echo "FAIL - $1 (exit $COD, esperaba $2 con '$3')"
    printf '%s\n' "$SALIDA" | sed 's/^/       | /'
    FALLOS=$((FALLOS + 1))
  fi
}

paso "1 base sin índices inválidos -> 0" 0 "No hay índices inválidos"

psql_ "CREATE TABLE public.b1288_tabla (v int);"
psql_ "INSERT INTO public.b1288_tabla VALUES (1), (1);"
psql_ "CREATE UNIQUE INDEX CONCURRENTLY b1288_uniq ON public.b1288_tabla (v);"   # falla: duplicados
INVALIDOS=$("$BIN/psql" -h 127.0.0.1 -p "$PUERTO" -U postgres -d postgres -Atq \
  -c "SELECT count(*) FROM pg_index WHERE NOT indisvalid" 2>&1 </dev/null)
[ "$INVALIDOS" = "1" ] || { echo "FAIL - no se fabricó el índice INVALID (count=$INVALIDOS)"; cat "$T/psql.out"; exit 1; }

paso "2 índice INVALID -> 1 y lo nombra" 1 'public.b1288_uniq (b1288_tabla)'
paso "3 …con la receta DROP literal"      1 'DROP INDEX CONCURRENTLY IF EXISTS "public"."b1288_uniq";'

psql_ 'DROP INDEX CONCURRENTLY IF EXISTS "public"."b1288_uniq";'
paso "4 tras el DROP de la receta -> 0"   0 "No hay índices inválidos"

parar_pg
paso "5 base apagada -> 2"                2 "NO SE PUDO RESPONDER"

if [ "$FALLOS" -ne 0 ]; then
  echo "$FALLOS caso(s) fallaron."
  exit 1
fi
echo "Todos los casos pasan."
exit 0
