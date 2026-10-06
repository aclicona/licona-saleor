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
#       no hay sesión autenticada, el repo o la rama no existen, el token no
#       tiene permiso de admin para leer la protección, o la respuesta de la
#       API es ilegible o incompleta.
#
#       OJO: 2 significa "no sé", NO significa "está mal". Y aquí conflarlos
#       es especialmente fácil porque la API de GitHub usa el MISMO código
#       HTTP (404) para TRES preguntas distintas:
#         · 404 en /branches/<rama>              → la rama NO EXISTE. No sé
#           responder nada sobre su protección: exit 2 ("no sé").
#         · 404 en /branches/<rama>/protection, con la rama sin proteger →
#           la rama existe y de verdad NO tiene protección. Respuesta VÁLIDA
#           y ACCIONABLE: exit 1 ("está mal, así se arregla").
#         · 404 en /branches/<rama>/protection, con la rama PROTEGIDA → el
#           token no es admin del repo. GitHub responde 404, NO 403, cuando
#           quien pregunta no tiene permiso para leer la protección: oculta
#           la existencia del recurso en vez de admitirla. Eso es "no sé":
#           exit 2.
#
#       Las dos últimas son indistinguibles por el código HTTP, y confundirlas
#       es el peor fallo posible de este guion: reportar como DESPROTEGIDA una
#       rama que SÍ está protegida, e imprimir un `PUT` de remedio que la
#       dejaría peor de lo que estaba. El desempate es el campo `.protected`
#       de /branches/<rama>, que GitHub sí devuelve SIN exigir admin (medido el
#       2026-09-25 contra saleor/saleor: `.protected=true` legible, /protection
#       en 404). Por eso el guion consulta PRIMERO la rama —de ahí saca su
#       existencia Y su `.protected`— y SOLO DESPUÉS su protección.
#
#       Este caso no es exótico: es el caso NORMAL en los dos usos que este
#       guion publicita. Quien replica el fork para un cliente rara vez es
#       admin del repo del cliente, y el `GITHUB_TOKEN` por defecto de un
#       workflow no lee branch protection sin `permissions: administration:
#       read`.
#
# ─── Alcance: qué verifica y qué NO ──────────────────────────────────────────
# El contrato cubre TODO campo de la protección que puede bloquear (o abrir de
# más) el push directo de despliegue a la rama —la vía real de este fork: push
# directo sin PR—. Son once comprobaciones:
#   required_status_checks.contexts      == ["Puerta rapida"]
#   required_status_checks.strict        == false
#   enforce_admins.enabled               == false
#   allow_force_pushes.enabled           == true
#   allow_deletions.enabled              == false
#   lock_branch.enabled                  == false  (true = rama de solo lectura)
#   block_creations.enabled              == false
#   required_linear_history.enabled      == false
#   required_signatures.enabled          == false
#   required_pull_request_reviews        AUSENTE   (si existe, exige PR)
#   restrictions                         AUSENTE   (si existe, limita quién empuja)
#
# Por qué entran linear_history y signatures (medido el 2026-10-03 sobre
# origin/stable/3.23): la historia de la rama CONTIENE merge commits propios del
# fork (p. ej. `chore(3.23): merge del tag upstream`, df2d84f) y NINGÚN commit
# lleva firma verificada (`git log --format=%G?` da N en todos). Con
# required_linear_history o required_signatures en true, el siguiente merge de
# tag upstream o el push de un commit del worker queda rechazado.
#
# `required_pull_request_reviews` y `restrictions`: la API OMITE la clave
# cuando no están configuradas. Su ausencia es el estado legítimo (por eso no
# cuentan como "respuesta truncada"); su presencia es deriva. De `restrictions`
# NO se validan las listas de actores (users/teams/apps): se afirma "sin
# restricciones" en vez de intentar decidir si el desplegador está en la lista.
#
# FUERA del contrato, a propósito:
#   · allow_fork_syncing — solo afecta a la sincronización de forks que cuelgan
#     de este repo; no toca el push de despliegue.
#   · required_conversation_resolution — solo aplica a pull requests, y esta
#     rama no se despliega por PR.
#   · url — metadato de la API, no es configuración.
# Además de los once puntos de la protección clásica, se consultan los
# repository RULESETS vigentes sobre la rama (`GET /repos/<repo>/rules/branches/<rama>`,
# B-769): un ruleset con una regla de tipo `pull_request`, `non_fast_forward`,
# `required_linear_history`, `required_signatures` o `update` bloquea el push
# directo de despliegue igual que la protección clásica, y la API clásica no lo
# ve. Cualquiera de esas cinco aplicable a la rama es deriva (exit 1). Si la API
# de rulesets no responde, "no sé" (exit 2). Las demás reglas de ruleset
# (deletion, creation, required_status_checks, etc.) quedan fuera del contrato.
# Un exit 0 significa "estos once puntos coinciden y ningún ruleset bloquea el
# push", NO "no existe ningún otro mecanismo que bloquee el despliegue".
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
# · Antes de comparar nada, se valida que la respuesta TENGA FORMA de
#   respuesta (número de líneas y campos no vacíos). Sin esa guarda, una
#   avería del entorno se disfraza de deriva: es exactamente el mismo
#   principio que `check-schema-fidelity.sh` aplica al exigir "salida no
#   vacía Y que parezca un esquema" ANTES de mirar el diff.
# · Solo lecturas: cada llamada a `gh api` de este guion es un GET implícito
#   (sin `-X`). El guion JAMÁS ejecuta un `-X PUT`/`-X DELETE`/`-X POST`
#   contra la API — eso mutaría la protección real, que es exactamente lo
#   que este guion existe para verificar sin tocar.
#
# ─── Parametrización — para otro repo o rama ─────────────────────────────────
# Por defecto verifica la rama de despliegue de ESTE fork. Para verificar la
# réplica de un cliente, sin editar el guion:
#
#   REPO=cliente/su-saleor RAMA=stable/3.23 sh scripts/check-branch-protection.sh
#
# Motivo: al replicar el repo para un cliente, la branch protection NO viaja
# (ver "Por qué existe" arriba) — con este guion la réplica puede AFIRMAR que
# quedó bien puesta, en vez de asumirlo en silencio.

ETIQUETA="[check-branch-protection]"

# `${VAR:-default}` cae al default TAMBIÉN cuando la variable está definida
# pero VACÍA. Eso convertiría `REPO='' sh scripts/check-branch-protection.sh`
# en un veredicto verde sobre el repo EQUIVOCADO —el default de este fork—
# mientras el llamador cree estar preguntando por otro sitio. Es la peor clase
# de respuesta: correcta sobre una pregunta que nadie hizo. `${VAR+definida}`
# distingue "sin definir" (usa el default: el uso normal) de "definida y
# vacía" (un error del llamador, que hay que decir en voz alta).
if [ -n "${REPO+definida}" ] && [ -z "$REPO" ]; then
  echo "$ETIQUETA REPO está definida pero VACÍA."
  echo "$ETIQUETA Dale un valor ('owner/repo') o no la definas para usar el default de este fork."
  echo "$ETIQUETA No sé responder: no voy a dar un veredicto sobre un repo que no pediste."
  exit 2
fi

if [ -n "${RAMA+definida}" ] && [ -z "$RAMA" ]; then
  echo "$ETIQUETA RAMA está definida pero VACÍA."
  echo "$ETIQUETA Dale un valor o no la definas para usar el default de este fork."
  echo "$ETIQUETA No sé responder: no voy a dar un veredicto sobre una rama que no pediste."
  exit 2
fi

REPO="${REPO:-aclicona/licona-saleor}"
RAMA="${RAMA:-stable/3.23}"

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
#
# El bloque del comando se imprime SIN el prefijo de $ETIQUETA a propósito. Con
# el prefijo, la línea terminadora del heredoc sale como "[check-branch-...]
# JSON" — que no es `JSON`, así que el heredoc NO CIERRA NUNCA y la terminal de
# quien lo copió se queda colgada esperando. Un remedio que no se puede pegar
# no es un remedio.
consejo_arreglar() {
  echo "$ETIQUETA Para restaurar el contrato (esto el guion NO lo ejecuta, es solo el comando)."
  echo "$ETIQUETA AVISO antes de pegarlo: 'PUT /protection' REEMPLAZA el objeto entero, no"
  echo "$ETIQUETA fusiona campos. Borraría en silencio cualquier ajuste que este repo tuviera"
  echo "$ETIQUETA puesto a propósito y que no aparezca abajo (required_conversation_resolution,"
  echo "$ETIQUETA allow_fork_syncing...). Mira qué hay antes de escribir. Ojo: el PUT no puede"
  echo "$ETIQUETA expresar required_signatures: si esa deriva aparece, se quita con"
  echo "$ETIQUETA 'gh api -X DELETE repos/$REPO/branches/$RAMA_ESC/protection/required_signatures'."
  echo ""
  echo "gh api -X PUT repos/$REPO/branches/$RAMA_ESC/protection --input - <<'JSON'"
  echo "{\"required_status_checks\":{\"strict\":false,\"contexts\":[\"$CONTEXTO_ESPERADO\"]},"
  echo " \"enforce_admins\":false,\"required_pull_request_reviews\":null,\"restrictions\":null,"
  echo " \"required_linear_history\":false,\"allow_force_pushes\":true,\"allow_deletions\":false,"
  echo " \"block_creations\":false,\"lock_branch\":false}"
  echo "JSON"
  echo ""
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

# ─── 1. ¿Existe la rama, y GitHub la da por protegida? ──────────────────────
# Se pregunta esto ANTES de la protección a propósito (ver el aviso del 404 en
# el contrato de salida, arriba). De esta única llamada salen los DOS datos que
# hacen falta después:
#   · `.name`      → la rama existe. Un 404 AQUÍ significa "no existe", sin
#     ninguna ambigüedad con "no protegida": si la rama no está, cualquier
#     respuesta sobre su protección es basura.
#   · `.protected` → el desempate del 404 AMBIGUO de /protection. MEDIDO el
#     2026-09-25: GitHub devuelve este campo sin exigir permisos de admin,
#     justo al revés que el endpoint /protection. Sin él, un token sin admin
#     ve un 404 en /protection y el guion afirmaría que una rama protegida
#     está desprotegida — la inversión exacta que existe para impedir.
gh api "repos/$REPO/branches/$RAMA_ESC" \
  --jq '[ .name, (.protected | tostring) ] | .[]' \
  >"$TMP/rama.out" 2>"$TMP/rama.err"
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

# Se cuentan las líneas con `awk 'END {print NR+0}'` y no con `wc -l`: `wc -l`
# cuenta SALTOS de línea, así que una salida truncada sin salto final se
# contaría de menos. `NR` de awk cuenta también la última línea incompleta.
LINEAS_RAMA=$(awk 'END {print NR+0}' "$TMP/rama.out")
NOMBRE_RAMA=$(sed -n '1p' "$TMP/rama.out")
PROTEGIDA=$(sed -n '2p' "$TMP/rama.out")

if [ "$LINEAS_RAMA" -ne 2 ] || [ "$NOMBRE_RAMA" != "$RAMA" ]; then
  echo "$ETIQUETA NO SE PUDO RESPONDER: la respuesta de GitHub para la rama fue ilegible o inesperada."
  echo "$ETIQUETA Esperaba 2 líneas —el nombre '$RAMA' y su '.protected'—; obtuve $LINEAS_RAMA línea(s)"
  echo "$ETIQUETA con nombre '${NOMBRE_RAMA:-(vacío)}'."
  exit 2
fi

# `.protected` no es opcional para este guion: es el ÚNICO dato que distingue
# "la rama no está protegida" (deriva real) de "no tengo permiso para leer su
# protección" (no sé). Sin un booleano legible aquí, no hay veredicto posible
# más abajo, así que se para ahora en vez de adivinar.
if [ "$PROTEGIDA" != "true" ] && [ "$PROTEGIDA" != "false" ]; then
  echo "$ETIQUETA NO SE PUDO RESPONDER: GitHub no devolvió un '.protected' booleano para la rama"
  echo "$ETIQUETA '$RAMA' (obtuve '${PROTEGIDA:-(vacío)}'). Sin ese campo no puedo distinguir 'la rama"
  echo "$ETIQUETA NO está protegida' de 'no tengo permiso para leer su protección', y confundir esas"
  echo "$ETIQUETA dos cosas es exactamente el fallo que este guion no puede permitirse."
  exit 2
fi

# ─── 2. La protección — una sola llamada, once campos ──────────────────────
# Se usa el --jq EMBEBIDO de 'gh' (no un 'jq' externo instalado aparte: 'gh'
# ya lo trae vendorizado, así que no hace falta declarar esa dependencia).
#
# Se emite una línea por campo, en un orden fijo, y NO como '@tsv': con un
# solo registro tabulado, cualquier campo vacío o el literal 'null' colapsa
# el conteo de columnas al leerlo con IFS=tab, y un 'read' partido a mano se
# desincroniza en silencio. Una línea por campo evita ESE modo de fallo, pero
# NO evita que la respuesta entera venga vacía o truncada: 'sed -n Np' sobre
# una línea que no existe devuelve la cadena vacía sin protestar. Por eso la
# sección 2.b cuenta las líneas ANTES de comparar nada (ver ahí el detalle).
gh api "repos/$REPO/branches/$RAMA_ESC/protection" \
  --jq '[ (.required_status_checks.contexts // [] | join(",")),
          (.required_status_checks.strict | tostring),
          (.enforce_admins.enabled | tostring),
          (.allow_force_pushes.enabled | tostring),
          (.allow_deletions.enabled | tostring),
          (.lock_branch.enabled | tostring),
          (.block_creations.enabled | tostring),
          (.required_linear_history.enabled | tostring),
          (.required_signatures.enabled | tostring),
          (if .required_pull_request_reviews != null then "presente" else "ausente" end),
          (if .restrictions != null then "presente" else "ausente" end) ] | .[]' \
  >"$TMP/prot.out" 2>"$TMP/prot.err"
CODIGO_PROT=$?

if [ "$CODIGO_PROT" -ne 0 ]; then
  if grep -qi 'HTTP 404' "$TMP/prot.err"; then
    # Un 404 AQUÍ sigue siendo ambiguo aunque la sección 1 ya haya confirmado
    # que la rama existe: GitHub responde 404 —no 403— tanto cuando no hay
    # protección como cuando el token no tiene permiso de admin para leerla.
    # El desempate es `.protected`, que la sección 1 ya trajo y validó.
    if [ "$PROTEGIDA" = "false" ]; then
      echo "$ETIQUETA DERIVA: la rama '$RAMA' existe pero NO tiene branch protection configurada."
      echo "$ETIQUETA GitHub lo confirma por dos vías independientes: 404 en /protection y"
      echo "$ETIQUETA '.protected=false' en la propia rama. No es un problema de permisos."
      echo "$ETIQUETA Consecuencia: sin protección, cualquiera con push puede forzar cambios,"
      echo "$ETIQUETA borrar la rama de despliegue, o mergear sin que '$CONTEXTO_ESPERADO' corra."
      consejo_arreglar
      exit 1
    elif [ "$PROTEGIDA" = "true" ]; then
      echo "$ETIQUETA NO SE PUDO RESPONDER: la rama '$RAMA' de '$REPO' SÍ ESTÁ PROTEGIDA"
      echo "$ETIQUETA ('.protected=true'), pero este token NO TIENE PERMISO DE ADMIN para leer los"
      echo "$ETIQUETA detalles de esa protección. GitHub responde 404 —no 403— al endpoint"
      echo "$ETIQUETA /protection cuando quien pregunta no es admin: oculta el recurso en vez de"
      echo "$ETIQUETA admitir que existe."
      echo "$ETIQUETA Cómo se arregla: pregunta con un token que tenga 'admin' sobre '$REPO'"
      echo "$ETIQUETA (revisa 'gh auth status' y quién es dueño del repo); si esto corre en un"
      echo "$ETIQUETA workflow, el job necesita 'permissions: administration: read'."
      echo "$ETIQUETA NO se imprime el comando de remedio A PROPÓSITO: la rama SÍ está protegida, y"
      echo "$ETIQUETA un 'PUT /protection' a ciegas REEMPLAZARÍA la protección real por esta"
      echo "$ETIQUETA plantilla, borrando lo que hubiera. Aquí no falta protección: falta permiso."
      exit 2
    else
      # Inalcanzable mientras la sección 1 valide `.protected` como booleano.
      # Se deja escrito para que un refactor que se salte esa validación falle
      # diciendo "no sé" en vez de volver a inventarse una deriva.
      echo "$ETIQUETA NO SE PUDO RESPONDER: 404 en /protection y '.protected' ilegible"
      echo "$ETIQUETA ('${PROTEGIDA:-(vacío)}'). No sé distinguir 'no está protegida' de 'no tengo"
      echo "$ETIQUETA permiso para leer su protección'."
      exit 2
    fi
  elif grep -qi 'HTTP 403' "$TMP/prot.err"; then
    # Se conserva por si acaso, pero el 403 NO es el mecanismo habitual: lo que
    # GitHub devuelve de verdad ante un token sin admin es el 404 de arriba.
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

# ─── 2.b ¿La respuesta tiene forma de respuesta? ────────────────────────────
# Esta guarda es hermana de la de `check-schema-fidelity.sh` ("salida no vacía
# Y que parezca un esquema ANTES de mirar el diff") y existe por el mismo
# motivo: sin ella, una avería se disfraza de deriva catastrófica.
# MEDIDO con un `gh` falso: una salida VACÍA con exit 0 producía CINCO derivas
# fabricadas —incluido el bloque de "DEADLOCK PERMANENTE"— y el comando de
# remedio, sobre una rama que nunca llegó a inspeccionarse. Y una salida
# truncada a tres líneas se desincronizaba en silencio: daba por buenos los
# tres primeros campos y reportaba deriva en los dos que faltaban.
# La regla es la de siempre: si no pude leer la respuesta, es 2, nunca 1.
LINEAS_PROT=$(awk 'END {print NR+0}' "$TMP/prot.out")
if [ "$LINEAS_PROT" -ne 11 ]; then
  echo "$ETIQUETA NO SE PUDO RESPONDER: 'gh api' salió con código 0 pero su respuesta no tiene"
  echo "$ETIQUETA la forma esperada: esperaba 11 líneas (una por campo), obtuve $LINEAS_PROT."
  REVELADORA=$(tail -n 1 "$TMP/prot.err")
  echo "$ETIQUETA Línea reveladora: ${REVELADORA:-(sin mensaje en stderr)}"
  echo "$ETIQUETA Esto NO dice que la protección esté mal: dice que no pude leerla. No apliques"
  echo "$ETIQUETA ningún remedio a partir de esto."
  exit 2
fi

CONTEXTS=$(sed -n '1p' "$TMP/prot.out")
STRICT=$(sed -n '2p' "$TMP/prot.out")
ENFORCE_ADMINS=$(sed -n '3p' "$TMP/prot.out")
ALLOW_FORCE_PUSHES=$(sed -n '4p' "$TMP/prot.out")
ALLOW_DELETIONS=$(sed -n '5p' "$TMP/prot.out")
LOCK_BRANCH=$(sed -n '6p' "$TMP/prot.out")
BLOCK_CREATIONS=$(sed -n '7p' "$TMP/prot.out")
LINEAR_HISTORY=$(sed -n '8p' "$TMP/prot.out")
SIGNATURES=$(sed -n '9p' "$TMP/prot.out")
PR_REVIEWS=$(sed -n '10p' "$TMP/prot.out")
RESTRICCIONES=$(sed -n '11p' "$TMP/prot.out")

# Los cuatro booleanos NUNCA pueden salir vacíos de un JSON bien formado:
# `tostring` siempre produce texto ('true', 'false' o el literal 'null'). Si
# alguno viene vacío, la respuesta está corrupta o desalineada — otra vez "no
# sé", nunca "está mal".
# `contexts` NO entra en esta guarda: SÍ puede estar legítimamente vacío
# (`[] | join(",")` da ""), y eso significa "ningún check gatea el merge", que
# es una deriva REAL y se reporta más abajo como exit 1. Meterlo aquí
# convertiría esa deriva de verdad en un "no sé".
# `PR_REVIEWS` y `RESTRICCIONES` salen de un `if` del jq: siempre son
# "presente" o "ausente", nunca vacíos ni 'null'. Su AUSENCIA es el estado
# legítimo (la API omite la clave), así que NO cuentan para la guarda de
# truncado de abajo; sí se exige que sean una de las dos palabras.
if [ -z "$STRICT" ] || [ -z "$ENFORCE_ADMINS" ] || [ -z "$ALLOW_FORCE_PUSHES" ] || [ -z "$ALLOW_DELETIONS" ] \
  || [ -z "$LOCK_BRANCH" ] || [ -z "$BLOCK_CREATIONS" ] || [ -z "$LINEAR_HISTORY" ] || [ -z "$SIGNATURES" ] \
  || { [ "$PR_REVIEWS" != "presente" ] && [ "$PR_REVIEWS" != "ausente" ]; } \
  || { [ "$RESTRICCIONES" != "presente" ] && [ "$RESTRICCIONES" != "ausente" ]; }; then
  echo "$ETIQUETA NO SE PUDO RESPONDER: la respuesta trajo 11 líneas pero algún campo vino"
  echo "$ETIQUETA vacío o ilegible (strict='$STRICT' enforce_admins='$ENFORCE_ADMINS'"
  echo "$ETIQUETA allow_force_pushes='$ALLOW_FORCE_PUSHES' allow_deletions='$ALLOW_DELETIONS'"
  echo "$ETIQUETA lock_branch='$LOCK_BRANCH' block_creations='$BLOCK_CREATIONS'"
  echo "$ETIQUETA linear_history='$LINEAR_HISTORY' signatures='$SIGNATURES'"
  echo "$ETIQUETA pr_reviews='$PR_REVIEWS' restrictions='$RESTRICCIONES')."
  echo "$ETIQUETA Comparar contra eso inventaría derivas. No apliques ningún remedio a partir de esto."
  exit 2
fi

# Un cuerpo `{}` (o sin NINGUNO de los campos booleanos) también es "respuesta
# truncada", no una cascada de derivas: una protección real siempre trae al
# menos `enforce_admins`, `allow_force_pushes` y `allow_deletions`. A diferencia
# de `required_pull_request_reviews`/`restrictions` (cuya ausencia es legítima),
# la ausencia de TODOS los obligatorios solo puede ser avería.
if [ "$ENFORCE_ADMINS$ALLOW_FORCE_PUSHES$ALLOW_DELETIONS$LOCK_BRANCH$BLOCK_CREATIONS$LINEAR_HISTORY$SIGNATURES" = "nullnullnullnullnullnullnull" ]; then
  echo "$ETIQUETA NO SE PUDO RESPONDER: la respuesta de /protection no trae NINGUNO de los campos"
  echo "$ETIQUETA obligatorios (enforce_admins, allow_force_pushes, allow_deletions, lock_branch...)."
  echo "$ETIQUETA Esto NO dice que la protección esté mal: dice que no pude leerla. No apliques"
  echo "$ETIQUETA ningún remedio a partir de esto."
  exit 2
fi

# ─── 2.c Repository rulesets aplicables a la rama (B-769) ───────────────────
# Endpoint de solo lectura: devuelve las reglas EFECTIVAS sobre la rama, de
# todos los rulesets activos que la apuntan (no requiere admin). Se listan solo
# las cinco que bloquean el push directo de despliegue. Una línea por regla:
# "<tipo> (ruleset <id>)". Cero líneas = ningún ruleset bloquea. Si la llamada
# falla es "no sé" (2), nunca "sin reglas": se decide al final para que una
# deriva de la protección clásica (1) no quede tapada por un fallo de esta.
RULESETS_ILEGIBLE=""
gh api "repos/$REPO/rules/branches/$RAMA_ESC" \
  --jq '.[] | select(.type | IN("pull_request","non_fast_forward","required_linear_history","required_signatures","update")) | "\(.type) (ruleset \(.ruleset_id))"' \
  >"$TMP/rules.out" 2>"$TMP/rules.err"
CODIGO_RULES=$?
if [ "$CODIGO_RULES" -ne 0 ]; then
  RULESETS_ILEGIBLE=$(tail -n 1 "$TMP/rules.err")
  RULESETS_ILEGIBLE="${RULESETS_ILEGIBLE:-(sin mensaje en stderr)}"
fi

# 'tostring' sobre un campo ausente en el JSON produce el literal 'null', que
# no es un booleano válido para el contrato: se traduce a algo legible para
# el humano y se trata como NO coincidente con nada esperado (ni true ni
# false), así que cualquier comparación de abajo lo marca como deriva.
[ "$STRICT" = "null" ] && STRICT="(ausente)"
[ "$ENFORCE_ADMINS" = "null" ] && ENFORCE_ADMINS="(ausente)"
[ "$ALLOW_FORCE_PUSHES" = "null" ] && ALLOW_FORCE_PUSHES="(ausente)"
[ "$ALLOW_DELETIONS" = "null" ] && ALLOW_DELETIONS="(ausente)"
[ "$LOCK_BRANCH" = "null" ] && LOCK_BRANCH="(ausente)"
[ "$BLOCK_CREATIONS" = "null" ] && BLOCK_CREATIONS="(ausente)"
[ "$LINEAR_HISTORY" = "null" ] && LINEAR_HISTORY="(ausente)"
[ "$SIGNATURES" = "null" ] && SIGNATURES="(ausente)"

# ─── 3. Comparar contra el contrato — acumular TODAS las derivas ────────────
# No se corta en la primera diferencia: un llamador que solo se entera de un
# campo roto por corrida tarda cinco corridas en ver el cuadro completo. Se
# acumula todo en $DERIVAS y se decide el exit code al final.
DERIVAS=""

# `contexts` es una LISTA, no un escalar: que no coincida con lo esperado tiene
# dos causas muy distintas y una consecuencia distinta cada una. Decir "la rama
# espera un check que nunca llega" cuando el check esperado SÍ está en la lista
# es sencillamente falso, y manda a quien lo lea a buscar donde no es. Se
# recorre la lista para saber cuál de los dos casos es.
# `set -f` apaga el globbing antes del `for`: sin él, un contexto que
# contuviera '*' o '?' se expandiría contra los archivos del directorio actual.
ESPERADO_PRESENTE=0
SOBRANTES=""
IFS_ORIGINAL=$IFS
set -f
IFS=','
for CTX in $CONTEXTS; do
  if [ "$CTX" = "$CONTEXTO_ESPERADO" ]; then
    ESPERADO_PRESENTE=1
  else
    SOBRANTES="${SOBRANTES:+$SOBRANTES, }'$CTX'"
  fi
done
set +f
IFS=$IFS_ORIGINAL

if [ "$CONTEXTS" != "$CONTEXTO_ESPERADO" ]; then
  DERIVAS="${DERIVAS}x"
  echo "$ETIQUETA DERIVA en required_status_checks.contexts:"
  echo "$ETIQUETA   esperado:  [\"$CONTEXTO_ESPERADO\"]"
  echo "$ETIQUETA   encontrado: [\"${CONTEXTS:-(vacío)}\"]"
  if [ -z "$CONTEXTS" ]; then
    echo "$ETIQUETA   Consecuencia: ningún check gatea el merge — cualquier PR se puede mergear sin CI."
  elif [ "$ESPERADO_PRESENTE" -eq 0 ]; then
    echo "$ETIQUETA   Falta el esperado: '$CONTEXTO_ESPERADO' NO está entre los checks requeridos."
    echo "$ETIQUETA   Consecuencia: la rama espera checks que este fork no reporta con ese nombre,"
    echo "$ETIQUETA   así que el merge queda bloqueado para siempre."
  else
    echo "$ETIQUETA   Matiz: '$CONTEXTO_ESPERADO' SÍ está entre los checks requeridos. Lo que no"
    echo "$ETIQUETA   esperaba son los contextos de más: $SOBRANTES."
    echo "$ETIQUETA   Consecuencia: el merge queda bloqueado hasta que TAMBIÉN esos reporten. Si"
    echo "$ETIQUETA   alguno corresponde a un job que ya no existe o que cambió de nombre, ese"
    echo "$ETIQUETA   bloqueo es permanente."
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

if [ "$LOCK_BRANCH" != "false" ]; then
  DERIVAS="${DERIVAS}x"
  echo "$ETIQUETA DERIVA en lock_branch.enabled:"
  echo "$ETIQUETA   esperado: false · encontrado: $LOCK_BRANCH"
  echo "$ETIQUETA   Consecuencia GRAVE: en true la rama es de SOLO LECTURA — ningún push, ni"
  echo "$ETIQUETA   el de despliegue, entra."
fi

if [ "$BLOCK_CREATIONS" != "false" ]; then
  DERIVAS="${DERIVAS}x"
  echo "$ETIQUETA DERIVA en block_creations.enabled:"
  echo "$ETIQUETA   esperado: false · encontrado: $BLOCK_CREATIONS"
  echo "$ETIQUETA   Consecuencia: en true se bloquea crear refs que casen con la protección; el"
  echo "$ETIQUETA   push que (re)crea la rama de despliegue fallaría."
fi

if [ "$LINEAR_HISTORY" != "false" ]; then
  DERIVAS="${DERIVAS}x"
  echo "$ETIQUETA DERIVA en required_linear_history.enabled:"
  echo "$ETIQUETA   esperado: false · encontrado: $LINEAR_HISTORY"
  echo "$ETIQUETA   Consecuencia: en true se rechazan los merge commits, y el flujo de sync de"
  echo "$ETIQUETA   este fork los usa ('chore(3.23): merge del tag upstream')."
fi

if [ "$SIGNATURES" != "false" ]; then
  DERIVAS="${DERIVAS}x"
  echo "$ETIQUETA DERIVA en required_signatures.enabled:"
  echo "$ETIQUETA   esperado: false · encontrado: $SIGNATURES"
  echo "$ETIQUETA   Consecuencia: en true se rechaza todo commit sin firma verificada; los del"
  echo "$ETIQUETA   worker y los de sync no la llevan."
fi

if [ "$PR_REVIEWS" != "ausente" ]; then
  DERIVAS="${DERIVAS}x"
  echo "$ETIQUETA DERIVA en required_pull_request_reviews:"
  echo "$ETIQUETA   esperado: ausente · encontrado: $PR_REVIEWS"
  echo "$ETIQUETA   Consecuencia GRAVE: exige PR para entrar a '$RAMA'; el push directo de"
  echo "$ETIQUETA   despliegue (sin PR) queda rechazado."
fi

if [ "$RESTRICCIONES" != "ausente" ]; then
  DERIVAS="${DERIVAS}x"
  echo "$ETIQUETA DERIVA en restrictions:"
  echo "$ETIQUETA   esperado: ausente (sin restricciones) · encontrado: $RESTRICCIONES"
  echo "$ETIQUETA   Consecuencia: limita QUIÉN puede empujar a '$RAMA'. No se validan las listas de"
  echo "$ETIQUETA   actores: el contrato afirma 'sin restricciones'. Si es deliberado y el"
  echo "$ETIQUETA   desplegador está en la lista, el contrato debe cambiarse a propósito."
fi

if [ -z "$RULESETS_ILEGIBLE" ] && [ -s "$TMP/rules.out" ]; then
  DERIVAS="${DERIVAS}x"
  echo "$ETIQUETA DERIVA en repository rulesets: hay reglas que bloquean el push directo a '$RAMA':"
  while IFS= read -r REGLA; do
    echo "$ETIQUETA   · $REGLA"
  done <"$TMP/rules.out"
  echo "$ETIQUETA   Consecuencia GRAVE: un ruleset con pull_request, non_fast_forward,"
  echo "$ETIQUETA   required_linear_history, required_signatures o update rechaza el push de"
  echo "$ETIQUETA   despliegue (sin PR, con merge commits, sin firma o con force-push de rollback)."
  echo "$ETIQUETA   Se corrige en Settings > Rules > Rulesets del repo (no con el PUT de abajo):"
  echo "$ETIQUETA   quita la regla o añade al desplegador como 'bypass actor'."
fi

if [ -n "$DERIVAS" ]; then
  echo "$ETIQUETA La branch protection de '$RAMA' en '$REPO' NO coincide con lo esperado en al"
  echo "$ETIQUETA menos uno de los once puntos que este guion verifica."
  consejo_arreglar
  exit 1
fi

if [ -n "$RULESETS_ILEGIBLE" ]; then
  echo "$ETIQUETA NO SE PUDO RESPONDER: la protección clásica coincide, pero 'gh api' falló"
  echo "$ETIQUETA consultando los rulesets de '$RAMA' (código $CODIGO_RULES)."
  echo "$ETIQUETA Línea reveladora: $RULESETS_ILEGIBLE"
  echo "$ETIQUETA No sé si un ruleset bloquea el push de despliegue: no doy un verde a medias."
  exit 2
fi

# El verde dice EXACTAMENTE qué comprobó, y dice también qué no.
echo "$ETIQUETA Los ONCE puntos que este guion verifica coinciden con lo esperado en la rama"
echo "$ETIQUETA '$RAMA' de '$REPO':"
echo "$ETIQUETA   required_status_checks.contexts = [\"$CONTEXTO_ESPERADO\"]"
echo "$ETIQUETA   required_status_checks.strict   = false"
echo "$ETIQUETA   enforce_admins.enabled          = false"
echo "$ETIQUETA   allow_force_pushes.enabled      = true"
echo "$ETIQUETA   allow_deletions.enabled         = false"
echo "$ETIQUETA   lock_branch.enabled             = false"
echo "$ETIQUETA   block_creations.enabled         = false"
echo "$ETIQUETA   required_linear_history.enabled = false"
echo "$ETIQUETA   required_signatures.enabled     = false"
echo "$ETIQUETA   required_pull_request_reviews   = ausente"
echo "$ETIQUETA   restrictions                    = ausente (no se validan listas de actores)"
echo "$ETIQUETA Ningún repository ruleset aplicable a la rama trae pull_request, non_fast_forward,"
echo "$ETIQUETA required_linear_history, required_signatures ni update."
echo "$ETIQUETA ALCANCE: fuera del contrato quedan allow_fork_syncing, required_conversation_resolution"
echo "$ETIQUETA (solo PRs) y las demás reglas de ruleset (deletion, creation, status checks...)."
exit 0
