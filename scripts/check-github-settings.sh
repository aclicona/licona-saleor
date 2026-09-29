#!/bin/sh
# check-github-settings.sh — ¿los ajustes de GitHub Actions de este repo coinciden
# con el contrato que este fork NECESITA para funcionar?
#
# Responde esa pregunta y NADA MÁS. Nunca muta: solo hace peticiones GET a la
# API de GitHub. La decisión de qué hacer con la respuesta es del llamador.
#
# ─── Contrato de salida ──────────────────────────────────────────────────────
#   0 — Los dos ajustes que este guion AFIRMA coinciden con lo esperado, y los
#       dos que solo INFORMA se pudieron leer.
#   1 — Hay deriva REAL y accionable: un HTTP 200 devolvió un valor distinto
#       del esperado. Solo dos de los cuatro ajustes pueden producir un 1
#       (ver la tabla de abajo).
#   2 — NO SE PUDO RESPONDER ("no sé", NO "está mal"): no hay `gh` instalado,
#       no hay sesión autenticada, el repo o la rama no existen, el token no
#       tiene el permiso que el endpoint exige, o la respuesta de la API es
#       ilegible, truncada o incompleta.
#
#       OJO: 2 significa "no sé", NO significa "está mal". Confundirlos aquí
#       sería el peor fallo posible del guion: un operador sin admin sobre la
#       réplica de un cliente vería "tus ajustes están mal" cuando lo único
#       que pasa es que su token no puede leerlos, e iría a cambiar a ciegas
#       una configuración que quizá ya estaba bien.
#
# ─── Los cuatro ajustes, y cuál puede dar exit 1 ─────────────────────────────
#   1. Workflows deshabilitados  · actions/workflows                    → SÍ
#      Los tres workflows propios en `state: active`, y ninguno de los del
#      árbol en `disabled_manually`/`disabled_inactivity`/`disabled_fork`/
#      `deleted`. Además cruza la lista de la API contra el árbol de la rama,
#      EN LAS DOS DIRECCIONES.
#   2. Workflow permissions      · actions/permissions/workflow         → SÍ
#      `default_workflow_permissions == "read"`.
#   3. Aprobación de PR de fork  · .../fork-pr-contributor-approval     → NO
#      Solo IMPRIME el valor medido. No hay un valor "correcto" que este fork
#      pueda afirmar sin conocer la política del dueño del repo.
#   4. Secrets de Actions        · actions/secrets                      → NO
#      Solo LISTA LOS NOMBRES para que el humano compare. Nunca imprime
#      valores: la API tampoco los devuelve.
#
# ─── Por qué el contrato dice `read` y no `write` (RULING, no re-litigar) ────
# «El contrato tiene que decir lo que el fork NECESITA, no lo que TIENE: los
# tres workflows propios llevan `permissions:` explícito y son inmunes, así
# que el fork no necesita `write`, y una réplica de cliente que nazca en el
# default de GitHub (`read`) DEBE SALIR VERDE, que es justamente el caso de
# uso del guion.»
#
# CONSECUENCIA QUE NO ES UN BUG: sobre `aclicona/licona-saleor` HOY
# (2026-09-26) este guion sale EXIT 1, porque ese repo está en `write`. Eso es
# deriva REAL y accionable —un toggle en Settings → Actions → General →
# "Workflow permissions" → "Read repository contents and packages
# permissions"— no un falso positivo del guion.
#
#   NO "arregles" este guion cambiando el valor esperado a `write`.
#   Arreglar el guion para que el repo salga verde es invertir la pregunta:
#   convertiría el verificador en un espejo del estado actual, que es
#   exactamente lo único que un verificador no puede ser.
#
# ─── Cómo se decide 1 vs 2 aquí: NO se replica el truco de `.protected` ──────
# Su hermano `check-branch-protection.sh` necesita un mecanismo de desempate
# —consultar `.protected` en /branches/<rama>— porque la API de GitHub usa el
# MISMO 404 para "la rama no está protegida" (deriva real) y para "no tienes
# permiso para leer su protección" (no sé).
#
#   ESE MECANISMO NO HACE FALTA EN ESTE GUION, Y NO DEBE REPLICARSE AQUÍ
#   POR ANALOGÍA.
#
# MEDIDO el 2026-09-26, por dos frentes independientes que coincidieron, y
# reconfirmado a mano contra TRES repos ajenos (`saleor/saleor`, `cli/cli`,
# `microsoft/vscode`): con un token sin admin, los tres endpoints con gate
# (`permissions/workflow`, `fork-pr-contributor-approval`, `secrets`)
# devuelven un HTTP 403 LIMPIO, nunca un 404 confundible con "no está
# configurado". No hay ambigüedad que desempatar, así que no hay desempate
# que escribir.
#
#   REGLA DURA: la única vía a exit 1 es un HTTP 200 cuyo valor difiera del
#   esperado. Cualquier fallo de llamada —403, 404, 422, 409, 5xx, red,
#   cuerpo incompleto— es exit 2.
#
# Tres detalles medidos que este guion trata por MEDICIÓN, no por suposición:
#
# · `fork-pr-contributor-approval` es el ÚNICO de los cuatro con un 404
#   DOCUMENTADO en el OpenAPI de GitHub que no se pudo provocar en ninguna
#   prueba. Está mapeado a 2 desde la primera línea a propósito: un 404 que
#   nadie ha visto no se puede interpretar, y "no sé" es la única lectura
#   honesta de una respuesta que no se entiende.
#
# · El OpenAPI declara SOLO `200` para `actions/permissions/workflow`,
#   `actions/secrets` y `actions/workflows`, y los tres primeros devuelven un
#   403 real. NO se deriva el manejo de errores de la especificación: se
#   deriva de lo medido.
#
# · La lista de `actions/workflows` puede traer ENTRADAS FANTASMA: registros
#   con `path` y `name` VACÍOS. MEDIDO el 2026-09-26 sobre cinco repos, y
#   aparecen en DOS de ellos: `saleor/saleor`
#   (`{"id":147273,"name":"","path":"","state":"active"}`) y `cli/cli`
#   (`{"id":218150, ..., "state":"disabled_manually"}`). NO las tienen
#   `aclicona/licona-saleor`, `microsoft/vscode` ni `django/django`.
#   En los dos casos el total de líneas CUADRABA con `total_count` (62 = 2 × 31
#   en saleor/saleor), así que no es una truncación de la lectura: es basura
#   del lado de GitHub.
#   Este guion las cuenta, las nombra en la salida y las deja FUERA de todo
#   veredicto — ni deriva ni "no sé"—, por el mismo motivo por el que deja
#   fuera `dynamic/dependabot/update-graph`: una entrada sin ruta no se puede
#   cruzar contra el árbol, y no hay nada accionable en un workflow que no
#   tiene archivo al que apuntar. Tratarlas como "forma mala" y salir con 2
#   haría el guion INÚTIL contra el 40 % de los repos medidos, que es justo lo
#   contrario de para lo que existe.
#
# · `actions/secrets` sin permiso da 403, NUNCA un 200 con lista vacía
#   (medido explícitamente). Por tanto un `{"total_count":0}` con HTTP 200 es
#   un DATO REAL —este repo no tiene secrets— y no una avería: se reporta
#   como listado obtenido (exit 0), no como "no pude listar".
#
# Y una regla de estilo que sale de lo mismo: los mensajes de 403 varían de
# texto entre endpoints (unos hablan de "Actions policies fine-grained
# permission", otros de "secrets fine-grained permission"), y `gh` no siempre
# imprime el número —el 409 de `selected-actions` sale como "(Conflict)", sin
# código—. Este guion RAMIFICA POR CÓDIGO HTTP, JAMÁS POR EL TEXTO.
#
# ─── Alcance: qué NO verifica ────────────────────────────────────────────────
# · NO verifica que los bloques `permissions:` sigan puestos en los workflows
#   propios. Que `default_workflow_permissions` esté en `read` NO garantiza
#   que esos bloques existan: son dos cosas independientes, y la segunda vive
#   en el árbol. De eso se encarga
#   `saleor/tests/test_fork_github_settings_drift.py`.
# · NO verifica el CONTENIDO de los workflows (qué hacen, en qué disparan,
#   si su lógica es correcta). Solo su `state` y su existencia.
# · NO verifica los VALORES de los secrets, ni si un secret que un workflow
#   referencia existe de verdad en el repo. La API no devuelve valores, y un
#   secret inexistente llega al workflow como cadena vacía sin ningún error.
#   Comparar la lista de nombres con lo que el árbol usa es trabajo del test.
# · NO verifica la branch protection: eso es `check-branch-protection.sh`.
# · NO consulta tres endpoints vecinos que devuelven códigos raros sobre
#   repos públicos y que NO están en el contrato (medido el 2026-09-26 contra
#   `aclicona/licona-saleor`): `actions/permissions/fork-pr-workflows-private-repos`
#   → 422 ("not allowed for public repositories"), `actions/permissions/access`
#   → 422 ("only applies to internal and private repositories"),
#   `actions/permissions/selected-actions` → 409 ("All actions and workflows
#   are allowed"). Se dejan escritos aquí para que nadie los añada creyendo
#   que su código raro es una deriva: no ramifiques con la lógica "no es 200
#   → está mal".
# · Un exit 0 significa "estos cuatro ajustes, leídos así", NO "la
#   configuración de Actions de este repo está bien". El mensaje final lo
#   dice en voz alta a propósito.
#
# ─── Por qué existe ──────────────────────────────────────────────────────────
# Ninguno de estos cuatro ajustes viaja con el código: viven solo en la
# configuración del repo del lado de GitHub. Cuando este fork se replica para
# un cliente nuevo (nuevo repo, mismo código), no se copian solos — y el
# silencio es total.
#
# Los dos silencios concretos que ya mordieron a este fork:
#   · `sync-upstream.yml` (ver su cabecera, líneas 3-18) no corrió NI UNA VEZ
#     entre abril y agosto de 2026. Cuatro meses sin sincronizar, sin un solo
#     aviso, y el PR #3 acabó mergeando DOS CVE con CERO checks.
#   · `UPGRADE_NOTES.md` (líneas 448-459) fija la regla: «Lo que no está en el
#     árbol no existe para la instancia N+1. Se borra en el árbol, NUNCA con
#     `gh workflow disable` ni desde la UI de Actions», porque el estado
#     `disabled` vive en la base de datos de GitHub y NO SE CLONA.
#
# Este guion existe para que la réplica pueda AFIRMAR que los ajustes quedaron
# bien puestos, en vez de heredar ese silencio.
#
# Es el hermano conceptual de `check-branch-protection.sh`,
# `check-schema-fidelity.sh` y `check-migrations.sh`: misma pregunta de fondo
# (¿el estado externo sigue sincronizado con lo que el fork afirma?), mismo
# contrato de tres códigos, mismo compromiso de no mutar nada.
#
# DATO ÚTIL PARA QUIEN REPLICA: de los cuatro endpoints, `actions/workflows`
# es el ÚNICO que NO exige admin — devuelve 200 sobre repos ajenos (medido el
# 2026-09-26: `saleor/saleor` 31 workflows, `cli/cli` 21,
# `microsoft/vscode` 42). Es decir: un operador SIN admin sobre la réplica de
# un cliente sí puede verificar el ajuste 1, el más caro de los cuatro. Por
# eso ese ajuste se consulta PRIMERO y su resultado se imprime EN CUANTO se
# conoce, antes de que un 403 en el ajuste 2 corte el guion con exit 2.
#
# ─── Convenciones ────────────────────────────────────────────────────────────
# · sh POSIX puro, sin bashismos, como los otros guiones de `scripts/`.
# · Todo lo humano sale por stdout, en un solo flujo, para que ningún
#   llamador pierda la mitad del mensaje por capturar solo una de las dos
#   salidas. El stderr de `gh` va a un temporal, del que se saca una "línea
#   reveladora" cuando hace falta.
# · Sin `set -e` a propósito: aquí los códigos de salida distintos de cero
#   son el dato que venimos a leer, no una avería que deba abortar el guion.
# · Antes de comparar nada, se valida que la respuesta TENGA FORMA de
#   respuesta (número de líneas y campos no vacíos). Sin esa guarda, una
#   avería del entorno se disfraza de deriva: es exactamente el mismo
#   principio que `check-schema-fidelity.sh` aplica al exigir "salida no
#   vacía Y que parezca un esquema" ANTES de mirar el diff.
# · Se acumulan TODAS las derivas y el exit code se decide al final: un
#   llamador que solo se entera de un campo roto por corrida tarda varias
#   corridas en ver el cuadro completo.
# · Solo lecturas: cada llamada a `gh api` de este guion es un GET implícito
#   (sin `-X`). El guion JAMÁS ejecuta un `-X PUT`/`-X POST`/`-X PATCH`/
#   `-X DELETE`, ni `gh workflow enable/disable/run`, ni `gh secret set`. Un
#   remedio se IMPRIME, nunca se ejecuta.
#
# ─── Parametrización — para otro repo o rama ─────────────────────────────────
# Por defecto verifica ESTE fork. Para verificar la réplica de un cliente, sin
# editar el guion:
#
#   REPO=cliente/su-saleor RAMA=stable/3.22 sh scripts/check-github-settings.sh
#
# La RAMA se usa para el cruce contra el árbol (`contents/.github/workflows`):
# la lista de la API de Actions no dice en qué rama vive cada archivo, así que
# hay que decirle contra qué rama comparar.

ETIQUETA="[check-github-settings]"

# `${VAR:-default}` cae al default TAMBIÉN cuando la variable está definida
# pero VACÍA. Eso convertiría `REPO='' sh scripts/check-github-settings.sh` en
# un veredicto verde sobre el repo EQUIVOCADO —el default de este fork—
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
RAMA="${RAMA:-stable/3.22}"

# Los tres workflows PROPIOS del fork (no existen en upstream). Esta lista está
# ACOPLADA a los archivos reales de `.github/workflows/`: si alguien borra o
# renombra uno y no toca esta línea, el guion exigirá para siempre el
# `state: active` de algo que ya no existe — un exit 1 INARREGLABLE, porque no
# hay nada que arreglar salvo esta propia lista.
# Por eso existe `saleor/tests/test_fork_github_settings_drift.py`: ese test
# verifica que cada ruta de aquí siga existiendo en el árbol y que ninguna
# caiga fuera de `.github/workflows/`. Si cambias los workflows, cambia también
# esta línea EN EL MISMO COMMIT.
WORKFLOWS_PROPIOS=".github/workflows/ci-fork.yml,.github/workflows/security-scan.yml,.github/workflows/sync-upstream.yml"

# Los secrets de Actions que los workflows PROPIOS necesitan, además del
# `GITHUB_TOKEN` que GitHub inyecta solo. HOY ESTÁ VACÍA A PROPÓSITO: ningún
# workflow propio referencia un `${{ secrets.X }}` con X distinto de
# `GITHUB_TOKEN` (verificado el 2026-09-26 recorriendo el YAML cargado, no el
# texto: `ci-fork.yml` línea 11 nombra `secrets.GITHUB_TOKEN` dentro de un
# COMENTARIO, y un regex sobre el texto lo leería como uso real).
# Está ACOPLADA al árbol igual que la de arriba, y el mismo test la vigila:
# si añades un secret a un workflow propio, añádelo aquí EN EL MISMO COMMIT.
# El guion NO afirma nada sobre ella (el ajuste 4 solo informa): la lista
# existe para que el test tenga contra qué comparar y para que el humano vea
# el conjunto esperado junto al medido.
SECRETS_ESPERADOS=""

# El valor que este fork NECESITA en Settings → Actions → General → "Workflow
# permissions". Ver el RULING en la cabecera antes de tocar esta línea.
PERMISO_ESPERADO="read"

# Prefijo de las rutas que corresponden a archivos reales del árbol. La API de
# Actions devuelve TAMBIÉN una entrada SINTÉTICA `dynamic/dependabot/update-graph`
# (nombre visible "Dependency Graph") que NO tiene archivo en ninguna rama.
# Sin este filtro, el cruce contra el árbol fabricaría una deriva falsa el día
# uno, todos los días.
PREFIJO_WORKFLOWS=".github/workflows/"

# El enum completo de `state` tiene CINCO valores, verificado contra
# `github/rest-api-description`. Solo `active` y `disabled_manually` tienen
# evidencia viva en este fork, pero se manejan los cinco: un valor fuera de
# este conjunto significa que la API cambió y que no sé leerla → exit 2, nunca
# exit 1.
ESTADOS_CONOCIDOS="active,deleted,disabled_fork,disabled_inactivity,disabled_manually"

# Valor de referencia ENDURECIDO para la política de aprobación de PR de fork
# (ajuste 3): `all_external_contributors` exige aprobación manual para CUALQUIER
# contribuidor externo, no solo para los de primera vez. Es el ajuste más
# restrictivo que ofrece GitHub. NO se afirma —el guion solo imprime el valor
# medido— porque cuál es el correcto depende de la política del dueño del
# repo, no de nada que este fork pueda deducir de su código.
# Los otros valores del enum: `first_time_contributors_new_to_github`,
# `first_time_contributors`, `none`.

# ─── Cómo se arregla cada deriva ─────────────────────────────────────────────
# Este guion NUNCA ejecuta los comandos de abajo: solo los imprime. Aplicar un
# cambio de configuración es una decisión del humano (o de otro guion
# explícitamente mutador), no de un verificador de solo lectura.
#
# El bloque se imprime SIN el prefijo de $ETIQUETA a propósito en las líneas
# que son comandos pegables. Con el prefijo, un comando prefijado no se puede
# pegar — y un remedio que no se puede pegar no es un remedio.
consejo_permisos() {
  echo "$ETIQUETA Para poner los permisos por defecto en '$PERMISO_ESPERADO' (esto el guion NO lo"
  echo "$ETIQUETA ejecuta, es solo cómo se hace). La vía recomendada es la UI, un solo toggle:"
  echo "$ETIQUETA   https://github.com/$REPO/settings/actions"
  echo "$ETIQUETA   → Workflow permissions → 'Read repository contents and packages permissions'"
  echo "$ETIQUETA AVISO si prefieres la API: el PUT de abajo MUTA la configuración del repo y"
  echo "$ETIQUETA REEMPLAZA el objeto entero, así que también fija"
  echo "$ETIQUETA 'can_approve_pull_request_reviews'. Mira qué hay puesto antes de escribir."
  echo ""
  echo "gh api -X PUT repos/$REPO/actions/permissions/workflow \\"
  echo "  -f default_workflow_permissions=$PERMISO_ESPERADO \\"
  echo "  -F can_approve_pull_request_reviews=<true|false>"
  echo ""
}

consejo_workflows() {
  echo "$ETIQUETA Cómo se arregla un workflow que no está en 'active' (el guion NO lo ejecuta):"
  echo "$ETIQUETA   · Si se apagó por INACTIVIDAD ('disabled_inactivity'), basta reactivarlo; el"
  echo "$ETIQUETA     cron vuelve a contar desde cero. Mira si hay un motivo de fondo (el repo"
  echo "$ETIQUETA     llevaba meses quieto) antes de dar el problema por resuelto."
  echo "$ETIQUETA   · Si se apagó A MANO ('disabled_manually'), ESE ES EL BUG. Lee la regla de"
  echo "$ETIQUETA     UPGRADE_NOTES.md (líneas 448-459): el estado 'disabled' NO SE CLONA, así"
  echo "$ETIQUETA     que la réplica del cliente arranca con el cron rojo el día uno. Lo que no"
  echo "$ETIQUETA     debe correr SE BORRA DEL ÁRBOL, nunca se deshabilita por la UI."
  echo "$ETIQUETA   · El comando existe, pero MUTA y NO es solo-lectura. Úsalo a sabiendas:"
  echo ""
  echo "gh workflow enable <nombre-o-id> --repo $REPO"
  echo ""
}

# Diagnostica un fallo de `gh api` y lo imprime. NO decide el exit: el llamador
# sale con 2 siempre (ver la REGLA DURA de la cabecera). Ramifica SOLO por
# código HTTP, nunca por el texto del mensaje.
#   $1 = descripción humana de la llamada
#   $2 = archivo con el stderr de `gh`
#   $3 = código de salida de `gh`
diagnosticar_fallo() {
  if grep -qi 'HTTP 403' "$2"; then
    echo "$ETIQUETA NO SE PUDO RESPONDER: HTTP 403 al consultar $1 de '$REPO'."
    echo "$ETIQUETA Este endpoint exige permiso de administración (o el fine-grained equivalente)"
    echo "$ETIQUETA sobre el repo. Es el caso NORMAL cuando quien pregunta no es dueño del repo:"
    echo "$ETIQUETA no dice que el ajuste esté mal, dice que no puedo leerlo."
    echo "$ETIQUETA Cómo se arregla: pregunta con un token que tenga admin sobre '$REPO' (revisa"
    echo "$ETIQUETA 'gh auth status'); si esto corre en un workflow, el job necesita el scope"
    echo "$ETIQUETA correspondiente en su bloque 'permissions:'."
  elif grep -qi 'HTTP 404' "$2"; then
    echo "$ETIQUETA NO SE PUDO RESPONDER: HTTP 404 al consultar $1 de '$REPO'."
    echo "$ETIQUETA Puede ser que el repo o la rama no existan, o que este endpoint haya cambiado"
    echo "$ETIQUETA de ruta. Revisa REPO='$REPO' y RAMA='$RAMA'."
    echo "$ETIQUETA Un 404 aquí NO se interpreta como 'el ajuste no está configurado': eso sería"
    echo "$ETIQUETA inventarse una deriva a partir de una respuesta que no entiendo."
  else
    echo "$ETIQUETA NO SE PUDO RESPONDER: 'gh api' falló consultando $1 (código $3)."
    echo "$ETIQUETA Línea reveladora: $(tail -n 1 "$2")"
    echo "$ETIQUETA Cualquier respuesta que no sea un 200 legible es 'no sé', nunca 'está mal'."
  fi
}

# ─── 0. ¿Hay con qué preguntar? ──────────────────────────────────────────────
if ! command -v gh >/dev/null 2>&1; then
  echo "$ETIQUETA No se encontró el CLI 'gh' en el PATH."
  echo "$ETIQUETA Instálalo con: brew install gh"
  echo "$ETIQUETA No sé responder si los ajustes de Actions coinciden con el contrato."
  exit 2
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "$ETIQUETA 'gh' no tiene una sesión autenticada."
  echo "$ETIQUETA Inicia sesión con: gh auth login"
  echo "$ETIQUETA No sé responder si los ajustes de Actions coinciden con el contrato."
  exit 2
fi

TMP=$(mktemp -d) || {
  echo "$ETIQUETA No se pudo crear un directorio temporal. No sé responder."
  exit 2
}
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

# A diferencia de `check-branch-protection.sh`, aquí la rama NO viaja como
# segmento de la ruta de la API sino como parámetro de consulta
# (`contents/...?ref=<rama>`), donde un '/' literal es legal. Por eso NO hace
# falta escaparla a '%2F'. Medido el 2026-09-26 con RAMA='stable/3.22'.

DERIVAS=""

# ─── 1. Workflows: ¿están todos registrados, activos, y cuadran con el árbol? ─
# Se consulta PRIMERO y su veredicto se imprime EN CUANTO se conoce, porque es
# el único de los cuatro endpoints que NO exige admin: un operador sin admin
# sobre la réplica de un cliente obtiene ESTE dato y luego un 403 en el ajuste
# 2. Si esta sección se imprimiera al final, ese operador no vería nada.

# 1.a — `total_count` en una llamada SIN `--paginate`. GitHub devuelve el total
# GLOBAL en cada página, así que `per_page=1` basta y es la forma más barata de
# saberlo. No se puede sacar de la llamada paginada de 1.b: con `--paginate`,
# `gh` aplica el `--jq` A CADA PÁGINA y `.total_count` saldría repetido una vez
# por página, lo que es justo el tipo de salida desincronizada que este guion
# no acepta.
gh api "repos/$REPO/actions/workflows?per_page=1" \
  --jq '.total_count | tostring' \
  >"$TMP/wf_total.out" 2>"$TMP/wf_total.err"
CODIGO=$?
if [ "$CODIGO" -ne 0 ]; then
  diagnosticar_fallo "el total de workflows (actions/workflows)" "$TMP/wf_total.err" "$CODIGO"
  exit 2
fi

# Se cuentan las líneas con `awk 'END {print NR+0}'` y no con `wc -l`: `wc -l`
# cuenta SALTOS de línea, así que una salida truncada sin salto final se
# contaría de menos. `NR` de awk cuenta también la última línea incompleta.
LINEAS=$(awk 'END {print NR+0}' "$TMP/wf_total.out")
TOTAL_WF=$(sed -n '1p' "$TMP/wf_total.out")
case "$TOTAL_WF" in
  '' | *[!0-9]*) TOTAL_WF_VALIDO=0 ;;
  *) TOTAL_WF_VALIDO=1 ;;
esac
if [ "$LINEAS" -ne 1 ] || [ "$TOTAL_WF_VALIDO" -ne 1 ]; then
  echo "$ETIQUETA NO SE PUDO RESPONDER: 'actions/workflows' salió con código 0 pero su"
  echo "$ETIQUETA 'total_count' no es un entero legible: esperaba 1 línea con un número,"
  echo "$ETIQUETA obtuve $LINEAS línea(s) con '${TOTAL_WF:-(vacío)}'."
  echo "$ETIQUETA Sin ese total no puedo saber si la lista paginada llegó completa."
  exit 2
fi

# 1.b — La lista completa. `--paginate` NO ES COSMÉTICO: este fork ya tiene 24
# entradas registradas y la página por defecto de GitHub es de 30. Sin
# `--paginate`, el guion se rompería EN SILENCIO el día que pase de 30,
# fabricando una deriva "este workflow no está registrado" por cada entrada de
# la página 2 en adelante. Y `per_page=100` reduce el número de páginas.
#
# Se emite UNA LÍNEA POR CAMPO (ruta, luego estado) y NO como '@tsv': con
# campos tabulados, cualquier valor vacío colapsa el conteo de columnas al
# leerlo con IFS=tab y un `read` partido a mano se desincroniza en silencio.
# Dos líneas por registro sí permiten detectar la desincronización: se exige
# que el total de líneas sea EXACTAMENTE 2 × total_count, y que ninguno de los
# dos campos venga vacío.
gh api --paginate "repos/$REPO/actions/workflows?per_page=100" \
  --jq '.workflows[] | [ .path, (.state | tostring) ] | .[]' \
  >"$TMP/wf.out" 2>"$TMP/wf.err"
CODIGO=$?
if [ "$CODIGO" -ne 0 ]; then
  diagnosticar_fallo "la lista de workflows (actions/workflows)" "$TMP/wf.err" "$CODIGO"
  exit 2
fi

LINEAS_WF=$(awk 'END {print NR+0}' "$TMP/wf.out")
LINEAS_ESPERADAS=$((TOTAL_WF * 2))
if [ "$LINEAS_WF" -ne "$LINEAS_ESPERADAS" ]; then
  echo "$ETIQUETA NO SE PUDO RESPONDER: la lista de workflows no cuadra con su propio"
  echo "$ETIQUETA 'total_count'. La API dice $TOTAL_WF workflows (= $LINEAS_ESPERADAS líneas, dos"
  echo "$ETIQUETA por entrada) y recibí $LINEAS_WF."
  echo "$ETIQUETA Línea reveladora: $(tail -n 1 "$TMP/wf.err")"
  echo "$ETIQUETA La causa típica es paginación truncada. Esto NO dice que falte ningún"
  echo "$ETIQUETA workflow: dice que no pude leer la lista entera. No apliques ningún remedio."
  exit 2
fi

# Se reparten las dos líneas de cada registro en un archivo de pares dentro de
# $TMP. El bucle NO va detrás de una tubería, así que las variables que toca
# sobreviven al `done` (en POSIX sh una tubería crearía una subshell y las
# perdería).
: >"$TMP/pares.tsv"
: >"$TMP/rutas_api.txt"
FORMA_MALA=0
MOTIVO_FORMA=""
FANTASMAS=0
while IFS= read -r RUTA_WF; do
  if ! IFS= read -r ESTADO_WF; then
    FORMA_MALA=1
    MOTIVO_FORMA="la última entrada ('$RUTA_WF') se quedó sin su línea de 'state'"
    break
  fi
  # Un `state` vacío sí es forma mala: el enum de más abajo también lo
  # rechazaría, pero se dice aquí con un motivo más claro.
  if [ -z "$ESTADO_WF" ]; then
    FORMA_MALA=1
    MOTIVO_FORMA="hay un registro con el 'state' vacío (ruta='$RUTA_WF')"
    break
  fi
  # Una RUTA vacía, en cambio, NO es forma mala: son ENTRADAS FANTASMA reales
  # de la API. Ver el bloque de la cabecera sobre ellas — medidas el 2026-09-26
  # en 2 de 5 repos. Se cuentan para informar y se dejan FUERA de todo
  # veredicto, por el mismo motivo por el que se deja fuera
  # `dynamic/dependabot/update-graph`: una entrada sin archivo en el árbol no se
  # puede cruzar contra el árbol, y no hay nada accionable en un workflow que no
  # tiene ruta. El filtro de $PREFIJO_WORKFLOWS de abajo ya las excluye sin
  # ayuda (una cadena vacía no empieza por '.github/workflows/'); esta rama
  # existe solo para poder contarlas y nombrarlas.
  if [ -z "$RUTA_WF" ]; then
    FANTASMAS=$((FANTASMAS + 1))
    continue
  fi
  # Un `state` fuera del enum conocido significa que la API cambió y que no sé
  # leerla. Es 2, nunca 1: comparar contra un valor que no entiendo es
  # inventarse el veredicto.
  ESTADO_CONOCIDO=0
  IFS_ORIGINAL=$IFS
  set -f
  IFS=','
  for EST in $ESTADOS_CONOCIDOS; do
    [ "$EST" = "$ESTADO_WF" ] && ESTADO_CONOCIDO=1
  done
  set +f
  IFS=$IFS_ORIGINAL
  if [ "$ESTADO_CONOCIDO" -ne 1 ]; then
    FORMA_MALA=1
    MOTIVO_FORMA="'$RUTA_WF' trae un state desconocido ('$ESTADO_WF'); el enum conocido es $ESTADOS_CONOCIDOS"
    break
  fi
  printf '%s\t%s\n' "$RUTA_WF" "$ESTADO_WF" >>"$TMP/pares.tsv"
  # Solo las rutas que corresponden a archivos reales entran en el cruce
  # contra el árbol (ver $PREFIJO_WORKFLOWS y el gotcha de la entrada
  # sintética `dynamic/dependabot/update-graph`).
  case "$RUTA_WF" in
    "$PREFIJO_WORKFLOWS"*) printf '%s\n' "$RUTA_WF" >>"$TMP/rutas_api.txt" ;;
  esac
done <"$TMP/wf.out"

if [ "$FORMA_MALA" -ne 0 ]; then
  echo "$ETIQUETA NO SE PUDO RESPONDER: la lista de workflows llegó con el número de líneas"
  echo "$ETIQUETA esperado pero mal formada — $MOTIVO_FORMA."
  echo "$ETIQUETA Comparar contra eso inventaría derivas. No apliques ningún remedio."
  exit 2
fi

# 1.c — El árbol de la rama. `select(.type=="file")` descarta el subdirectorio
# `.github/workflows/notify/` (que contiene un script auxiliar, no un
# workflow), y el filtro de extensión descarta cualquier otro archivo que
# alguien deje ahí: GitHub solo registra como workflow los `.yml`/`.yaml`.
# Sin ambos filtros, el cruce fabricaría deltas falsos.
gh api "repos/$REPO/contents/$PREFIJO_WORKFLOWS?ref=$RAMA" \
  --jq '.[] | select(.type == "file") | select(.name | test("\\.ya?ml$")) | .path' \
  >"$TMP/arbol.out" 2>"$TMP/arbol.err"
CODIGO=$?
if [ "$CODIGO" -ne 0 ]; then
  diagnosticar_fallo "el árbol de '$PREFIJO_WORKFLOWS' en la rama '$RAMA' (contents)" "$TMP/arbol.err" "$CODIGO"
  exit 2
fi

LINEAS_ARBOL=$(awk 'END {print NR+0}' "$TMP/arbol.out")
if [ "$LINEAS_ARBOL" -eq 0 ]; then
  echo "$ETIQUETA NO SE PUDO RESPONDER: 'contents/$PREFIJO_WORKFLOWS' respondió 200 pero sin un"
  echo "$ETIQUETA solo archivo .yml/.yaml en la rama '$RAMA'."
  echo "$ETIQUETA Un directorio vacío no existe en git, así que esto es una respuesta que no sé"
  echo "$ETIQUETA leer —no un árbol sin workflows—. Si lo tomara al pie de la letra reportaría"
  echo "$ETIQUETA una deriva por cada workflow registrado, y todas serían inventadas."
  exit 2
fi

# El cruce, EN LAS DOS DIRECCIONES. `state: active` NO implica que el archivo
# exista: MEDIDO en `saleor/saleor`, hay CUATRO workflows en `active` con el
# archivo borrado del árbol, uno desde 2024-09-13. GitHub nunca los transiciona
# a `deleted`. Y al revés: un archivo que GitHub no tenga registrado no sale en
# la lista de la API, y por tanto no corre nunca.
sort "$TMP/rutas_api.txt" >"$TMP/api.sorted"
sort "$TMP/arbol.out" >"$TMP/arbol.sorted"
comm -23 "$TMP/api.sorted" "$TMP/arbol.sorted" >"$TMP/solo_api.txt"
comm -13 "$TMP/api.sorted" "$TMP/arbol.sorted" >"$TMP/solo_arbol.txt"

# 1.d — Los tres workflows PROPIOS deben estar en 'active'. Se comprueban
# aparte del resto del árbol porque su consecuencia concreta es distinta y
# mucho más cara (ver los textos de abajo).
# La búsqueda del estado se hace con `awk -F'\t'`, no con un `read` de shell con
# IFS de tabulador: awk NO colapsa campos vacíos, y además ambos campos ya se
# validaron como no vacíos al construir el archivo.
IFS_ORIGINAL=$IFS
set -f
IFS=','
for RUTA_PROPIA in $WORKFLOWS_PROPIOS; do
  ESTADO_PROPIO=$(awk -F'\t' -v r="$RUTA_PROPIA" '$1 == r {print $2}' "$TMP/pares.tsv")
  if [ -z "$ESTADO_PROPIO" ]; then
    DERIVAS="${DERIVAS}x"
    echo "$ETIQUETA DERIVA en workflows_propios.state:"
    echo "$ETIQUETA   esperado: '$RUTA_PROPIA' registrado en 'active'"
    echo "$ETIQUETA   encontrado: GitHub no tiene ese workflow registrado (no sale en la lista)"
    echo "$ETIQUETA   Consecuencia: un workflow que la API no lista NO CORRE NUNCA, y"
    echo "$ETIQUETA   'gh workflow run' contra él falla. No hay error visible en ninguna parte:"
    echo "$ETIQUETA   simplemente no pasa nada, que es el modo de fallo más caro de este fork."
  elif [ "$ESTADO_PROPIO" != "active" ]; then
    DERIVAS="${DERIVAS}x"
    echo "$ETIQUETA DERIVA en workflows_propios.state:"
    echo "$ETIQUETA   esperado: active · encontrado: $ESTADO_PROPIO  ($RUTA_PROPIA)"
    if [ "$ESTADO_PROPIO" = "disabled_inactivity" ]; then
      echo "$ETIQUETA   Consecuencia: GitHub apaga los 'schedule' tras 60 días sin actividad y"
      echo "$ETIQUETA   DEJAN DE CORRER SIN AVISO. Es el fallo ya medido de los cuatro meses sin"
      echo "$ETIQUETA   sincronizar (sync-upstream.yml, líneas 3-18), en los que el PR #3 mergeó"
      echo "$ETIQUETA   DOS CVE con CERO checks."
    elif [ "$ESTADO_PROPIO" = "disabled_manually" ]; then
      echo "$ETIQUETA   Consecuencia: alguien usó la UI de Actions en vez de borrar el archivo."
      echo "$ETIQUETA   Ese estado NO SE CLONA (vive en la base de datos de GitHub, no en el"
      echo "$ETIQUETA   árbol), así que la réplica del cliente arranca con el cron ROJO el día"
      echo "$ETIQUETA   uno. UPGRADE_NOTES.md líneas 448-459: 'Se borra en el árbol, NUNCA con"
      echo "$ETIQUETA   gh workflow disable'."
    else
      echo "$ETIQUETA   Consecuencia: en '$ESTADO_PROPIO' el workflow no corre. Si el estado es"
      echo "$ETIQUETA   'deleted' GitHub lo dio de baja aunque el archivo siga en el árbol; si es"
      echo "$ETIQUETA   'disabled_fork', está apagado por ser este repo un fork."
    fi
  fi
done
set +f
IFS=$IFS_ORIGINAL

# 1.e — Ninguno de los workflows del ÁRBOL puede estar en un estado
# deshabilitado. Se excluyen los tres propios para no reportarlos dos veces:
# 1.d ya los cubre con su consecuencia específica.
while IFS= read -r RUTA_WF; do
  [ -z "$RUTA_WF" ] && continue
  ES_PROPIO=0
  IFS_ORIGINAL=$IFS
  set -f
  IFS=','
  for RUTA_PROPIA in $WORKFLOWS_PROPIOS; do
    [ "$RUTA_PROPIA" = "$RUTA_WF" ] && ES_PROPIO=1
  done
  set +f
  IFS=$IFS_ORIGINAL
  [ "$ES_PROPIO" -eq 1 ] && continue

  ESTADO_WF=$(awk -F'\t' -v r="$RUTA_WF" '$1 == r {print $2}' "$TMP/pares.tsv")
  if [ "$ESTADO_WF" != "active" ]; then
    DERIVAS="${DERIVAS}x"
    echo "$ETIQUETA DERIVA en workflows_del_arbol.state:"
    echo "$ETIQUETA   esperado: active · encontrado: $ESTADO_WF  ($RUTA_WF)"
    echo "$ETIQUETA   Consecuencia: ese workflow está en el árbol pero no corre. Si se apagó a"
    echo "$ETIQUETA   mano, ese estado NO SE CLONA a la réplica del cliente, que arrancará"
    echo "$ETIQUETA   ejecutándolo (y fallando) desde el día uno. La regla del fork es que lo"
    echo "$ETIQUETA   que no debe correr SE BORRA DEL ÁRBOL (UPGRADE_NOTES.md líneas 448-459)."
  fi
done <"$TMP/api.sorted"

# 1.f — Los dos deltas del cruce.
while IFS= read -r RUTA_WF; do
  [ -z "$RUTA_WF" ] && continue
  DERIVAS="${DERIVAS}x"
  echo "$ETIQUETA DERIVA en workflows.cruce_api_vs_arbol:"
  echo "$ETIQUETA   esperado: '$RUTA_WF' existe como archivo en la rama '$RAMA'"
  echo "$ETIQUETA   encontrado: GitHub lo tiene registrado, pero el archivo NO está en el árbol"
  echo "$ETIQUETA   Consecuencia: un registro sin archivo exige PARA SIEMPRE el 'active' de algo"
  echo "$ETIQUETA   que no existe, y GitHub nunca lo transiciona a 'deleted' por su cuenta"
  echo "$ETIQUETA   (medido en saleor/saleor: cuatro 'active' con el archivo borrado, uno desde"
  echo "$ETIQUETA   2024-09-13). Cualquier verificación sobre ese nombre queda encallada."
done <"$TMP/solo_api.txt"

while IFS= read -r RUTA_WF; do
  [ -z "$RUTA_WF" ] && continue
  DERIVAS="${DERIVAS}x"
  echo "$ETIQUETA DERIVA en workflows.cruce_api_vs_arbol:"
  echo "$ETIQUETA   esperado: '$RUTA_WF' registrado en la API de Actions"
  echo "$ETIQUETA   encontrado: el archivo está en el árbol, pero GitHub no lo tiene registrado"
  echo "$ETIQUETA   Consecuencia: NO CORRE NUNCA, y 'gh workflow run' contra él falla. Es el"
  echo "$ETIQUETA   estado en el que ya está 'tests-and-linters.yml' de upstream en este fork, y"
  echo "$ETIQUETA   el motivo entero de que 'ci-fork.yml' exista como archivo aparte."
done <"$TMP/solo_arbol.txt"

if [ -n "$DERIVAS" ]; then
  consejo_workflows
else
  # Este resultado se imprime AQUÍ, no al final, a propósito: es el único de
  # los cuatro ajustes que un token sin admin puede leer, y un 403 en el
  # ajuste 2 corta el guion con exit 2 antes de llegar al bloque verde final.
  echo "$ETIQUETA OK ajuste 1 (workflows): $TOTAL_WF registrados en la API, de los cuales"
  echo "$ETIQUETA $(awk 'END {print NR+0}' "$TMP/api.sorted") bajo '$PREFIJO_WORKFLOWS', todos en"
  echo "$ETIQUETA 'active'; cuadran exactamente con los $LINEAS_ARBOL archivos .yml/.yaml de la"
  echo "$ETIQUETA rama '$RAMA' (cruce sin delta en ninguna de las dos direcciones), y los tres"
  echo "$ETIQUETA workflows propios están registrados y activos."
fi

# Se informa SIEMPRE (haya derivas o no): quien lea la salida tiene que poder
# explicar la diferencia entre el total_count y el número de rutas cruzadas sin
# ir a la API a mano.
if [ "$FANTASMAS" -gt 0 ]; then
  echo "$ETIQUETA Nota (sin veredicto): $FANTASMAS entrada(s) FANTASMA en la lista de la API —"
  echo "$ETIQUETA registros con 'path' y 'name' vacíos—. No se cruzan contra el árbol ni entran en"
  echo "$ETIQUETA ningún veredicto: no hay archivo al que apunten y por tanto nada accionable."
  echo "$ETIQUETA Son basura del lado de GitHub, medida en 2 de 5 repos el 2026-09-26."
fi

# ─── 2. Workflow permissions — el ajuste que este fork NECESITA en 'read' ────
# Dos campos en la misma respuesta, una línea por campo (ver el porqué en 1.b).
# `can_approve_pull_request_reviews` se IMPRIME, NO SE AFIRMA: hoy vale true y
# no tiene consecuencia medible en este fork, así que afirmar un valor sería
# inventarse un contrato.
gh api "repos/$REPO/actions/permissions/workflow" \
  --jq '[ (.default_workflow_permissions | tostring),
          (.can_approve_pull_request_reviews | tostring) ] | .[]' \
  >"$TMP/perm.out" 2>"$TMP/perm.err"
CODIGO=$?
if [ "$CODIGO" -ne 0 ]; then
  diagnosticar_fallo "los permisos por defecto (actions/permissions/workflow)" "$TMP/perm.err" "$CODIGO"
  if [ -n "$DERIVAS" ]; then
    echo "$ETIQUETA Las derivas impresas arriba siguen siendo válidas y accionables; lo que no"
    echo "$ETIQUETA puedo dar es el veredicto completo."
  fi
  exit 2
fi

LINEAS_PERM=$(awk 'END {print NR+0}' "$TMP/perm.out")
PERMISO=$(sed -n '1p' "$TMP/perm.out")
APRUEBA_PR=$(sed -n '2p' "$TMP/perm.out")
if [ "$LINEAS_PERM" -ne 2 ] || [ -z "$PERMISO" ] || [ -z "$APRUEBA_PR" ]; then
  echo "$ETIQUETA NO SE PUDO RESPONDER: 'actions/permissions/workflow' salió con código 0 pero su"
  echo "$ETIQUETA respuesta no tiene la forma esperada: esperaba 2 líneas no vacías (una por"
  echo "$ETIQUETA campo), obtuve $LINEAS_PERM con default='${PERMISO:-(vacío)}' y"
  echo "$ETIQUETA can_approve='${APRUEBA_PR:-(vacío)}'."
  echo "$ETIQUETA Línea reveladora: $(tail -n 1 "$TMP/perm.err")"
  echo "$ETIQUETA Esto NO dice que el ajuste esté mal: dice que no pude leerlo. No apliques"
  echo "$ETIQUETA ningún remedio a partir de esto."
  exit 2
fi

if [ "$PERMISO" != "$PERMISO_ESPERADO" ]; then
  DERIVAS="${DERIVAS}x"
  echo "$ETIQUETA DERIVA en default_workflow_permissions:"
  echo "$ETIQUETA   esperado: $PERMISO_ESPERADO · encontrado: $PERMISO"
  echo "$ETIQUETA   Consecuencia: los tres workflows PROPIOS son INMUNES a este ajuste —llevan"
  echo "$ETIQUETA   bloque 'permissions:' explícito (ci-fork.yml líneas 26-28, sync-upstream.yml"
  echo "$ETIQUETA   líneas 47-61 y 557-559, security-scan.yml líneas 12-14)—, así que aquí no"
  echo "$ETIQUETA   hay ningún 403 de 'upload-artifact' que citar. La consecuencia real es más"
  echo "$ETIQUETA   estrecha y es de seguridad: en '$PERMISO', los workflows DE UPSTREAM que NO"
  echo "$ETIQUETA   llevan bloque 'permissions:' y que aún disparan reciben un token de ESCRITURA"
  echo "$ETIQUETA   que nadie les concedió explícitamente. Hoy son 'bump-dependencies.yml' (cron"
  echo "$ETIQUETA   mensual, abre PR) y 'create-tag-with-release-pr.yml' (crea tag y release)."
  consejo_permisos
fi

# ─── 3. Aprobación de PR de fork — se INFORMA, no se afirma ──────────────────
# Este es el ÚNICO de los cuatro endpoints con un 404 DOCUMENTADO en el OpenAPI
# de GitHub que no se pudo provocar en ninguna prueba. Va mapeado a exit 2
# desde la primera línea (a través de `diagnosticar_fallo`) a propósito: un 404
# que nadie ha visto no se puede interpretar, y "no sé" es la única lectura
# honesta de una respuesta que no se entiende. En particular NO se lee como
# "este repo no tiene política configurada".
gh api "repos/$REPO/actions/permissions/fork-pr-contributor-approval" \
  --jq '.approval_policy | tostring' \
  >"$TMP/fork.out" 2>"$TMP/fork.err"
CODIGO=$?
if [ "$CODIGO" -ne 0 ]; then
  diagnosticar_fallo "la política de aprobación de PR de fork (fork-pr-contributor-approval)" "$TMP/fork.err" "$CODIGO"
  if [ -n "$DERIVAS" ]; then
    echo "$ETIQUETA Las derivas impresas arriba siguen siendo válidas y accionables; lo que no"
    echo "$ETIQUETA puedo dar es el veredicto completo."
  fi
  exit 2
fi

LINEAS_FORK=$(awk 'END {print NR+0}' "$TMP/fork.out")
POLITICA_FORK=$(sed -n '1p' "$TMP/fork.out")
if [ "$LINEAS_FORK" -ne 1 ] || [ -z "$POLITICA_FORK" ]; then
  echo "$ETIQUETA NO SE PUDO RESPONDER: 'fork-pr-contributor-approval' salió con código 0 pero su"
  echo "$ETIQUETA respuesta no tiene la forma esperada: esperaba 1 línea no vacía, obtuve"
  echo "$ETIQUETA $LINEAS_FORK con '${POLITICA_FORK:-(vacío)}'."
  echo "$ETIQUETA Línea reveladora: $(tail -n 1 "$TMP/fork.err")"
  exit 2
fi

# ─── 4. Secrets de Actions — solo los NOMBRES, nunca los valores ─────────────
# Mismo esquema de dos llamadas que el ajuste 1, y por el mismo motivo: el
# `total_count` no se puede sacar de una llamada con `--paginate` sin que salga
# repetido por página.
gh api "repos/$REPO/actions/secrets?per_page=1" \
  --jq '.total_count | tostring' \
  >"$TMP/sec_total.out" 2>"$TMP/sec_total.err"
CODIGO=$?
if [ "$CODIGO" -ne 0 ]; then
  diagnosticar_fallo "el total de secrets (actions/secrets)" "$TMP/sec_total.err" "$CODIGO"
  if [ -n "$DERIVAS" ]; then
    echo "$ETIQUETA Las derivas impresas arriba siguen siendo válidas y accionables; lo que no"
    echo "$ETIQUETA puedo dar es el veredicto completo."
  fi
  exit 2
fi

LINEAS=$(awk 'END {print NR+0}' "$TMP/sec_total.out")
TOTAL_SEC=$(sed -n '1p' "$TMP/sec_total.out")
case "$TOTAL_SEC" in
  '' | *[!0-9]*) TOTAL_SEC_VALIDO=0 ;;
  *) TOTAL_SEC_VALIDO=1 ;;
esac
if [ "$LINEAS" -ne 1 ] || [ "$TOTAL_SEC_VALIDO" -ne 1 ]; then
  echo "$ETIQUETA NO SE PUDO LISTAR: 'actions/secrets' salió con código 0 pero su 'total_count'"
  echo "$ETIQUETA no es un entero legible: esperaba 1 línea con un número, obtuve $LINEAS"
  echo "$ETIQUETA línea(s) con '${TOTAL_SEC:-(vacío)}'."
  exit 2
fi

# Solo los NOMBRES. La API no devuelve los valores de los secrets, y este guion
# tampoco imprimiría ninguno si los devolviera.
gh api --paginate "repos/$REPO/actions/secrets?per_page=100" \
  --jq '.secrets[] | .name' \
  >"$TMP/sec.out" 2>"$TMP/sec.err"
CODIGO=$?
if [ "$CODIGO" -ne 0 ]; then
  diagnosticar_fallo "la lista de secrets (actions/secrets)" "$TMP/sec.err" "$CODIGO"
  if [ -n "$DERIVAS" ]; then
    echo "$ETIQUETA Las derivas impresas arriba siguen siendo válidas y accionables; lo que no"
    echo "$ETIQUETA puedo dar es el veredicto completo."
  fi
  exit 2
fi

# Un `total_count: 0` con HTTP 200 es un DATO REAL, no una avería: medido
# explícitamente, un token sin permiso da 403 y NUNCA un 200 con lista vacía.
# Así que 0 nombres con la cuenta cuadrando es "listado obtenido", exit 0.
LINEAS_SEC=$(awk 'END {print NR+0}' "$TMP/sec.out")
if [ "$LINEAS_SEC" -ne "$TOTAL_SEC" ]; then
  echo "$ETIQUETA NO SE PUDO LISTAR: la lista de secrets no cuadra con su propio 'total_count'."
  echo "$ETIQUETA La API dice $TOTAL_SEC secrets y recibí $LINEAS_SEC nombre(s)."
  echo "$ETIQUETA Línea reveladora: $(tail -n 1 "$TMP/sec.err")"
  echo "$ETIQUETA La causa típica es paginación truncada. Esto NO dice que falte ningún secret:"
  echo "$ETIQUETA dice que no pude listarlos."
  exit 2
fi

# ─── 5. Lo que solo se informa, impreso junto ────────────────────────────────
echo "$ETIQUETA ─── Valores que este guion IMPRIME pero NO afirma ───"
echo "$ETIQUETA fork-pr-contributor-approval.approval_policy = $POLITICA_FORK"
echo "$ETIQUETA   Sin veredicto: cuál es el valor correcto depende de la política del dueño del"
echo "$ETIQUETA   repo, no de nada deducible del código de este fork. El valor más endurecido"
echo "$ETIQUETA   que ofrece GitHub es 'all_external_contributors' (exige aprobación manual para"
echo "$ETIQUETA   CUALQUIER contribuidor externo, no solo los de primera vez)."
echo "$ETIQUETA workflow.can_approve_pull_request_reviews = $APRUEBA_PR"
echo "$ETIQUETA   Sin veredicto: no tiene consecuencia medible en este fork."
echo "$ETIQUETA actions/secrets: $TOTAL_SEC secret(s) configurado(s) en el repo."
if [ "$TOTAL_SEC" -eq 0 ]; then
  echo "$ETIQUETA   (ninguno) — compáralo tú con lo que los workflows necesitan."
else
  while IFS= read -r NOMBRE_SEC; do
    [ -z "$NOMBRE_SEC" ] && continue
    echo "$ETIQUETA   · $NOMBRE_SEC"
  done <"$TMP/sec.out"
fi
echo "$ETIQUETA   Conjunto que los workflows PROPIOS necesitan además de GITHUB_TOKEN"
echo "$ETIQUETA   (SECRETS_ESPERADOS, la constante que el test vigila): ${SECRETS_ESPERADOS:-(ninguno)}"
echo "$ETIQUETA   Sin veredicto: solo se listan los NOMBRES, para que el humano compare. Nunca"
echo "$ETIQUETA   se imprimen valores (la API tampoco los devuelve), y este guion no comprueba"
echo "$ETIQUETA   si un secret que un workflow usa existe de verdad: uno inexistente llega al"
echo "$ETIQUETA   workflow como cadena vacía, sin ningún error. El conjunto esperado por el"
echo "$ETIQUETA   árbol vive en SECRETS_ESPERADOS y lo vigila"
echo "$ETIQUETA   saleor/tests/test_fork_github_settings_drift.py."

# ─── 6. Veredicto ────────────────────────────────────────────────────────────
if [ -n "$DERIVAS" ]; then
  echo "$ETIQUETA Los ajustes de Actions de '$REPO' NO coinciden con lo que este fork necesita,"
  echo "$ETIQUETA en al menos uno de los DOS ajustes que este guion afirma."
  exit 1
fi

# El verde dice EXACTAMENTE qué comprobó, y dice también qué NO. Afirmar "los
# ajustes de Actions están bien" mirando cuatro de ellos —y afirmando solo
# dos— sería prometer de más.
echo "$ETIQUETA Los DOS ajustes que este guion AFIRMA coinciden con lo que este fork necesita en"
echo "$ETIQUETA '$REPO' (rama '$RAMA'):"
echo "$ETIQUETA   1. workflows: los tres propios en 'active', ninguno del árbol deshabilitado o"
echo "$ETIQUETA      dado de baja, y la lista de la API cuadra con el árbol en AMBAS direcciones."
echo "$ETIQUETA   2. default_workflow_permissions = $PERMISO_ESPERADO"
echo "$ETIQUETA Y los DOS que solo informa se pudieron leer (ver el bloque de arriba)."
echo "$ETIQUETA ALCANCE: este 0 NO afirma que la configuración de Actions de este repo esté bien."
echo "$ETIQUETA En concreto NO afirma que los bloques 'permissions:' sigan puestos en los"
echo "$ETIQUETA workflows propios —eso vive en el árbol y lo vigila"
echo "$ETIQUETA saleor/tests/test_fork_github_settings_drift.py—, ni dice nada del CONTENIDO de"
echo "$ETIQUETA los workflows, ni de los valores de los secrets, ni de la branch protection"
echo "$ETIQUETA (eso es scripts/check-branch-protection.sh)."
exit 0
