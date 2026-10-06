#!/bin/sh
# upsert-upstream-minor-issue.sh — crea o ACTUALIZA el issue `upstream-minor` (B-618).
#
# Lo invoca el job `check-new-minor` de sync-upstream.yml. Antes solo creaba el
# issue y lo idempotizaba por título exacto: el cuerpo (latest, behind) se
# congelaba el día de creación (el #1 decía 3.23.28 cuando upstream ya iba por
# 3.23.36). Ahora:
#   · Idempotencia POR LABEL: si hay un issue abierto con la label `upstream-minor`
#     es EL issue, aunque su título sea de un minor anterior.
#   · Si existe y título o cuerpo difieren de lo esperado -> `gh issue edit`.
#   · Si existe y ya coincide -> no hace nada (sin ruido).
#   · Si no existe -> `gh issue create`.
#
# Variables obligatorias: CURRENT NEXT LATEST BEHIND. Requiere `gh` y `jq` en PATH
# (GH_TOKEN/GH_REPO los pone el workflow). sh POSIX, sin Django.
# Salida: 0 ok · 2 faltan variables.

: "${CURRENT:?falta CURRENT}" "${NEXT:?falta NEXT}" "${LATEST:?falta LATEST}" "${BEHIND:?falta BEHIND}" || exit 2

T=$(mktemp -d) || exit 2
trap 'rm -rf "$T"' EXIT HUP INT TERM

TITLE="chore: Saleor ${NEXT} disponible — siguiente minor del fork"

cat >"$T/body.md" <<EOF
El fork está en **${CURRENT}** y upstream ya publicó **${LATEST}**.
Minors por delante en total: **${BEHIND}**.

## Por qué esto es un issue y no un PR

Saleor solo garantiza migraciones sin downtime **entre minors consecutivos**. No se
puede saltar de ${CURRENT} a un minor posterior directamente: hay que pasar por
${NEXT} primero. Por eso el salto de minor es una decisión humana planificada y no un
merge automático — el job \`sync\` de este mismo workflow solo trae parches dentro de
${CURRENT}.x.

Cuantos más minors se acumulen, más caro sale: no se paga un upgrade, se pagan todos
los intermedios, cada uno con su tanda de migraciones.

## Qué hay que hacer

1. Leer el changelog de upstream entre \`${CURRENT}\` y \`${LATEST}\`, con foco en
   migraciones y cambios de esquema GraphQL.
2. Revisar \`UPGRADE_NOTES.md\` — ahí está todo lo que este fork cambió respecto a
   upstream, que es exactamente donde van a aparecer los conflictos.
3. Rama de upgrade desde \`stable/${CURRENT}\`, merge de \`refs/tags/${LATEST}\`,
   resolver conflictos.
4. Correr las migraciones contra una copia de la BD, no solo la suite.
5. Verificar el storefront y las apps de pago contra la API nueva: el esquema GraphQL
   cambia entre minors y el codegen del storefront depende de él.
6. Al terminar: actualizar \`version\` en \`pyproject.toml\`, renombrar la rama base a
   \`stable/${NEXT}\` y **cambiar la rama por defecto del repo** — si no, este
   workflow deja de correr (ver el comentario al inicio de \`sync-upstream.yml\`).

---
_Mantenido automáticamente por \`.github/workflows/sync-upstream.yml\`: título y cuerpo se
actualizan cada lunes mientras el fork siga en ${CURRENT}; ciérralo cuando el upgrade esté
planificado._
EOF

gh issue list --state open --label upstream-minor --limit 100 \
  --json number,title,body >"$T/lista.json" || exit 1

NUM=$(jq -r '.[0].number // empty' "$T/lista.json")

if [ -z "$NUM" ]; then
  gh issue create --title "$TITLE" --label "upstream-minor" --body-file "$T/body.md"
  exit $?
fi

jq -r '.[0].title // ""' "$T/lista.json" >"$T/titulo-actual"
# La API puede devolver el cuerpo con CRLF; se normaliza para comparar.
jq -r '.[0].body // ""' "$T/lista.json" | tr -d '\r' >"$T/cuerpo-actual"

if [ "$(cat "$T/titulo-actual")" = "$TITLE" ] && [ "$(cat "$T/cuerpo-actual")" = "$(cat "$T/body.md")" ]; then
  echo "El issue #$NUM ya está al día (${NEXT}, ${LATEST}) — nada que hacer."
  exit 0
fi

echo "Actualizando el issue #$NUM a ${NEXT} / ${LATEST}."
gh issue edit "$NUM" --title "$TITLE" --body-file "$T/body.md"
