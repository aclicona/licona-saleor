#!/bin/sh
# resolve-uv-lock.sh — resuelve el conflicto mecánico de uv.lock en un merge de sync (B-567).
#
# Uso: scripts/resolve-uv-lock.sh <tag-upstream>   (con un `git merge --no-commit` en curso)
#
# `.gitattributes` trae `*.lock -merge` de upstream: uv.lock conflictúa SIEMPRE en el sync.
# La resolución correcta es regenerarlo, no elegir un lado: se parte del lock del tag de
# upstream y `uv lock` añade las deps propias del fork (python-dotenv) de pyproject.toml.
#
# Salida: 0 si uv.lock no estaba en conflicto o quedó resuelto y agregado al índice;
#         1 si no se pudo resolver (uv.lock queda con su conflicto original).
# No toca ningún otro archivo en conflicto.
#
# Entorno: UV_CMD (por defecto `uv tool run uv@<versión del Dockerfile>`): la versión se
# lee del Dockerfile, no se fija aquí, para que no caduque cuando upstream suba uv.

set -u

TAG=${1:?uso: resolve-uv-lock.sh <tag-upstream>}
DOCKERFILE=${DOCKERFILE:-Dockerfile}

CONFLICTED=$(git diff --name-only --diff-filter=U)

if ! printf '%s\n' "$CONFLICTED" | grep -qx 'uv.lock'; then
  echo "uv.lock no está en conflicto — nada que resolver."
  exit 0
fi

# Si pyproject.toml también conflictúa, regenerar partiría de marcadores: lo resuelve un humano.
if printf '%s\n' "$CONFLICTED" | grep -qx 'pyproject.toml'; then
  echo "pyproject.toml también está en conflicto — uv.lock se deja para resolución humana."
  exit 1
fi

if [ -z "${UV_CMD:-}" ]; then
  UV_VERSION=$(sed -n 's|.*astral-sh/uv:\([0-9][0-9.]*\).*|\1|p' "$DOCKERFILE" | head -n 1)
  if [ -z "$UV_VERSION" ]; then
    echo "No se encontró la versión de uv en $DOCKERFILE." >&2
    exit 1
  fi
  UV_CMD="uv tool run uv@$UV_VERSION"
fi

BACKUP=$(mktemp) || exit 1
trap 'rm -f "$BACKUP"' EXIT HUP INT TERM
cp uv.lock "$BACKUP"

restaurar() {
  cp "$BACKUP" uv.lock
  echo "$1 — uv.lock queda con su conflicto original." >&2
  exit 1
}

git show "refs/tags/$TAG:uv.lock" > uv.lock 2>/dev/null || restaurar "No se pudo leer uv.lock de $TAG"
# shellcheck disable=SC2086
$UV_CMD lock || restaurar "uv lock falló"

git add uv.lock || restaurar "git add uv.lock falló"
echo "uv.lock regenerado con: $UV_CMD lock"
