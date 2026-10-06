#!/bin/sh
# test_resolve_venv_python.sh — pruebas de scripts/resolve-venv-python.sh (B-377).
#
# Crea repos git reales en un temporal (un clone "principal" y un worktree) y
# comprueba qué intérprete resuelve el guion. Sin Django ni red.
# Uso: sh scripts/tests/test_resolve_venv_python.sh

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 2
GUION="$DIR/../resolve-venv-python.sh"

T=$(mktemp -d) || exit 2
trap 'rm -rf "$T"' EXIT HUP INT TERM
T=$(CDPATH= cd -- "$T" && pwd -P)

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git init -q "$T/main" || exit 2
git -C "$T/main" commit -q --allow-empty -m raiz || exit 2
git -C "$T/main" worktree add -q "$T/wt" -b rama || exit 2
mkdir -p "$T/main/.venv/bin"
printf '#!/bin/sh\n' >"$T/main/.venv/bin/python"
chmod +x "$T/main/.venv/bin/python"

FALLOS=0
# caso <nombre> <cwd> <exit esperado> <stdout esperado ('' = vacío)>
caso() {
  SALIDA=$(cd "$2" && sh "$GUION" 2>"$T/err")
  COD=$?
  if [ "$COD" -eq "$3" ] && [ "$SALIDA" = "$4" ]; then
    echo "ok   - $1"
  else
    echo "FAIL - $1 (exit $COD, stdout '$SALIDA'; esperaba $3 y '$4')"
    sed 's/^/       | /' "$T/err"
    FALLOS=$((FALLOS + 1))
  fi
}

caso "1 clone principal con .venv -> su .venv" "$T/main" 0 "$T/main/.venv/bin/python"
caso "2 worktree sin .venv -> cae al .venv del clone principal" "$T/wt" 0 "$T/main/.venv/bin/python"

mkdir -p "$T/wt/.venv/bin"
printf '#!/bin/sh\n' >"$T/wt/.venv/bin/python"
chmod +x "$T/wt/.venv/bin/python"
caso "3 worktree con .venv propio -> el suyo (tiene prioridad)" "$T/wt" 0 "$T/wt/.venv/bin/python"
rm -rf "$T/wt/.venv"

mkdir "$T/wt/sub"
caso "4 desde un subdirectorio del worktree -> igual que 2" "$T/wt/sub" 0 "$T/main/.venv/bin/python"

rm -rf "$T/main/.venv"
caso "5 ningún .venv en worktree ni principal -> falla cerrado (2)" "$T/wt" 2 ""
caso "6 clone principal sin .venv -> falla cerrado (2)" "$T/main" 2 ""

mkdir "$T/fuera"
caso "7 fuera de un repo git -> falla cerrado (2)" "$T/fuera" 2 ""

mkdir -p "$T/main/.venv/bin"   # .venv/bin/python NO ejecutable
printf 'x' >"$T/main/.venv/bin/python"
caso "8 .venv/bin/python existe pero no es ejecutable -> falla cerrado (2)" "$T/wt" 2 ""

if [ "$FALLOS" -ne 0 ]; then
  echo "$FALLOS caso(s) fallaron."
  exit 1
fi
echo "Todos los casos pasan."
exit 0
