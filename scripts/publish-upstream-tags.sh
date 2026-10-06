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

set -u

[ "$#" -ge 1 ] || { echo "uso: publish-upstream-tags.sh <minor>..." >&2; exit 2; }
TARGET_REF=${TARGET_REF:-HEAD}
PUSH_REMOTE=${PUSH_REMOTE:-origin}
PUSH_TAGS=${PUSH_TAGS:-false}

REMOTE_TAGS=$(git ls-remote --tags "$PUSH_REMOTE" | sed -n 's|.*refs/tags/\([^^]*\)$|\1|p') || exit 1

FALLOS=0
PENDIENTES=0
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
      if git push "$PUSH_REMOTE" "refs/tags/$TAG"; then
        echo "publicado $TAG"
      else
        echo "FALLÓ    $TAG" >&2
        FALLOS=$((FALLOS + 1))
      fi
    else
      echo "dry-run  $TAG (se publicaría con PUSH_TAGS=true)"
    fi
  done
done

echo "tags pendientes: $PENDIENTES"
[ "$FALLOS" -eq 0 ]
