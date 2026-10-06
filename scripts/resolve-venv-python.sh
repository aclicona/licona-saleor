#!/bin/sh
# resolve-venv-python.sh — imprime la ruta del intérprete `.venv/bin/python` del fork (B-377).
#
# Un worktree de git no trae `.venv` (es un directorio sin versionar del clone
# principal), así que `$(git rev-parse --show-toplevel)/.venv/bin/python` no
# existe ahí y un hook que lo use bloquea TODO commit hecho desde un worktree.
# Orden de resolución:
#   1. `.venv/bin/python` de la raíz del árbol actual (clone principal o worktree
#      con venv propio: gana el más cercano).
#   2. `.venv/bin/python` del clone principal, deducido de `git rev-parse
#      --git-common-dir` (en un worktree apunta al `.git` del clone principal).
# Si ninguno es ejecutable, FALLA CERRADO: no adivina `python` del PATH, porque
# un intérprete equivocado puede dar «esquema fiel» sin haber preguntado de verdad.
#
# Contrato: stdout = SOLO la ruta (para `PYTHON=$(sh scripts/resolve-venv-python.sh)`);
# los mensajes humanos salen por stderr. Salida 0 = resuelto · 2 = no se pudo.
# sh POSIX, sin Django. Uso en un hook de esquema:
#   PYTHON=$(sh scripts/resolve-venv-python.sh) || exit 1
#   PYTHON="$PYTHON" sh scripts/check-schema-fidelity.sh

ETIQUETA="[resolve-venv-python]"

RAIZ=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "$ETIQUETA No estoy dentro de un repo git. No sé qué intérprete usar." >&2
  exit 2
}

if [ -x "$RAIZ/.venv/bin/python" ]; then
  printf '%s\n' "$RAIZ/.venv/bin/python"
  exit 0
fi

COMUN=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || COMUN=""
if [ -n "$COMUN" ]; then
  PRINCIPAL=$(dirname -- "$COMUN")
  if [ "$PRINCIPAL" != "$RAIZ" ] && [ -x "$PRINCIPAL/.venv/bin/python" ]; then
    printf '%s\n' "$PRINCIPAL/.venv/bin/python"
    exit 0
  fi
fi

echo "$ETIQUETA No hay .venv/bin/python ejecutable en $RAIZ" >&2
[ -n "${PRINCIPAL:-}" ] && echo "$ETIQUETA ni en el clone principal ($PRINCIPAL)." >&2
echo "$ETIQUETA Crea el entorno (uv sync) en el clone principal o pasa PYTHON=... explícito." >&2
exit 2
