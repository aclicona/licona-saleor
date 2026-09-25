#!/bin/sh
# check-branch-protection.sh — ¿la branch protection de la rama de despliegue
# coincide con el contrato que este fork afirma?
#
# Responde esa pregunta y NADA MÁS. Nunca muta: solo hace peticiones GET a la
# API de GitHub. La decisión de qué hacer con la respuesta es del llamador.
#
# ─── Contrato de salida ──────────────────────────────────────────────────────
#   0 — La protección coincide con el contrato esperado.
#   1 — Hay deriva REAL y accionable: la rama existe pero NO está protegida,
#       o algún campo de la protección no coincide con lo esperado.
#   2 — NO SE PUDO RESPONDER ("no sé", NO "está mal"): no hay `gh` instalado,
#       no hay sesión autenticada, el repo o la rama no existen, permisos
#       insuficientes (403), o el JSON de respuesta es ilegible.
#
#       OJO: 2 significa "no sé", NO significa "está mal". Y aquí conflarlos
#       es especialmente fácil porque la API de GitHub usa el MISMO código
#       HTTP (404) para dos preguntas distintas según el endpoint que se
#       consulte:
#         · 404 en /branches/<rama>            → la rama NO EXISTE. No sé
#           responder nada sobre su protección: exit 2 ("no sé").
#         · 404 en /branches/<rama>/protection  → la rama SÍ EXISTE pero NO
#           tiene protección configurada. Esa es una respuesta VÁLIDA y
#           ACCIONABLE: exit 1 ("está mal, así se arregla").
#       Por eso el guion consulta PRIMERO si la rama existe (sección 1) y
#       SOLO DESPUÉS pregunta por su protección (sección 2). Invertir el
#       orden, o tratar cualquier 404 como "no protegida", mezclaría "la
#       rama no existe" (avería del guion o typo en REPO/RAMA) con "la rama
#       existe pero el que la creó no le puso protección" (deriva real del
#       repo). Son preguntas distintas y merecen códigos distintos.
#
# ─── Por qué existe ──────────────────────────────────────────────────────────
# La branch protection de GitHub NO viaja con el código: vive solo en la
# configuración del repo en GitHub, no en ningún archivo versionado. Cuando
# este fork se replica para un cliente nuevo (nuevo repo, mismo código), la
# protección de la rama de despliegue no se copia sola — y el silencio es
# total: nada en el código avisa que falta. Este guion existe para que la
# réplica pueda AFIRMAR que el contrato de protección quedó bien puesto, en
# vez de heredar ese silencio y descubrirlo el día que alguien fuerza un
# push que debía estar bloqueado, o que un push legítimo se queda esperando
# un check que nunca corre.
#
# Es el hermano conceptual de `check-schema-fidelity.sh` y
# `check-migrations.sh`: misma pregunta de fondo (¿el estado externo sigue
# sincronizado con lo que el fork afirma?), mismo contrato de salida de tres
# códigos, mismo compromiso de no mutar nada. La diferencia es que aquí el
# "estado externo" no es un archivo ni una base de datos: es configuración
# que solo existe del lado de GitHub.
#
# ─── Convenciones ────────────────────────────────────────────────────────────
# · sh POSIX puro, sin bashismos, como los otros guiones de `scripts/`.
# · Todo lo humano sale por stdout, en un solo flujo, para que ningún
#   llamador pierda la mitad del mensaje por capturar solo una de las dos
#   salidas.
# · Sin `set -e` a propósito: aquí los códigos de salida distintos de cero
#   son el dato que venimos a leer, no una avería que deba abortar el guion.
# · Solo lecturas: cada llamada a `gh api` de este guion es un GET implícito
#   (sin `-X`). El guion JAMÁS ejecuta un `-X PUT`/`-X DELETE`/`-X POST`
#   contra la API — eso mutaría la protección real, que es exactamente lo
#   que este guion existe para verificar sin tocar.
#
# ─── Parametrización — para otro repo o rama ─────────────────────────────────
# Por defecto verifica la rama de despliegue de ESTE fork. Para verificar la
# réplica de un cliente, sin editar el guion:
#
#   REPO=cliente/su-saleor RAMA=stable/3.22 sh scripts/check-branch-protection.sh
#
# Motivo: al replicar el repo para un cliente, la branch protection NO viaja
# (ver "Por qué existe" arriba) — con este guion la réplica puede AFIRMAR que
# quedó bien puesta, en vez de asumirlo en silencio.

REPO="${REPO:-aclicona/licona-saleor}"
RAMA="${RAMA:-stable/3.22}"
ETIQUETA="[check-branch-protection]"

# El contexto esperado en `required_status_checks.contexts`. Esta cadena está
# ACOPLADA al `name:` del job `puerta` en `.github/workflows/ci-fork.yml`
# (hoy: "Puerta rapida"). Un rename inocente de ese job en el workflow deja
# la rama esperando PARA SIEMPRE un check que nunca vuelve a llegar —
# GitHub no fusiona status checks por heurística, compara el nombre literal.
# Por eso existe `saleor/tests/test_fork_branch_protection_drift.py`: ese
# test verifica que esta constante y el nombre del job en el workflow no se
# separen. Si cambias el job, cambia también esta línea en el mismo commit.
CONTEXTO_ESPERADO="Puerta rapida"

# ─── Cómo se arregla una deriva ──────────────────────────────────────────────
# Este guion NUNCA ejecuta el comando de abajo: solo lo imprime. Aplicar una
# protección es una decisión del humano (o de otro guion explícitamente
# mutador), no de un verificador de solo lectura.
consejo_arreglar() {
  echo "$ETIQUETA Para restaurar el contrato (esto el guion NO lo ejecuta, es solo el comando):"
  echo "$ETIQUETA   gh api -X PUT repos/$REPO/branches/$RAMA_ESC/protection --input - <<'JSON'"
  echo "$ETIQUETA   {\"required_status_checks\":{\"strict\":false,\"contexts\":[\"$CONTEXTO_ESPERADO\"]},"
  echo "$ETIQUETA    \"enforce_admins\":false,\"required_pull_request_reviews\":null,\"restrictions\":null,"
  echo "$ETIQUETA    \"allow_force_pushes\":true,\"allow_deletions\":false}"
  echo "$ETIQUETA   JSON"
}

# ─── 0. ¿Hay con qué preguntar? ──────────────────────────────────────────────
if ! command -v gh >/dev/null 2>&1; then
  echo "$ETIQUETA No se encontró el CLI 'gh' en el PATH."
  echo "$ETIQUETA Instálalo con: brew install gh"
  echo "$ETIQUETA No sé responder si la branch protection coincide con el contrato."
  exit 2
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "$ETIQUETA 'gh' no tiene una sesión autenticada."
  echo "$ETIQUETA Inicia sesión con: gh auth login"
  echo "$ETIQUETA No sé responder si la branch protection coincide con el contrato."
  exit 2
fi

TMP=$(mktemp -d) || {
  echo "$ETIQUETA No se pudo crear un directorio temporal. No sé responder."
  exit 2
}
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

# GitHub no acepta un '/' literal en la ruta de la API para el nombre de una
# rama (colisionaría con el separador de segmentos de la URL): hay que
# escaparlo como '%2F'. Ramas como "stable/3.22" son justo el caso que rompe
# sin esto. `sed` con IFS de barra doble ('|') como delimitador evita pelear
# con el propio '/' que se está sustituyendo.
RAMA_ESC=$(printf '%s' "$RAMA" | sed 's|/|%2F|g')

# ─── 1. ¿Existe la rama? ──────────────────────────────────────────────────────
# Se pregunta esto ANTES de la protección a propósito (ver el aviso de 404 en
# el contrato de salida, arriba): si la rama no existe, cualquier respuesta
# sobre su protección es basura, y el 404 de este endpoint significa
# exactamente eso — no existe — sin ambigüedad con "no protegida".
gh api "repos/$REPO/branches/$RAMA_ESC" --jq '.name' >"$TMP/rama.out" 2>"$TMP/rama.err"
CODIGO_RAMA=$?

if [ "$CODIGO_RAMA" -ne 0 ]; then
  if grep -qi 'HTTP 404' "$TMP/rama.err"; then
    echo "$ETIQUETA NO SE PUDO RESPONDER: el repo '$REPO' o la rama '$RAMA' no existen (HTTP 404)."
    echo "$ETIQUETA Revisa REPO/RAMA, o que la rama no se haya renombrado o borrado."
  elif grep -qi 'HTTP 403' "$TMP/rama.err"; then
    echo "$ETIQUETA NO SE PUDO RESPONDER: permisos insuficientes contra '$REPO' (HTTP 403)."
    echo "$ETIQUETA Revisa que la sesión de 'gh auth login' tenga acceso a este repo."
  else
    REVELADORA=$(tail -n 1 "$TMP/rama.err")
    echo "$ETIQUETA NO SE PUDO RESPONDER: 'gh api' falló consultando la rama (código $CODIGO_RAMA)."
    echo "$ETIQUETA Línea reveladora: ${REVELADORA:-(sin mensaje en stderr)}"
  fi
  echo "$ETIQUETA No sé si la branch protection coincide con el contrato: no pude confirmar que la rama exista."
  exit 2
fi

NOMBRE_RAMA=$(cat "$TMP/rama.out")
if [ -z "$NOMBRE_RAMA" ] || [ "$NOMBRE_RAMA" != "$RAMA" ]; then
  echo "$ETIQUETA NO SE PUDO RESPONDER: la respuesta de GitHub para la rama fue ilegible o inesperada."
  echo "$ETIQUETA Esperaba el nombre '$RAMA', obtuve: '${NOMBRE_RAMA:-(vacío)}'."
  exit 2
fi

# ─── 2. La protección — una sola llamada, cinco campos ──────────────────────
# Se usa el --jq EMBEBIDO de 'gh' (no un 'jq' externo instalado aparte: 'gh'
# ya lo trae vendorizado, así que no hace falta declarar esa dependencia).
#
# Se emite una línea por campo, en un orden fijo, y NO como '@tsv': con un
# solo registro tabulado, cualquier campo vacío o el literal 'null' colapsa
# el conteo de columnas al leerlo con IFS=tab, y un 'read' partido a mano se
# desincroniza en silencio. Leer con 'sed -n Np' sobre cinco líneas propias
# no tiene ese problema: cada campo vive en su propia línea, sin separador
# que se pueda perder.
gh api "repos/$REPO/branches/$RAMA_ESC/protection" \
  --jq '[ (.required_status_checks.contexts // [] | join(",")),
          (.required_status_checks.strict | tostring),
          (.enforce_admins.enabled | tostring),
          (.allow_force_pushes.enabled | tostring),
          (.allow_deletions.enabled | tostring) ] | .[]' \
  >"$TMP/prot.out" 2>"$TMP/prot.err"
CODIGO_PROT=$?

if [ "$CODIGO_PROT" -ne 0 ]; then
  if grep -qi 'HTTP 404' "$TMP/prot.err"; then
    # Aquí el 404 SÍ es una respuesta válida: ya confirmamos en la sección 1
    # que la rama existe, así que un 404 en /protection solo puede significar
    # que no hay protección configurada. Deriva real y accionable: exit 1.
    echo "$ETIQUETA DERIVA: la rama '$RAMA' existe pero NO tiene branch protection configurada."
    echo "$ETIQUETA Consecuencia: sin protección, cualquiera con push puede forzar cambios,"
    echo "$ETIQUETA borrar la rama de despliegue, o mergear sin que 'Puerta rapida' corra."
    consejo_arreglar
    exit 1
  elif grep -qi 'HTTP 403' "$TMP/prot.err"; then
    echo "$ETIQUETA NO SE PUDO RESPONDER: permisos insuficientes para leer la protección (HTTP 403)."
    echo "$ETIQUETA La branch protection requiere permisos de administración del repo para leerse."
    echo "$ETIQUETA Revisa que la sesión de 'gh auth login' tenga ese nivel de acceso."
    exit 2
  else
    REVELADORA=$(tail -n 1 "$TMP/prot.err")
    echo "$ETIQUETA NO SE PUDO RESPONDER: 'gh api' falló consultando la protección (código $CODIGO_PROT)."
    echo "$ETIQUETA Línea reveladora: ${REVELADORA:-(sin mensaje en stderr)}"
    exit 2
  fi
fi

CONTEXTS=$(sed -n '1p' "$TMP/prot.out")
STRICT=$(sed -n '2p' "$TMP/prot.out")
ENFORCE_ADMINS=$(sed -n '3p' "$TMP/prot.out")
ALLOW_FORCE_PUSHES=$(sed -n '4p' "$TMP/prot.out")
ALLOW_DELETIONS=$(sed -n '5p' "$TMP/prot.out")

# 'tostring' sobre un campo ausente en el JSON produce el literal 'null', que
# no es un booleano válido para el contrato: se traduce a algo legible para
# el humano y se trata como NO coincidente con nada esperado (ni true ni
# false), así que cualquier comparación de abajo lo marca como deriva.
[ "$STRICT" = "null" ] && STRICT="(ausente)"
[ "$ENFORCE_ADMINS" = "null" ] && ENFORCE_ADMINS="(ausente)"
[ "$ALLOW_FORCE_PUSHES" = "null" ] && ALLOW_FORCE_PUSHES="(ausente)"
[ "$ALLOW_DELETIONS" = "null" ] && ALLOW_DELETIONS="(ausente)"

# ─── 3. Comparar contra el contrato — acumular TODAS las derivas ────────────
# No se corta en la primera diferencia: un llamador que solo se entera de un
# campo roto por corrida tarda cinco corridas en ver el cuadro completo. Se
# acumula todo en $DERIVAS y se decide el exit code al final.
DERIVAS=""

if [ "$CONTEXTS" != "$CONTEXTO_ESPERADO" ]; then
  DERIVAS="${DERIVAS}x"
  echo "$ETIQUETA DERIVA en required_status_checks.contexts:"
  echo "$ETIQUETA   esperado:  [\"$CONTEXTO_ESPERADO\"]"
  echo "$ETIQUETA   encontrado: [\"${CONTEXTS:-(vacío)}\"]"
  if [ -z "$CONTEXTS" ]; then
    echo "$ETIQUETA   Consecuencia: ningún check gatea el merge — cualquier PR se puede mergear sin CI."
  else
    echo "$ETIQUETA   Consecuencia: la rama espera un check ('$CONTEXTS') que nunca llega,"
    echo "$ETIQUETA   porque el job real se llama '$CONTEXTO_ESPERADO'. El merge queda bloqueado para siempre."
  fi
fi

if [ "$STRICT" != "false" ]; then
  DERIVAS="${DERIVAS}x"
  echo "$ETIQUETA DERIVA en required_status_checks.strict:"
  echo "$ETIQUETA   esperado: false · encontrado: $STRICT"
  echo "$ETIQUETA   Consecuencia: en true exige la rama al día con la base antes de mergear —"
  echo "$ETIQUETA   fricción que este fork no quiere en su flujo de despliegue."
fi

if [ "$ENFORCE_ADMINS" != "false" ]; then
  DERIVAS="${DERIVAS}x"
  echo "$ETIQUETA DERIVA en enforce_admins.enabled:"
  echo "$ETIQUETA   esperado: false · encontrado: $ENFORCE_ADMINS"
  echo "$ETIQUETA   Consecuencia GRAVE, no cosmética: en true, el push directo de despliegue"
  echo "$ETIQUETA   queda en DEADLOCK PERMANENTE — la vía real de despliegue de este fork es"
  echo "$ETIQUETA   push directo a '$RAMA' sin PR, y ese push lo hace un admin."
fi

if [ "$ALLOW_FORCE_PUSHES" != "true" ]; then
  DERIVAS="${DERIVAS}x"
  echo "$ETIQUETA DERIVA en allow_force_pushes.enabled:"
  echo "$ETIQUETA   esperado: true · encontrado: $ALLOW_FORCE_PUSHES"
  echo "$ETIQUETA   Consecuencia: en false bloquea también a los admins y ROMPE el rollback"
  echo "$ETIQUETA   con 'git push --force-with-lease'."
fi

if [ "$ALLOW_DELETIONS" != "false" ]; then
  DERIVAS="${DERIVAS}x"
  echo "$ETIQUETA DERIVA en allow_deletions.enabled:"
  echo "$ETIQUETA   esperado: false · encontrado: $ALLOW_DELETIONS"
  echo "$ETIQUETA   Consecuencia: en true cualquiera con permiso de push puede borrar la rama de despliegue."
fi

if [ -n "$DERIVAS" ]; then
  echo "$ETIQUETA La branch protection de '$RAMA' en '$REPO' NO coincide con el contrato esperado."
  consejo_arreglar
  exit 1
fi

echo "$ETIQUETA La branch protection de '$RAMA' en '$REPO' coincide con el contrato esperado:"
echo "$ETIQUETA   contexts=[\"$CONTEXTO_ESPERADO\"] strict=false enforce_admins=false"
echo "$ETIQUETA   allow_force_pushes=true allow_deletions=false"
exit 0
