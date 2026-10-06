#!/bin/sh
# test_upsert_upstream_minor_issue.sh — pruebas de scripts/upsert-upstream-minor-issue.sh (B-618).
#
# Pone un `gh` falso primero en PATH: `issue list` imprime $LISTA (JSON) y
# `issue create|edit` se registran en $T/llamadas. Sin red ni credenciales.
# Uso: sh scripts/tests/test_upsert_upstream_minor_issue.sh

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 2
GUION="$DIR/../upsert-upstream-minor-issue.sh"

T=$(mktemp -d) || exit 2
trap 'rm -rf "$T"' EXIT HUP INT TERM
mkdir "$T/bin"

cat >"$T/bin/gh" <<'FAKE'
#!/bin/sh
# FAKE_T (no T): el guion bajo prueba define su propio $T temporal.
case "$1 $2" in
  "issue list") cat "$FAKE_T/lista.json" ;;
  "issue create"|"issue edit")
    echo "$1 $2 $*" >>"$FAKE_T/llamadas"
    while [ $# -gt 0 ]; do
      [ "$1" = "--body-file" ] && cp "$2" "$FAKE_T/cuerpo-enviado.md"
      shift
    done ;;
  *) echo "gh inesperado: $*" >&2; exit 9 ;;
esac
FAKE
chmod +x "$T/bin/gh"

FALLOS=0
correr() {
  rm -f "$T/llamadas"
  SALIDA=$(PATH="$T/bin:$PATH" FAKE_T="$T" CURRENT=3.23 NEXT=3.24 LATEST="$1" BEHIND=1 sh "$GUION" 2>&1)
  COD=$?
}
verificar() { # <nombre> <patrón en llamadas ('' = ninguna)>
  LL=$(cat "$T/llamadas" 2>/dev/null)
  if [ "$COD" -eq 0 ] && { [ -z "$2" ] && [ -z "$LL" ] || { [ -n "$2" ] && printf '%s' "$LL" | grep -q -- "$2"; }; }; then
    echo "ok   - $1"
  else
    echo "FAIL - $1 (exit $COD, llamadas: '$LL')"
    printf '%s\n' "$SALIDA" | sed 's/^/       | /'
    FALLOS=$((FALLOS + 1))
  fi
}

# Cuerpo actual = el que el guion generaría para 3.24.5 (se captura de una creación).
echo '[]' >"$T/lista.json"
correr 3.24.5
verificar "1 sin issue abierto -> create" "^issue create .*--label upstream-minor"
cp "$T/cuerpo-enviado.md" "$T/cuerpo-creado.md"
jq -Rs --arg t "chore: Saleor 3.24 disponible — siguiente minor del fork" \
  '[{number: 1, title: $t, body: .}]' "$T/cuerpo-creado.md" >"$T/lista-al-dia.json"

cp "$T/lista-al-dia.json" "$T/lista.json"
correr 3.24.5
verificar "2 issue al día -> no hace nada" ""

correr 3.24.7
verificar "3 latest cambió -> edit del #1" "^issue edit issue edit 1 "

jq '.[0].title = "chore: Saleor 3.23 disponible — siguiente minor del fork"' "$T/lista-al-dia.json" >"$T/lista.json"
correr 3.24.5
verificar "4 título de un minor anterior (mismo label) -> edit, no create" "^issue edit issue edit 1 "

jq '.[0].title = "otro título cualquiera"' "$T/lista-al-dia.json" >"$T/lista.json"
correr 3.24.5
verificar "5 idempotencia por label, no por título -> nunca create" "^issue edit "

jq '.[0].body |= gsub("\n"; "\r\n")' "$T/lista-al-dia.json" >"$T/lista.json"
correr 3.24.5
verificar "6 cuerpo con CRLF equivalente -> no hace nada" ""

if [ "$FALLOS" -ne 0 ]; then
  echo "$FALLOS caso(s) fallaron."
  exit 1
fi
echo "Todos los casos pasan."
exit 0
