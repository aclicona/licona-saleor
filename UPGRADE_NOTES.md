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

**Conflicto potencial al actualizar upstream:** bajo. Son adiciones en zonas estables de los tres
archivos; un cambio de upstream en las mismas líneas es improbable pero revisable.

**Archivos modificados (higiene):**

- `.gitignore` — añadido `celerybeat-schedule*` (estado local de Celery beat, se regenera).

---

## Pendiente de upstream

Ninguno.

## Deuda del fork

| Tema | Detalle |
|---|---|
| `python-dotenv` transitivo | Declararlo directo en `pyproject.toml` — ver nota del 2026-04-29 |

---

## Historial de actualizaciones de upstream

| Fecha | De | A | PR | Notas |
|---|---|---|---|---|
| 2026-04-16 | — | 3.22.48 | — | Versión base inicial del fork |

---

## Cómo hacer una actualización

1. El workflow `sync-upstream.yml` abre un PR automático cada lunes con el latest patch de la minor actual.
2. Revisar el PR: verificar que no haya conflictos en `Dockerfile` ni en `scripts/`.
3. Hacer merge del PR a `stable/3.22`.
4. Verificar en staging que las migraciones corren sin errores.
5. Actualizar la tabla de arriba con la nueva versión.

Para saltar de minor (ej. 3.22 → 3.23):
1. Crear rama `stable/3.23` desde el tag `3.23.x` más reciente.
2. Aplicar manualmente los cambios de esta lista a la nueva rama.
3. Correr `python manage.py migrate` en staging y verificar que no haya errores.
4. Actualizar `build-image.yml` y `sync-upstream.yml` para apuntar a `stable/3.23`.
