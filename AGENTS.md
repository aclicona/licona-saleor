# saleor-api

Fork de [Saleor 3.22](https://github.com/saleor/saleor) — backend GraphQL del e-commerce colombiano. Python 3.12, Django, Celery, Gunicorn + Uvicorn workers. Sirve la API GraphQL que consume el storefront y las saleor-apps.

**Contexto de proyecto completo:** `../CLAUDE.md` (o abre `ecommerce/` en Claude Code).

---

## Local Dev

**Prereqs:** Python 3.12, Postgres nativo corriendo, Redis nativo corriendo.

```bash
# Primera vez
cd ecommerce/saleor-api
python -m venv .venv
source .venv/bin/activate
pip install -e ".[dev]"
python manage.py migrate
python manage.py collectstatic --noinput

# Arrancar API
python manage.py runserver 0.0.0.0:8000

# Arrancar worker Celery (terminal separada)
source .venv/bin/activate
celery -A saleor worker -E --concurrency=2 --loglevel=info

# Arrancar beat (terminal separada, solo si necesitas tareas programadas)
source .venv/bin/activate
celery -A saleor beat --loglevel=info
```

La API queda disponible en `http://localhost:8000/graphql/`.
El Playground de GraphQL está en `http://localhost:8000/graphql/` (con DEBUG=True).

---

## Variables de entorno

Ver `.env.example` para la lista completa con comentarios.
Copiar a `.env` y completar los valores marcados como requeridos.

**Variables críticas para arrancar:**
- `DATABASE_URL` — conexión a Postgres local
- `REDIS_URL` — cache y channel layers
- `CELERY_BROKER_URL` — broker para worker/beat
- `RSA_PRIVATE_KEY` — firma JWT (generar con `openssl genrsa 2048`, pegar el PEM completo)
- `SECRET_KEY` — clave Django (si no se setea en DEBUG=True, Saleor genera una temporal con warning)

---

## Comandos clave

```bash
# Migraciones
python manage.py migrate
python manage.py makemigrations   # solo si cambias modelos del fork

# Crear superusuario para el Dashboard
python manage.py createsuperuser

# Tests
pytest saleor/ -x -q

# Regenerar el esquema GraphQL commiteado (si tocas la capa GraphQL).
# OJO con la ruta: el archivo versionado es saleor/graphql/schema.graphql.
# Escribirlo en la raiz deja un huerfano y el bueno sin regenerar -- y el
# storefront vendoriza el bueno para generar sus tipos contra el.
# Comprobar el invariante: scripts/check-schema-fidelity.sh
python manage.py get_graphql_schema > saleor/graphql/schema.graphql
```

---

## Regla de upstream sync

**CRÍTICO:** Saleor solo garantiza migraciones sin downtime entre minors consecutivos.
- Para ir de 3.19 → 3.21 hay que pasar por 3.20.
- El workflow `sync-upstream.yml` abre un PR semanal cuando detecta un nuevo tag estable.
- Todos los cambios locales al fork deben documentarse en `UPGRADE_NOTES.md`.

---

## Qué provee a los otros repos

| Consumer | URL |
|---|---|
| storefront | `http://localhost:8000/graphql/` |
| saleor-apps | `http://localhost:8000/graphql/` |
| Dashboard | `http://localhost:8000/` |

---

## Stack

- Python 3.12, Django 4.x, Graphene (GraphQL)
- Celery + Redis (async tasks, cache)
- Gunicorn + Uvicorn workers (producción) / `runserver` (local)
- Postgres 16 (DB principal)
- `dj-database-url`, `dj-email-url`, `django-cache-url`
