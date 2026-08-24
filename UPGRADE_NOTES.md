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
`scripts/railway-entrypoint.sh`, `scripts/wait-for-db.sh`, este archivo, nuestros tres
workflows, `docs/superpowers/`— y **no pueden conflictuar**: no hay nada del otro lado
con qué chocar.

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
2. Apuntar `build-image.yml` y `sync-upstream.yml` a `stable/3.23` (los `ref:` de los
   checkouts y el `--base` del PR).
3. ⚠️ **Cambiar la rama por defecto del repo a `stable/3.23`.**
   ```sh
   gh repo edit aclicona/licona-saleor --default-branch stable/3.23
   ```
   **No es cosmético.** `schedule` de GitHub Actions solo dispara desde la rama por
   defecto: si se olvida, el sync deja de correr **sin ningún aviso**. Es exactamente lo
   que pasó entre abril y agosto de 2026 — cuatro meses sin sincronizar, descubiertos
   por casualidad.
4. Cerrar el issue de `upstream-minor` correspondiente.
