#!/bin/sh
# test_tests_aislados_de_git_dir.sh — los tests de scripts/tests no deben escribir en un repo
# externo cuando heredan GIT_DIR (B-1416). Dentro de un hook de git, `git -C` no protege: un
# GIT_DIR absoluto gana y `git config user.name t` acababa en el .git/config del checkout.
# Se ejecuta cada test con GIT_DIR apuntando a un repo centinela y se mide SU config, no el
# exit del test (uno que sale != 0 por falta de herramientas no cuenta como contaminación).
# Uso: sh scripts/tests/test_tests_aislados_de_git_dir.sh

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 2
YO=$(basename -- "$0")
T=$(mktemp -d) || exit 2
trap 'rm -rf "$T"' EXIT HUP INT TERM

# Los centinelas se crean sin GIT_DIR heredado, para que este test sea fiable dentro de un hook.
unset $(git rev-parse --local-env-vars)

FALLOS=0
verifica() { if eval "$2"; then echo "ok   - $1"; else echo "FALLA - $1"; FALLOS=$((FALLOS + 1)); fi; }

for t in "$DIR"/test_*.sh; do
  N=$(basename -- "$t")
  [ "$N" = "$YO" ] && continue
  C="$T/centinela-$N"   # un centinela por test: un culpable no tapa a los siguientes
  git init -q "$C" || exit 2
  GIT_DIR="$C/.git" sh "$t" >"$T/salida" 2>&1 </dev/null
  CONF=$(git --git-dir="$C/.git" config --local --get-regexp '^user\.' 2>/dev/null)
  REFS=$(git --git-dir="$C/.git" for-each-ref 2>/dev/null)
  verifica "$N no escribe en el repo heredado por GIT_DIR" '[ -z "$CONF" ] && [ -z "$REFS" ]'
done

[ "$FALLOS" -eq 0 ] || { echo "$FALLOS fallo(s)"; exit 1; }
echo "todo ok"
