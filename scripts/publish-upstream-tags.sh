#!/bin/sh
# publish-upstream-tags.sh — publica en el fork los tags de upstream que el fork ya contiene (B-540).
#
# Uso: scripts/publish-upstream-tags.sh <minor> [<minor>...]      (p. ej. 3.23)
#
# Un tag `X.Y.N` de upstream se publica en el remoto del fork solo si:
#   - existe localmente (tras `git fetch upstream --tags`),
#   - su commit es ancestro de $TARGET_REF (el fork de verdad lo contiene), y
#   - el remoto del fork no lo tiene.
# Así la etiqueta "dice" la versión que el fork tiene, ni una más.
#
# DRY-RUN POR DEFECTO: solo imprime lo que empujaría. Para empujar de verdad: PUSH_TAGS=true.
# Entorno: TARGET_REF (def. HEAD), PUSH_REMOTE (def. origin), PUSH_TAGS (def. false).
#
# B-1280: si un push falla y corre en GitHub Actions (GITHUB_ACTIONS=true) emite un `::warning` por tag y,
# al final, un bloque en $GITHUB_STEP_SUMMARY; el paso del workflow es continue-on-error y sin esto el fallo
# (típico: el commit del tag toca .github/workflows y GITHUB_TOKEN no tiene permiso `workflows`) pasa inadvertido.

set -u

[ "$#" -ge 1 ] || { echo "uso: publish-upstream-tags.sh <minor>..." >&2; exit 2; }
TARGET_REF=${TARGET_REF:-HEAD}
PUSH_REMOTE=${PUSH_REMOTE:-origin}
PUSH_TAGS=${PUSH_TAGS:-false}

REMOTE_TAGS=$(git ls-remote --tags "$PUSH_REMOTE" | sed -n 's|.*refs/tags/\([^^]*\)$|\1|p') || exit 1

REPO_REF=${GITHUB_REPOSITORY:-<owner>/<repo>}
FALLOS=0
PENDIENTES=0
TAGS_FALLIDOS=""

# Causa probable según la salida de error del push (B-1280).
causa_probable() {
  if printf '%s' "$1" | grep -qi 'workflow'; then
    echo "el commit del tag toca .github/workflows y GITHUB_TOKEN no tiene el permiso workflows"
  else
    echo "causa no identificada (revisar la salida del push; lo habitual es que el commit toque .github/workflows y GITHUB_TOKEN no tenga el permiso workflows)"
  fi
}

remedio() {
  echo "crearla a mano con un token con scope workflow: gh api repos/$REPO_REF/git/refs -f ref=refs/tags/$1 -f sha=$2 (como en B-540)"
}

avisa_fallo() {
  TAGS_FALLIDOS="$TAGS_FALLIDOS $1"
  [ "${GITHUB_ACTIONS:-}" = "true" ] || return 0
  SHA=$(git rev-list -n 1 "$1" 2>/dev/null || echo "<sha>")
  echo "::warning title=Tag de upstream sin publicar::$1 no se pudo publicar: $(causa_probable "$2"). Remedio: $(remedio "$1" "$SHA")"
}

resumen_fallos() {
  [ -n "$TAGS_FALLIDOS" ] && [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
  {
    echo "### Tags de upstream sin publicar"
    echo
    for T in $TAGS_FALLIDOS; do
      echo "- \`$T\` — remedio: $(remedio "$T" "$(git rev-list -n 1 "$T" 2>/dev/null || echo '<sha>')")"
    done
    echo
    echo "Causa probable: el commit del tag toca \`.github/workflows\` y \`GITHUB_TOKEN\` no tiene el permiso \`workflows\`."
  } >> "$GITHUB_STEP_SUMMARY"
}

for MINOR in "$@"; do
  PATRON=$(printf '%s' "$MINOR" | sed 's/\./\\./g')
  for TAG in $(git tag -l "$MINOR.*" --sort=v:refname | grep -E "^${PATRON}\.[0-9]+$"); do
    printf '%s\n' "$REMOTE_TAGS" | grep -qx "$TAG" && continue
    if ! git merge-base --is-ancestor "$TAG" "$TARGET_REF"; then
      echo "omitido  $TAG (su commit aún no está en $TARGET_REF)"
      continue
    fi
    PENDIENTES=$((PENDIENTES + 1))
    if [ "$PUSH_TAGS" = "true" ]; then
      if SALIDA_PUSH=$(git push "$PUSH_REMOTE" "refs/tags/$TAG" 2>&1); then
        [ -z "$SALIDA_PUSH" ] || printf '%s\n' "$SALIDA_PUSH" >&2
        echo "publicado $TAG"
      else
        printf '%s\n' "$SALIDA_PUSH" >&2
        echo "FALLÓ    $TAG" >&2
        avisa_fallo "$TAG" "$SALIDA_PUSH"
        FALLOS=$((FALLOS + 1))
      fi
    else
      echo "dry-run  $TAG (se publicaría con PUSH_TAGS=true)"
    fi
  done
done

echo "tags pendientes: $PENDIENTES"
resumen_fallos
[ "$FALLOS" -eq 0 ]
