#!/bin/sh
# with-venv.sh — corre un comando con el venv del repo en el PATH (B-388).
#
# Uso: sh scripts/with-venv.sh <comando> [args...]
#
# Los hooks `language: system` de .pre-commit-config.yaml (mypy, deptry,
# manage.py) exigían `.venv/bin` en el PATH del que invoca; sin él fallaban por
# razones ajenas al cambio ("Executable 'deptry' not found", "No module named
# 'django'") y enseñaban a ignorar el rojo. Este guion resuelve el venv solo:
#   1. <raíz del repo>/.venv/bin
#   2. si no existe (worktree): <clone principal>/.venv/bin, donde el clone
#      principal sale de `git rev-parse --git-common-dir`.
# Falla CERRADO (exit 1, mensaje claro) si no hay venv o no tiene el comando:
# jamás cae al PATH del sistema, que podría dar un verde con otras versiones.
# El exit code del comando se propaga. sh POSIX puro.

ETIQUETA="[with-venv]"

if [ "$#" -eq 0 ]; then
  echo "$ETIQUETA Uso: with-venv.sh <comando> [args...]"
  exit 2
fi

DIR_GUION=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 2
RAIZ=$(CDPATH= cd -- "$DIR_GUION/.." && pwd) || exit 2

VENV_BIN=""
if [ -d "$RAIZ/.venv/bin" ]; then
  VENV_BIN="$RAIZ/.venv/bin"
else
  COMUN=$(git -C "$RAIZ" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  if [ -n "$COMUN" ] && [ -d "$(dirname -- "$COMUN")/.venv/bin" ]; then
    VENV_BIN="$(dirname -- "$COMUN")/.venv/bin"
  fi
fi

if [ -z "$VENV_BIN" ]; then
  echo "$ETIQUETA No encontré .venv/bin en $RAIZ ni en el clone principal del repo."
  echo "$ETIQUETA Créalo: python -m venv .venv && .venv/bin/pip install -e \".[dev]\" (o 'uv sync')."
  exit 1
fi

if [ ! -x "$VENV_BIN/$1" ]; then
  echo "$ETIQUETA El venv $VENV_BIN no tiene '$1' (¿dependencias sin instalar?)."
  echo "$ETIQUETA Corre 'uv sync' o 'pip install -e \".[dev]\"' dentro de ese venv."
  exit 1
fi

PATH="$VENV_BIN:$PATH"
VIRTUAL_ENV=$(dirname -- "$VENV_BIN")
export PATH VIRTUAL_ENV
exec "$@"
