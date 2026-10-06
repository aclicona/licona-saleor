#!/bin/sh
# test_with_venv.sh — pruebas de scripts/with-venv.sh (B-388).
# Crea repos git temporales; no necesita el venv real. sh POSIX puro.
# Uso: sh scripts/tests/test_with_venv.sh [ruta/al/with-venv.sh]

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 2
ORIGEN="${1:-$DIR/../with-venv.sh}"

T=$(mktemp -d) || exit 2
trap 'rm -rf "$T"' EXIT HUP INT TERM

FALLOS=0
# verificar <nombre> <exit esperado> <texto esperado> <exit real> <salida>
verificar() {
  if [ "$4" -eq "$2" ] && printf '%s\n' "$5" | grep -q -- "$3"; then
    echo "ok   - $1"
  else
    echo "FAIL - $1 (exit $4, esperaba $2 con '$3')"
    printf '%s\n' "$5" | sed 's/^/       | /'
    FALLOS=$((FALLOS + 1))
  fi
}

# Repo principal con scripts/with-venv.sh copiado.
nuevo_repo() {
  mkdir -p "$1/scripts"
  cp "$ORIGEN" "$1/scripts/with-venv.sh"
  git -C "$1" init -q 2>/dev/null
}
# Venv falso con un ejecutable `herramienta` que imprime de dónde viene.
venv_falso() {
  mkdir -p "$1/.venv/bin"
  printf '#!/bin/sh\necho "herramienta del venv de %s"\n' "$1" >"$1/.venv/bin/herramienta"
  chmod +x "$1/.venv/bin/herramienta"
}

# 1. Venv en el propio repo.
nuevo_repo "$T/a"; venv_falso "$T/a"
S=$(cd "$T/a" && sh scripts/with-venv.sh herramienta 2>&1); C=$?
verificar "1 venv propio -> lo usa" 0 "venv de $T/a" "$C" "$S"

# 2. Sin venv en ninguna parte: falla cerrado con mensaje claro.
nuevo_repo "$T/b"
S=$(cd "$T/b" && sh scripts/with-venv.sh herramienta 2>&1); C=$?
verificar "2 sin venv -> exit 1 y mensaje" 1 "No encontré .venv/bin" "$C" "$S"

# 3. Worktree sin venv propio: usa el del clone principal.
nuevo_repo "$T/c"; venv_falso "$T/c"
git -C "$T/c" -c user.name=t -c user.email=t@t commit -q --allow-empty -m x 2>/dev/null
git -C "$T/c" worktree add -q "$T/c-wt" -b wt 2>/dev/null
mkdir -p "$T/c-wt/scripts"; cp "$ORIGEN" "$T/c-wt/scripts/with-venv.sh"
S=$(cd "$T/c-wt" && sh scripts/with-venv.sh herramienta 2>&1); C=$?
verificar "3 worktree -> venv del clone principal" 0 "venv de $T/c" "$C" "$S"

# 4. Venv presente pero sin la herramienta: falla cerrado, no cae al PATH.
nuevo_repo "$T/d"; mkdir -p "$T/d/.venv/bin"
S=$(cd "$T/d" && sh scripts/with-venv.sh herramienta 2>&1); C=$?
verificar "4 venv sin la herramienta -> exit 1" 1 "no tiene 'herramienta'" "$C" "$S"

# 5. El exit code del comando se propaga.
nuevo_repo "$T/e"; mkdir -p "$T/e/.venv/bin"
printf '#!/bin/sh\nexit 7\n' >"$T/e/.venv/bin/falla"; chmod +x "$T/e/.venv/bin/falla"
S=$(cd "$T/e" && sh scripts/with-venv.sh falla 2>&1); C=$?
verificar "5 propaga el exit code del comando" 7 "" "$C" "$S"

if [ "$FALLOS" -ne 0 ]; then echo "$FALLOS caso(s) fallaron."; exit 1; fi
echo "Todos los casos pasan."
exit 0
