#!/bin/sh
# test_publish_upstream_tags.sh — pruebas de scripts/publish-upstream-tags.sh (B-540).
# Uso: sh scripts/tests/test_publish_upstream_tags.sh
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 2
GUION="$DIR/../publish-upstream-tags.sh"
T=$(mktemp -d) || exit 2
trap 'rm -rf "$T"' EXIT HUP INT TERM

g() { git -C "$T/w" "$@"; }
git init -q --bare "$T/origin.git"
git init -q "$T/w" && g config user.email t@t && g config user.name t
g remote add origin "$T/origin.git"
g commit -q --allow-empty -m c1 && g tag 3.23.1
g commit -q --allow-empty -m c2 && g tag 3.23.2
g branch fork          # el fork contiene hasta 3.23.2
g commit -q --allow-empty -m c3 && g tag 3.23.3   # upstream-only
g tag 3.23.0-a.1 HEAD~2; g tag 3.22.9 HEAD~2; g tag 3.230.1 HEAD~2
g push -q origin refs/tags/3.23.1

FALLOS=0
verifica() { if eval "$2"; then echo "ok   - $1"; else echo "FALLA - $1"; FALLOS=$((FALLOS + 1)); fi; }
remotos() { git -C "$T/origin.git" tag -l | sort | tr '\n' ' '; }

SAL=$(cd "$T/w" && TARGET_REF=fork sh "$GUION" 3.23 2>&1); COD=$?
verifica "dry-run: sale 0" '[ $COD -eq 0 ]'
verifica "dry-run: propone 3.23.2" 'printf "%s" "$SAL" | grep -q "dry-run  3.23.2"'
verifica "dry-run: no propone 3.23.1 (ya publicado)" '! printf "%s" "$SAL" | grep -q "3.23.1 "'
verifica "dry-run: omite 3.23.3 (no está en el fork)" 'printf "%s" "$SAL" | grep -q "omitido  3.23.3"'
verifica "dry-run: ignora pre-releases, otros minors y 3.230" '! printf "%s" "$SAL" | grep -q "a.1\|3.22.9\|3.230"'
verifica "dry-run: NO empuja nada" '[ "$(remotos)" = "3.23.1 " ]'

SAL=$(cd "$T/w" && TARGET_REF=fork PUSH_TAGS=true sh "$GUION" 3.23 2>&1); COD=$?
verifica "push: sale 0" '[ $COD -eq 0 ]'
verifica "push: publica solo 3.23.2" '[ "$(remotos)" = "3.23.1 3.23.2 " ]'

SAL=$(cd "$T/w" && TARGET_REF=fork PUSH_TAGS=true sh "$GUION" 3.23 2>&1)
verifica "idempotente: segunda corrida sin pendientes" 'printf "%s" "$SAL" | grep -q "tags pendientes: 0"'

(cd "$T/w" && sh "$GUION" >/dev/null 2>&1); verifica "sin argumentos: sale 2" '[ $? -eq 2 ]'

echo; [ "$FALLOS" -eq 0 ] && { echo "todo verde"; exit 0; }; echo "$FALLOS fallo(s)"; exit 1
