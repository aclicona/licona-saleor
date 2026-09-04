# UPGRADE NOTES — licona-saleor fork

Este archivo documenta **todos los cambios aplicados encima del upstream de Saleor**.
Antes de cada actualización de upstream, revisar esta lista para detectar conflictos potenciales.

> **Regla de oro:** Solo actualizar de una minor a la siguiente consecutiva.
> Para ir de 3.22 → 3.24 hay que pasar por 3.23 primero.

---

## Cambios aplicados

### 2026-04-16 — Setup inicial Railway (base: 3.22.48)

**Archivos modificados:**

- `Dockerfile`
  - Agregado `netcat-openbsd` en apt-get para el script `wait-for-db.sh`.
  - Reemplazado `CMD` directo por `ENTRYPOINT ["scripts/railway-entrypoint.sh"]` + `CMD` original.
  - Motivo: Railway inyecta `$PORT` dinámicamente y necesita ejecutar migraciones en el arranque.

**Archivos creados:**

- `railway.json` — Configuración de build y deploy para Railway.
- `scripts/railway-entrypoint.sh` — Ejecuta `migrate` y opcionalmente crea superusuario antes de iniciar el proceso.
- `scripts/wait-for-db.sh` — Espera a que Postgres acepte conexiones (útil en Railway donde DB puede tardar en estar lista).
- `.env.railway.example` — Plantilla de variables de entorno para Railway (sin valores reales).
- `.github/workflows/sync-upstream.yml` — Sync semanal automático con upstream.
- `.github/workflows/build-image.yml` — Build y push de imagen Docker a GHCR en cada push a `stable/3.22`.
  ⚠️ **Retirado del árbol el 2026-09-03 sin haber tenido nunca un run verde** (0 éxitos en 36 runs,
  la imagen nunca llegó a existir en GHCR y nadie la consumía). Ver la entrada de esa fecha.
- `.github/workflows/security-scan.yml` — Escaneo Trivy semanal de vulnerabilidades en la imagen.

### 2026-04-17 — Fix migración discount.0052 para PostgreSQL 15+ (base: 3.22.48)

**Archivos modificados:**

- `saleor/discount/migrations/0052_drop_sales_constraints.py`
  - Envuelto cada `execute DROP CONSTRAINT` en `BEGIN/EXCEPTION WHEN others THEN null END`.
  - Motivo: PostgreSQL 15+ lanza `InvalidTableDefinition` al intentar dropear el constraint
    `*_id_not_null` en tablas donde `id` es parte de la PK (ej. `discount_sale_collections`).
    El `IF EXISTS` no es suficiente para este tipo de error; hay que capturar la excepción.
  - **Conflicto potencial al actualizar upstream:** Si Saleor corrige esta migración en el upstream,
    puede haber un conflicto en este archivo. Revisar y descartar el parche local si el fix upstream
    lo resuelve correctamente.

**Sin cambios en:**

- Lógica de negocio de Saleor
- Modelos ni settings de Django
- Código Python del core

### 2026-04-29 — Carga de `.env` para desarrollo local (base: 3.22.48)

**Archivos modificados:**

- `manage.py`
  - `from dotenv import load_dotenv` + `load_dotenv()` dentro de `if __name__ == "__main__":`,
    antes del `os.environ.setdefault("DJANGO_SETTINGS_MODULE", ...)`.
- `saleor/asgi/__init__.py`
  - `from dotenv import load_dotenv` en el bloque de imports de cabecera (como third-party, entre la
    stdlib y los imports relativos) + `load_dotenv()` a nivel de módulo antes del
    `os.environ.setdefault("DJANGO_SETTINGS_MODULE", ...)`.
  - **Corregido el 2026-08-22:** el import se había dejado suelto en la línea 34, después de las
    definiciones de función. `ruff check .` lo marcaba con `E402` (module level import not at top of
    file) e `I001` (import block un-sorted) — eran los **únicos 2 errores de lint del fork entero**.
    Mover el import a la cabecera deja `ruff check .` en `All checks passed!`. La posición de la
    **llamada** sí importa (tiene que preceder a la lectura de settings); la del import no.
- `saleor/celeryconf.py`
  - `from dotenv import load_dotenv` en los imports + `load_dotenv()` tras ellos.

**Motivo:** upstream espera las variables ya exportadas en el entorno (en Railway las inyecta la
plataforma). Para desarrollo local con `.env` hacía falta cargarlas explícitamente en los tres puntos
de entrada: comandos de gestión, ASGI y Celery (worker y beat).

**En producción es inocuo:** sin archivo `.env` presente, `load_dotenv()` es un no-op y las variables
siguen viniendo del entorno de Railway.

> ⚠️ **Riesgo conocido — `python-dotenv` no es dependencia directa.** Hoy llega de forma
> **transitiva**, como extra de `uvicorn[standard]` y con marker
> `platform_python_implementation != 'PyPy'` (ver `uv.lock`). Como el import es a nivel de módulo en
> `saleor/asgi/__init__.py` y `saleor/celeryconf.py`, si un cambio de resolución de dependencias
> dejara de traerlo, **los tres servicios (`saleor-api`, `saleor-worker`, `saleor-beat`) fallarían al
> arrancar** con `ModuleNotFoundError`. Hoy no ocurre porque los tres comparten la misma imagen, que
> sí instala `uvicorn[standard]`. Corrección pendiente: declarar `python-dotenv` como dependencia
> directa en `pyproject.toml`.
>
> ✅ **Resuelto el 2026-08-22** — ver la entrada de esa fecha más abajo.

**Conflicto potencial al actualizar upstream:** bajo. Son adiciones en zonas estables de los tres
archivos; un cambio de upstream en las mismas líneas es improbable pero revisable.

**Archivos modificados (higiene):**

- `.gitignore` — añadido `celerybeat-schedule*` (estado local de Celery beat, se regenera).

### 2026-08-22 — `python-dotenv` como dependencia directa (base: 3.22.48)

**Archivos modificados:**

- `pyproject.toml`
  - Añadida `"python-dotenv>=1.1.1,<2"` a `[project].dependencies`, en orden alfabético entre
    `python-dateutil` y `python-http-client`, con el estilo `>=mínimo,<major siguiente` que usa el
    resto del archivo. El mínimo es la versión que ya estaba resuelta en el lock, así que la
    restricción no fuerza ningún cambio de resolución.
- `uv.lock`
  - Regenerado con `uv lock` (uv 0.8.14, la misma versión que fija el hook `uv-lock` de
    `.pre-commit-config.yaml`; el `Dockerfile` usa la serie `0.8`). El diff son **exactamente dos
    líneas añadidas**: `python-dotenv` entra en `[[package]] name = "saleor"` → `dependencies` y en
    `metadata.requires-dist`. Ninguna versión de ningún paquete cambió; siguen siendo 239 paquetes
    resueltos y `python-dotenv` sigue clavada en 1.1.1.

**Motivo (por qué, no solo qué):** desde el 2026-04-29 hay `from dotenv import load_dotenv` **a nivel
de módulo** en `saleor/asgi/__init__.py` y `saleor/celeryconf.py` (y dentro de `__main__` en
`manage.py`), pero el paquete nunca se declaró. Llegaba de rebote como extra de `uvicorn[standard]`,
y encima condicionado al marker `platform_python_implementation != 'PyPy'`.

Que hoy funcione es una coincidencia de empaquetado, no un contrato: los tres servicios de producción
—`saleor-api`, `saleor-worker` y `saleor-beat`— comparten **la misma imagen Docker**, y esa imagen
instala `uvicorn[standard]` porque la API sirve con uvicorn. El worker y el beat **no necesitan
uvicorn para nada**; el día que se construya una imagen separada y más delgada para ellos —o que un
upgrade de `uvicorn` mueva `python-dotenv` fuera del extra `standard`—, los tres arrancarían con
`ModuleNotFoundError: No module named 'dotenv'` **antes de emitir un solo log útil**. Es un fallo de
arranque, silencioso en la revisión de código y ruidoso en producción.

Declararla directa convierte esa dependencia implícita en explícita: el resolvedor la garantiza
aunque `uvicorn` desaparezca del árbol.

**Verificación:** `uv tree --invert --package python-dotenv` pasa de listar un solo consumidor
(`uvicorn (extra: standard)`) a listar dos (`saleor` y `uvicorn`). Además `manage.py check` limpio y
`ruff check .` en `All checks passed!`.

**Conflicto potencial al actualizar upstream:** medio-bajo. `pyproject.toml` y `uv.lock` son
archivos que upstream toca a menudo (bumps de dependencias), así que el sync semanal puede marcar
conflicto ahí. La resolución es siempre la misma: conservar la línea de `python-dotenv` y regenerar
el lock. Upstream no usa `python-dotenv`, por lo que nunca va a añadir la línea por su cuenta.

---

### 2026-08-27 — CI propia del fork y verificación de los PR de sync (base: 3.22.67)

**Archivos añadidos:**

- `.github/workflows/ci-fork.yml` — **nuevo, sin equivalente en upstream.** Tres jobs: `puerta`
  (import + ruff + `manage.py check` + `makemigrations --check`, techo 15 min), `linters`
  (`pre-commit run --all`, techo 20 min) y `suite` (la suite completa sin e2e, techo 60 min).
  Dispara con `pull_request` sobre `stable/*` y con `workflow_dispatch` (input `alcance`:
  `completo` | `rapido`).

**Archivos modificados:**

- `.github/workflows/sync-upstream.yml` — el job `sync` pasa de un `run:` monolítico a cinco pasos
  con `id`. Añade una **puerta rápida en línea** (techo 10 min, sin tests) cuando el merge sale sin
  conflictos, dispara `ci-fork.yml` sobre la rama de sync, y **reescribe el cuerpo del PR** para que
  el estado de verificación sea lo primero que se lee. El job `check-new-minor` **no se tocó**
  (verificado por diff de bloque: 117 líneas idénticas antes y después).
- `manage.py` — **una línea en blanco** tras `from dotenv import load_dotenv`, que es lo que pide
  `ruff-format`. Ver el motivo abajo.

**Motivo — por qué existe un `ci-fork.yml` en vez de arreglar `tests-and-linters.yml`:**

Medido el 2026-08-27 contra la API de Actions de GitHub, no supuesto:

```
gh api repos/aclicona/licona-saleor/actions/workflows/tests-and-linters.yml -q .state
→ deleted
```

Lo mismo para `check-licenses.yaml` y `check-migration-tasks.yml`. Los tres archivos **existen** en
`stable/3.22`, que es la rama por defecto, y aun así GitHub los tiene por borrados. La explicación más
probable —**inferencia, no medición**— es que el registro de Actions del fork heredara el borrado que
upstream hizo en `ec664a1d32` (*fix(build): always run linters + add `sfw`*, #19573), un commit que
solo vive en ramas de upstream. Lo medido es el `state` y el historial vacío, no la causa; para el
arreglo la causa da igual. Consecuencia medida:
`gh run list --workflow tests-and-linters.yml` devuelve **vacío** — la suite de este fork **no ha
corrido ni una sola vez** desde que se creó en abril de 2026.

Aun sin ese problema, tocar `tests-and-linters.yml` sería un error: es un archivo de upstream, y
`sync-upstream.yml` descarta a propósito todo `.github/workflows/` que venga de upstream (porque el
`GITHUB_TOKEN` tiene prohibido empujar cambios ahí). Un archivo con nombre propio tiene **cero
conflictos de merge por definición**.

**Motivo — por qué el PR de sync necesita verificación dentro de su propio job:**

GitHub no dispara workflows con eventos originados por `secrets.GITHUB_TOKEN` (salvaguarda antibucle
documentada; las únicas excepciones son `workflow_dispatch` y `repository_dispatch`). El PR #3
(`sync/upstream-3.22.67`) llegó a revisión humana con **cero** checks: sus seis CheckRuns son todos
`SKIPPED` y con timestamp del evento `closed` al mergear, no de la apertura. Ese sync traía dos CVE.

Se descartó la alternativa del PAT: una credencial de larga vida que caduca en silencio reproduce
exactamente el fallo que se está arreglando —algo que deja de verificar sin avisar— y sería un punto
único de fallo en la cadena de suministro de **todas** las instancias de cliente a la vez.

**Motivo — la línea en blanco de `manage.py`:**

`pre-commit run --all` sobre `stable/3.22` limpio da **`ruff format` en Failed, 1 archivo
reformateado**: `manage.py`, que es un parche local del fork (el `load_dotenv` del 2026-04-29). El
resto está verde. El
parche entró sin pasar por el formateador del propio fork **porque ese formateador nunca ha corrido**,
que es justo lo que arregla este cambio. Tomar el reformateo es lo que evita que `ci-fork.yml` nazca
en rojo por una razón que no tiene nada que ver con lo que vigila.

**Verificación (2026-08-27, sobre `stable/3.22`):**

- `pre-commit run --all` tras el reformateo → **los diez hooks en verde, exit 0**:
  `trailing-whitespace`, `end-of-file-fixer`, `ruff`, `ruff-format`, `mypy`, `deptry`, `semgrep`,
  `uv-lock`, `Check for uncreated migrations` y `Check GraphQL schema is up to date`.
  ⚠️ En la corrida **anterior** al reformateo, `semgrep` salió `Failed — files were modified by this
  hook`. Es un **falso positivo por cascada**: pre-commit le atribuyó la modificación que había dejado
  `ruff-format`. Con el árbol formateado pasa. No perseguirlo.

- `.venv/bin/ruff check .` → `All checks passed!`
- `.venv/bin/python manage.py check` → `System check identified no issues (0 silenced).`
- `.venv/bin/python manage.py makemigrations --check --dry-run` → `No changes detected`, exit 0
- `python -c "import saleor"` → OK, `3.22.67`
- Los cuatro son exactamente los comandos de la puerta rápida, así que la línea base de la puerta
  está medida antes de existir.
- Se comprobó además, apuntando `CACHE_URL` a un puerto muerto, que **la puerta no necesita Redis**:
  `manage.py check` y `makemigrations --check` salen 0 igual. Por eso el job `sync` declara solo
  Postgres.

**Primer run real de `ci-fork.yml`** (`workflow_dispatch` sobre `stable/3.22`,
[run 33126906393](https://github.com/aclicona/licona-saleor/actions/runs/33126906393)) — los tres jobs
en verde:

| Job | Resultado | Duración |
|---|---|---|
| `Puerta rapida` | `success` | 1 min 31 s |
| `Linters (pre-commit)` | `success` | 5 min 34 s |
| `Suite completa (17k tests)` | `success` — **17 265 passed, 2 skipped, 0 failed** | 17 min 40 s |

⚠️ **Dato que corrige la línea base documentada del proyecto:** los **17 fallos "preexistentes"** que
aparecen al correr la suite en macOS local **no existen en Linux CI**. La primera ejecución de esta
suite en CI en toda la vida del fork sale limpia. Los 17 son un artefacto del entorno local, no una
deuda del fork.

**Permisos, explícitos en los dos workflows y a propósito.** `ci-fork.yml` declara
`contents: read` + `actions: write` (lo exige `actions/upload-artifact`), y `sync-upstream.yml` añade
`actions: write` al job `sync` (lo exige `gh workflow run`). Sin declararlos, el scope sale del ajuste
de repo *Workflow permissions*, que **no está versionado** y que GitHub pone en solo lectura para los
repos nuevos desde 2023 — o sea que un repo replicado para un cliente los rompería, y de forma
engañosa: el job `suite` saldría rojo por el `upload-artifact`, no por los tests.

**Conflicto potencial al actualizar upstream:** **ninguno.** `ci-fork.yml` y `sync-upstream.yml` no
existen en upstream, y el propio `sync-upstream.yml` descarta todo `.github/workflows/` que llegue
del merge. La línea en blanco de `manage.py` sí puede conflictuar, pero `manage.py` ya era un archivo
con parche local y ya estaba en la lista de conflictos previsibles.

### 2026-09-01 — Guion de chequeo de migraciones (base: 3.22.67)

**Archivos añadidos:**

- `scripts/check-migrations.sh` — **nuevo, sin equivalente en upstream.** Responde una sola
  pregunta —¿está la base migrada a la altura del código?— y **no muta nada**: nunca corre
  `migrate`. Existe porque `manage.py migrate --check` es mudo (0 bytes en stdout, verde o rojo)
  y solo habla por exit code; el guion genera el mensaje: ante pendientes lista **cuáles**
  (vía `showmigrations --plan`) y el comando exacto para aplicarlas.
  Contrato de salida: **0** = base al día · **1** = hay migraciones pendientes (accionable:
  migrar) · **2** = **no se pudo responder** la pregunta (base inaccesible o inexistente,
  Postgres apagado, entorno Python roto). **2 significa "no sé", no "está mal"**: conflarlo con 1
  llevaría a correr `migrate` contra una base apagada.
  Intérprete configurable con `${PYTHON:-python}` (local recibe `.venv/bin/python`; en la imagen
  vale el del PATH). `sh` POSIX puro, como los otros dos guiones de `scripts/`.

**Motivo:** vive en el fork porque la imagen del fork es el **único artefacto que viaja a todas las
instancias de cliente**. Ahí una sola fuente sirve a sus tres llamadores —`dev.sh` en local, la
sesión nocturna y (cuando el humano lo apruebe) el `preDeployCommand` de Railway— sin adaptarla.
El caso que lo motiva está medido: el 2026-08-28 la API local devolvió HTTP 500 en todo GraphQL
porque el sync a 3.22.67 trajo migraciones y nadie migró la base local.

**Conflicto potencial al actualizar upstream:** **ninguno.** El archivo no existe en upstream, así
que no hay nada del otro lado con qué chocar. En un re-fork limpio se copia con el resto de
`scripts/`.

### 2026-09-03 — Guion de fidelidad del esquema GraphQL y `push` en la CI (base: 3.22.67)

**Archivos añadidos:**

- `scripts/check-schema-fidelity.sh` — **nuevo, sin equivalente en upstream.** Hermano de
  `check-migrations.sh`: mismo tipo de pregunta (¿el artefacto derivado y commiteado sigue
  sincronizado con el código?), mismo contrato de salida, mismo compromiso de no mutar nada.
  Responde si `saleor/graphql/schema.graphql` es byte a byte lo que emite
  `manage.py get_graphql_schema`. **Nunca escribe sobre el esquema**: genera a un temporal
  (`mktemp -d`, fuera del repo, borrado con `trap`).
  Contrato de salida: **0** = fiel · **1** = deriva real (accionable: regenerar, y el guion
  imprime el comando exacto) · **2** = **no se pudo responder** (entorno Python roto,
  `manage.py` caído, Postgres apagado, salida vacía o que no parece un SDL).
  **La distinción 1/2 es la razón de ser del guion.** El comando de la comprobación —
  `manage.py get_graphql_schema | diff saleor/graphql/schema.graphql -` — falla de forma
  engañosa: si `manage.py` muere, su stdout sale **vacío** y `diff` reporta las ~38 000 líneas
  del archivo como diferentes. Eso parece deriva catastrófica y en realidad es "no pude
  preguntar". Por eso el guion valida el **exit code**, que la salida **no esté vacía** y que
  **empiece por `schema {`** ANTES de mirar el diff.
  Intérprete configurable con `${PYTHON:-python}`, `sh` POSIX puro, funciona desde cualquier
  cwd (resuelve la raíz desde `$0`) — las mismas convenciones que `check-migrations.sh`.

**Archivos modificados:**

- `.github/workflows/ci-fork.yml` — tres cambios:
  1. Trigger `push: branches: ['stable/*']` nuevo.
  2. Paso nuevo en `puerta`: `uv run sh scripts/check-schema-fidelity.sh`, colocado junto a
     `No faltan migraciones`, que es su hermano conceptual.
  3. `github.event_name != 'push' &&` antepuesto a los `if:` de `linters` y `suite`, con el
     segundo término entre paréntesis.

**Motivo — por qué el invariante no estaba vigilado en ningún sitio:**

`saleor/graphql/schema.graphql` está commiteado en el fork y **el storefront Nuxt vendoriza esa
copia** para generar sus tipos TypeScript. Si un parche local toca la capa GraphQL y nadie
regenera, el archivo miente aquí y la mentira se descubre allá: en otro repo, días después.
Medido el 2026-09-03, el enforcement era **cero en el camino que se usa**:

| Vía | Estado medido |
|---|---|
| Hook `gql-schema-check` de `.pre-commit-config.yaml` | Declarado, pero **`.git/hooks/` solo tiene los `.sample`**: `pre-commit install` nunca se corrió. No se dispara en ningún commit local. |
| `ci-fork.yml` | Disparaba solo en `pull_request` sobre `stable/*` y `workflow_dispatch`. **Sin trigger `push`.** |
| Despliegue real | **Push directo a `stable/3.22`, sin PR.** |

O sea: el único camino que se usa no pasaba por ninguna de las dos comprobaciones.

**Motivo — por qué el check entra en `puerta` y no en `linters`:**

`puerta` es el job que corre siempre, y el check de esquema es de la **misma clase** que
`makemigrations --check`: artefacto derivado desincronizado del código. `linters` corre
`pre-commit run --all` **entero** —mypy, semgrep, deptry, ~20 min de runner— para un resultado
que cuesta **9,5 s** (medido en local, ver abajo); y además `linters` no corre en `push`, que es
justo el camino a cubrir. `suite` tampoco entra en `push`: 60 min de runner que no gatean nada,
porque **Railway despliega el commit en paralelo sin esperar a la CI**.

**El gotcha de las condiciones, y por qué había que tocarlas.** Los `if:` antiguos eran
`${{ github.event_name != 'workflow_dispatch' || inputs.alcance != 'rapido' }}`, que evalúa
**TRUE en `push`** (no es dispatch → la `or` corta en true). Añadir el trigger sin tocarlos
habría puesto los **tres** jobs a correr en cada push — 20 min de linters y 60 de suite por
commit, exactamente lo contrario de lo que se busca. Los paréntesis del segundo término tampoco
son decorativos: en las expresiones de GitHub `&&` liga más fuerte que `||`, así que sin ellos
la condición sería `(A && B) || C` y volvería a dar true en un dispatch `rapido`.

**Qué es y qué NO es este trigger, dicho sin adornos.** En `push`, `puerta` es una **alarma
post-hoc, no un gate**. Railway no espera a la CI: cuando el job termina, la versión mala ya está
arriba. Lo que aporta es la X roja en el commit y el correo al autor — que alguien se entere en
minutos en vez de en el próximo `npm run codegen` del storefront. Un gate de verdad exigiría rama
protegida y PR obligatorio; esa es otra decisión, con otro coste de flujo, y no se toma aquí.

**Política de fallo, deliberadamente distinta por capa.** En CI, exit 1 y exit 2 fallan los dos:
un "no sé" en CI es rojo (falla cerrado). Un llamador que deba **callar** ante el 2 —la sesión
nocturna, por ejemplo— tiene que distinguirlo, y por eso el guion no colapsa los dos códigos.

**Verificación (2026-09-03, sobre el worktree `hardening/gate-esquema-1.43`):**

- Los tres códigos de salida, medidos de verdad:

| Caso | Cómo se forzó | Resultado |
|---|---|---|
| Esquema fiel | tal cual, e invocado desde `/` para probar la independencia del cwd | **exit 0** |
| Deriva real | copia del esquema con una línea borrada y cuatro añadidas, restaurada después | **exit 1**, `+1 línea(s) que faltan · -5 línea(s) que sobran` + comando de regeneración |
| Intérprete que muere | `PYTHON=/usr/bin/false` (existe, ejecutable, sale 1, stdout vacío) | **exit 2**, no 1 |
| Python real sin dependencias | `PYTHON=/usr/bin/python3` | **exit 2**, `Línea reveladora: ModuleNotFoundError: No module named 'dotenv'` |
| Intérprete mudo que sale 0 | `PYTHON=/usr/bin/true` | **exit 2**, `salió 0 pero no imprimió nada` |
| Intérprete inexistente | `PYTHON=/no/existe/python` | **exit 2** |

  Tras el caso de deriva, el `sha256` del esquema volvió a ser idéntico al de partida
  (`b4070edb…`) y `git status` quedó limpio: el guion **no escribió** sobre el archivo en ningún
  momento; la deriva la fabricó el test, no el guion.

- Coste: **9,48 s** (`time`, en local). Es lo que se le añade a `puerta`.
- `sh -n scripts/check-schema-fidelity.sh` → sintaxis OK. `shellcheck` **no está instalado** en la
  máquina; el guion no pasó por él.
- `python3 -c "import yaml; yaml.safe_load(...)"` sobre `ci-fork.yml` → válido; los triggers
  quedan `['push', 'pull_request', 'workflow_dispatch']` y `puerta` sigue **sin `if:`**.
  `actionlint` **no está instalado**; la validación es de YAML, no de la semántica de Actions.
- Tabla de verdad de los `if:` de `linters` y `suite`, con
  `A = event_name != 'push'` y `B = event_name != 'workflow_dispatch'`, `C = inputs.alcance != 'rapido'`:

| Evento | A | B | C | `A && (B \|\| C)` | Jobs que corren |
|---|---|---|---|---|---|
| `push` sobre `stable/*` | false | true | true | **false** | solo `puerta` |
| `pull_request` | true | true | true (`inputs` vacío) | **true** | los tres |
| `workflow_dispatch` `alcance: completo` | true | false | true | **true** | los tres |
| `workflow_dispatch` `alcance: rapido` | true | false | false | **false** | solo `puerta` |

- **Verificado en GitHub el 2026-09-03**, no solo razonado sobre el YAML. Push de `5d27391e` a
  `stable/3.22` a las 19:21 → run
  [33821463025](https://github.com/aclicona/licona-saleor/actions/runs/33821463025), evento `push`:
  `Puerta rapida` **success**, `Linters (pre-commit)` **skipped**, `Suite completa` **skipped** —
  exactamente la fila `push` de la tabla de arriba. El paso nuevo salió
  `[check-schema-fidelity] El esquema commiteado es fiel al código`, en **~10 s** (00:23:05 →
  00:23:15 UTC).
- **Y de paso quedó medido el agujero que el trigger `push` viene a tapar:** los dos PR abiertos del
  repo —#4 (sync 3.22.68) y #5 (bump de dependencias)— tienen runs de `ci-fork.yml` en estado
  `action_required` con **0 s y CERO jobs ejecutados**. Es el gotcha ya documentado (un PR abierto
  con `secrets.GITHUB_TOKEN` no dispara workflows), pero su consecuencia no se había medido: el job
  `linters` —el único que corría `pre-commit run --all` y con él `gql-schema-check`— **solo se ha
  ejecutado dos veces en la vida del repo**, ambas por `workflow_dispatch` manual el 2026-08-27.

- **`AGENTS.md` (= `CLAUDE.md`, que es un symlink a él) — corregida una ruta que causaba justo
  este defecto.** La sección "Comandos clave" decía
  `python manage.py get_graphql_schema > schema.graphql`: ruta equivocada. Seguirla crea un
  `schema.graphql` huérfano en la raíz del repo y deja **sin regenerar** el archivo versionado
  de verdad, `saleor/graphql/schema.graphql` — es decir, la documentación del propio fork
  describía el camino más corto para producir la deriva que este guion viene a detectar. Ahora
  apunta a la ruta correcta y remite a `scripts/check-schema-fidelity.sh`.
  **Deuda de merge: ninguna adicional.** `AGENTS.md` ya está listado más abajo como
  "reemplazamos el de upstream entero", resuelto automáticamente vía `merge=ours` en
  `.gitattributes`.

**Conflicto potencial al actualizar upstream: ninguno.** Los **dos** archivos son propios del
fork: `scripts/check-schema-fidelity.sh` no existe en upstream, y `ci-fork.yml` tampoco (y
`sync-upstream.yml` descarta a propósito todo `.github/workflows/` que llegue del merge). Cero
deuda de merge por definición: no hay nada del otro lado con qué chocar.

### 2026-09-03 — Retirada de dos workflows en rojo crónico (base: 3.22.67)

**Archivos eliminados:**

- `.github/workflows/build-image.yml` — **propio del fork, creado el 2026-04-16.** Construía y
  empujaba `ghcr.io/aclicona/licona-saleor` en cada push y PR sobre `stable/3.22`.
  **Nunca tuvo un run verde: 0 éxitos en 36 runs**, desde su primer día hasta hoy. La causa es una
  línea que falta, no una que sobre: el workflow pide `cache-to: type=gha` a
  `docker/build-push-action@v5` sin haber corrido antes `docker/setup-buildx-action@v3`, así que
  el build usa el driver `docker` por defecto y muere siempre con
  `ERROR: failed to build: Cache export is not supported for the docker driver.`
- `.github/workflows/test-env-cleanup-cron.yml` — **heredado de upstream.** Cron diario (`0 2 * * *`
  UTC) que asume un lambda `test-env-manager` y una cuenta AWS de entornos de test de Saleor Inc.
  Nosotros no tenemos ni el lambda ni la cuenta ni los secretos (`AWS_TESTENVS_ACCOUNT_ID`,
  `AWS_TESTENVS_CICD_ROLE_NAME`), así que muere en el primer paso.
  **12 de 12 runs en rojo.** Nótese que es el *cron*: `test-env-cleanup.yml` (el disparado por
  evento de PR) se queda, porque sin `schedule` no se ejecuta solo.

**Por qué borrar y no arreglar `build-image.yml` — lo medido, no lo opinado:**

| Pregunta | Medición del 2026-09-03 |
|---|---|
| ¿Existe la imagen? | `gh api /users/aclicona/packages/container/licona-saleor/versions` → **`404 Package not found`**. Nunca se publicó ni una versión. |
| ¿Quién la consume? | `grep -rn "ghcr.io/aclicona/licona-saleor"` sobre los **tres** repos y todas las docs → **cero coincidencias**. |
| ¿La usa Railway? | No. `railway.json` declara `"builder": "DOCKERFILE"`: Railway construye desde el fuente. |
| ¿La usa el escaneo? | No. `security-scan.yml:20` hace `docker build -t licona-saleor:scan .` en local; no lee GHCR. |

Un artefacto que nunca existió y que nadie lee no es una pieza rota: es una pieza que no está en
el sistema. **El artefacto de replicabilidad real de este fork es el `Dockerfile` versionado +
`uv.lock` + el SHA de `stable/3.22`**, que es lo que Railway construye. Arreglar el workflow
habría añadido un segundo camino de build —con su propia caché, su propio drift y su propia
superficie de mantenimiento— para producir bits que nadie iba a descargar.

**Por qué corría prisa, y no era estética.** `build-image.yml` disparaba en `push` a `stable/3.22`,
o sea en la **misma lista de checks del commit** que el guardarraíl `puerta` de `ci-fork.yml`
instalado hoy. Medido sobre el HEAD `30e235659e`: `Puerta rapida: success`, `trivy: success`,
`build: failure` → **estado agregado del commit = `failure`**. El guardarraíl recién puesto nacía
ya dentro de una X roja permanente, que es la forma más rápida de enseñarle a un equipo que las X
rojas de este repo no significan nada.

**Regla general que esto fija, aplicable a todo el fork:**

> **Lo que no está en el árbol no existe para la instancia N+1.** Se borra en el árbol, **nunca**
> con `gh workflow disable` ni desde la UI de Actions.

El modelo de negocio es single-tenant replicable: cada cliente es un clone. El estado de "disabled"
de un workflow vive en la base de datos de GitHub del repo original y **no se clona**; el archivo
sí. Deshabilitar por UI produce una instancia N+1 que arranca con el cron rojo del día uno y con
un humano preguntándose por qué "en el repo de referencia no salía".

**Archivos modificados:**

- `.github/workflows/sync-upstream.yml` — el reset de `.github/workflows/` pasa a ser una
  restauración **completa** del directorio:

  ```sh
  rm -rf .github/workflows
  if ! git checkout "$BASE_SHA" -- .github/workflows/; then
    echo "::error::No se pudo restaurar .github/workflows/ desde $BASE_SHA."
    exit 1
  fi
  ```

  **Motivo:** `git checkout <sha> -- <dir>` **restaura** lo que existe en `<sha>` pero **no elimina**
  lo que el merge haya dejado en el índice y `<sha>` no tenga. El comentario del propio archivo ya
  daba por hecho que descartaba "los workflows de upstream" en bloque; no era cierto. El defecto ya
  existía —bastaba con que upstream añadiera un workflow para que el push muriera con el error de
  permiso `workflows` que ese mismo comentario documenta—, y borrar archivos del fork lo amplía:
  upstream **sigue teniendo** `test-env-cleanup-cron.yml`, así que cada merge semanal lo
  re-añadiría y el `checkout` no lo quitaría. El `git add -A` que ya estaba tres líneas más abajo
  estagea las eliminaciones sin cambio adicional.

  **Por qué el `if !` en vez del `|| true` heredado:** el paso corre con `set -uo pipefail`, **sin
  `-e`**. Con `rm -rf` delante, un `|| true` convertiría un `checkout` fallido en "borra los 24
  workflows y ábrelo como PR de sync". Se comprueba a mano y se sale con 1: falla cerrado.

- `UPGRADE_NOTES.md` — la línea de "Archivos creados" del 2026-04-16 documentaba `build-image.yml`
  como pieza activa; ahora dice que se retiró y apunta aquí. La receta de salto de minor (3.22 →
  3.23) mandaba "apuntar `build-image.yml` y `sync-upstream.yml` a `stable/3.23`": era una
  instrucción hacia un archivo que ya no existe.

**Receta literal de reintroducción**, si algún día hace falta publicar imagen. Lo que faltaba era
un paso, en este orden, antes del `build-push-action`:

```yaml
      - name: Set up Buildx
        uses: docker/setup-buildx-action@v3
```

Sin él, el driver por defecto es `docker`, que no implementa export de caché; con él se levanta el
driver `docker-container`, que sí. Es la línea que habría bastado, y es exactamente la razón por la
que borrarlo no es "renunciar a algo difícil".

**Condiciones que tendrían que cumplirse para que valga la pena volver a añadirlo** — ninguna se
cumple hoy, y por eso no se añade:

1. **Varias instancias que deban recibir bits idénticos** sin reconstruir cada una. Hoy hay una
   instancia y Railway reconstruye; con N clientes, N builds de la misma imagen es desperdicio y,
   peor, N oportunidades de que los bits difieran.
2. **El build de Railway convertido en cuello de botella** (tiempo de despliegue o minutos de
   build) de forma medida, no supuesta.
3. **Necesidad de rollback a una imagen pinneada** por digest que el historial de despliegues de
   Railway no cubra.

Si se reintroduce: el workflow vuelve **al árbol** (no se rehabilita nada por UI), se le añade el
`setup-buildx-action`, y **se verifica que el package existe en GHCR** antes de anotarlo aquí como
pieza activa — que es precisamente el paso que no se dio en abril.

**Conflicto potencial al actualizar upstream:** **ninguno, por construcción.**
`build-image.yml` es propio del fork y `sync-upstream.yml` también.
`test-env-cleanup-cron.yml` **sí** existe en upstream y el merge semanal lo re-añadiría — es
justo el caso que cubre el `rm -rf` de arriba, que lo vuelve a borrar en cada sync sin
intervención humana. Coste de sync recurrente: **cero**, y por la misma razón de siempre:
`.github/workflows/` del fork no sigue a upstream (decisión del 2026-08-22).

---

## Pendiente de upstream

| Tema | Estado a fecha 3.22.67 |
|---|---|
| Fix de `discount.0052` para PostgreSQL 15+ | **Upstream sigue sin arreglarlo.** Verificado el 2026-08-24: `git diff 3.22.48 3.22.67 -- saleor/discount/` sale vacío y nuestro parche difiere de ambos tags en las mismas 7/−3 líneas. Nuestro parche sigue siendo necesario — no volver a auditarlo desde cero en el próximo sync, mirar solo si ese diff deja de estar vacío. |

## Deuda del fork

| Tema | Detalle |
|---|---|
| — | Sin deuda abierta. (`python-dotenv` transitivo: **resuelto el 2026-08-22**.) |

---

## Historial de actualizaciones de upstream

| Fecha | De | A | PR | Notas |
|---|---|---|---|---|
| 2026-04-16 | — | 3.22.48 | — | Versión base inicial del fork |
| 2026-08-24 | 3.22.48 | 3.22.67 | [#3](https://github.com/aclicona/licona-saleor/pull/3) | 19 parches. **Dos CVE**: 2026-48744 (bypass de autorización) y 2026-44472 (secuestro de fusión de cuentas). Único conflicto `uv.lock`, regenerado. 3 migraciones, ninguna destructiva. Cero breaking changes de GraphQL. Ver [bitácora](../docs/hardening/sessions/2026-08-24-sync-upstream-3.22.67.md) |

---

## Cambios de comportamiento heredados de upstream (no son parches nuestros)

Un sync no solo trae fixes: trae **cambios de comportamiento que nadie pidió**. Estos son
los del rango `3.22.48 → 3.22.67`, auditados el 2026-08-24. Ninguno rompe hoy, pero los
tres cambian lo que la API hace.

| Cambio | Qué cambia | ¿Nos toca hoy? |
|---|---|---|
| **`accountConfirmMergeMode`** (fix de CVE-2026-44472, migración `site.0041`) | El campo nace en `merge_disabled`, así que `confirmAccount` **deja de asociar** a la cuenta los pedidos y gift cards hechos como invitado. Antes lo hacía siempre — que era justo el CVE. | **No.** El storefront no usa `confirmAccount` en ninguna parte: la auth de clientes es la Fase 4. **Pero cuando la Fase 4 llegue, el default habrá cambiado en silencio.** Ver el ítem del backlog y el ruling de Fable en la bitácora del 2026-08-24. |
| **Desempate de cursores** (`saleor/graphql/utils/sorting.py`) | Los cursores de paginación ganan un componente `pk`. Los cursores emitidos **antes** del deploy se rechazan con `Received cursor is invalid.` | **No.** Verificado: el storefront pasa `after: null` y solo usa `endCursor` dentro de la misma sesión (`app/pages/categoria/[slug].vue:69`, `all.vue:64`). No persiste cursores en URL ni en `localStorage`. |
| **Filtros de atributos** | `products`/`pages` dejan de matchear valores de atributos **desasignados** del product type. Un filtro que devolvía N productos puede devolver menos. | **No.** El storefront no filtra por atributos: sus dos queries (`products.graphql`, `categories.graphql`) no usan `attributes:`. |

⚠️ El default de `account_confirm_merge_mode` lo calcula la migración `0041` **en tiempo
de migración**, a partir de `settings.ACCOUNT_CONFIRM_ASSOCIATE_ANONYMOUS_OBJECTS`. Sobre
una instancia ya migrada, cambiar ese setting es un **no-op**: el único mecanismo que
funciona es la mutación `shopSettingsUpdate(accountConfirmMergeMode: ...)`.

---

## Cuánto divergimos de upstream — medido, no estimado

Esto es lo que hace manejable cada actualización, y conviene volver a medirlo antes de
cada upgrade (`git diff --numstat <tag-base> stable/3.22`):

**Remedición del 2026-08-24, contra `3.22.67` (tras el sync): la divergencia NO creció.
Siguen siendo ~20 líneas de código de Saleor, exactamente las mismas.**

| Archivo | Líneas | Qué es |
|---|---|---|
| `manage.py` | +3 | `load_dotenv()` |
| `saleor/asgi/__init__.py` | +4 | `load_dotenv()` |
| `saleor/celeryconf.py` | +3 | `load_dotenv()` |
| `pyproject.toml` | +1 | `python-dotenv` como dependencia directa |
| `saleor/discount/migrations/0052_drop_sales_constraints.py` | +7 −3 | fix PostgreSQL 15+ |
| `uv.lock` | +2 | consecuencia de la anterior |
| `Dockerfile` | +16 −2 | `netcat-openbsd` + `ENTRYPOINT` de Railway |

Que la divergencia **no crezca** tras absorber 19 parches es el dato que importa: es lo
que mantiene viva la estrategia A (re-fork limpio) para el salto a 3.23. Medido con
`git diff --stat 3.22.67 stable/3.22 -- . ':!.github' ':!AGENTS.md'` — todo lo demás son
archivos que upstream no tiene.

Todo lo demás son **archivos que upstream no tiene** —`railway.json`,
`scripts/railway-entrypoint.sh`, `scripts/wait-for-db.sh`, `scripts/check-migrations.sh`,
`scripts/check-schema-fidelity.sh`,
este archivo, nuestros tres workflows, `docs/superpowers/`— y **no pueden conflictuar**:
no hay nada del otro lado con qué chocar.

**El producto no vive en este repo.** `storefront` y `saleor-apps` hablan con Saleor por
GraphQL, no por sus internals. Por eso el riesgo de un upgrade está en **el esquema
GraphQL**, no en este fork.

### Los tres conflictos previsibles

| Archivo | Por qué | Cómo se resuelve |
|---|---|---|
| `AGENTS.md` | Reemplazamos el de upstream entero | **Automático** vía `merge=ours` en `.gitattributes` — requiere `git config merge.ours.driver true` (ver abajo) |
| `uv.lock` | Upstream lo marca `-merge`: siempre conflictúa, a propósito | **Regenerar**, no resolver, y **partiendo del lock de upstream** (`git checkout <tag> -- uv.lock`) para heredar sus versiones: `uv tool run uv@<version-que-pinea-el-Dockerfile> lock` |
| `0052_drop_sales_constraints.py` | Único cambio nuestro con lógica propia | **Revisar a mano** si upstream tocó esa migración. Es el único que merece atención real |

---

## Cómo hacer una actualización

### Requisito de una sola vez, en cada clone nuevo

```sh
git config merge.ours.driver true
```

Sin esto, el `merge=ours` que `.gitattributes` declara para `AGENTS.md` **no hace nada**
y el archivo conflictúa en cada sync. El driver `ours` no viene definido en git y la
config no se versiona. `sync-upstream.yml` lo ejecuta solo; los clones locales no.

### Parche dentro de la minor actual (3.22.x → 3.22.y)

1. `sync-upstream.yml` abre el PR cada lunes 9:00 UTC. Si viene con conflictos llega
   como **draft** y con el título `⚠️ CON CONFLICTOS`; los marcadores están commiteados
   a propósito, para que el PR sea revisable.
2. Resolver sobre la rama del PR: `uv.lock` regenerándolo, el resto a mano.
3. Revisar la sección "Cambios aplicados" de este archivo: es la lista de sitios donde
   nuestro código y el de upstream pueden pisarse.
4. Migraciones **contra una copia de la BD**, no solo la suite.
5. `npm run codegen` en el storefront: si el esquema GraphQL cambió, TypeScript lo dice.
6. Sacar el PR de draft y mergear a `stable/3.22`.
7. Anotar la versión nueva en el historial de abajo.

### Salto de minor (3.22 → 3.23)

**Primero hay que estar al día dentro de la minor actual.** No se salta desde un punto
atrasado: se resuelve el sync de parches, se verifica, y recién ahí se sube de minor.

Dos estrategias, y la divergencia medida arriba decide cuál:

**A · Re-fork limpio (recomendada mientras la divergencia siga siendo de ~20 líneas)**

1. Rama `stable/3.23` desde el tag `3.23.x` estable más reciente.
2. Reaplicar los cambios de la sección "Cambios aplicados" — son pocos y están listados.
3. Copiar los archivos que upstream no tiene (`railway.json`, `scripts/`, workflows,
   este archivo).
4. Migraciones contra copia de la BD + `npm run codegen` en el storefront.

Ventaja: el árbol queda idéntico a upstream salvo lo nuestro, sin arrastrar historia de
merges. Desventaja: reaplicar a mano, y hay que acordarse de todo — por eso la sección
"Cambios aplicados" es obligatoria de mantener.

**B · Merge del tag de la minor nueva**

`git merge refs/tags/3.23.x` sobre `stable/3.22`. Preserva la historia y git hace el
grueso del trabajo, pero arrastra un merge grande. Preferible **si algún día la
divergencia crece** y reaplicar a mano deja de ser realista.

**Cierre del salto, con cualquiera de las dos:**

1. Actualizar `version` en `pyproject.toml`.
2. Apuntar `sync-upstream.yml` a `stable/3.23` (los `ref:` de los checkouts y el
   `--base` del PR). `ci-fork.yml` no hay que tocarlo: dispara sobre `stable/*`.
   (Aquí figuraba también `build-image.yml`; se retiró del árbol el 2026-09-03.)
3. ⚠️ **Cambiar la rama por defecto del repo a `stable/3.23`.**
   ```sh
   gh repo edit aclicona/licona-saleor --default-branch stable/3.23
   ```
   **No es cosmético.** `schedule` de GitHub Actions solo dispara desde la rama por
   defecto: si se olvida, el sync deja de correr **sin ningún aviso**. Es exactamente lo
   que pasó entre abril y agosto de 2026 — cuatro meses sin sincronizar, descubiertos
   por casualidad.
4. Cerrar el issue de `upstream-minor` correspondiente.
