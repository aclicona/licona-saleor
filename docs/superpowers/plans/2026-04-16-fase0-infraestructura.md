# Fase 0 — Infraestructura: Fork Saleor + Railway

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tener Saleor Core + Dashboard corriendo en Railway con Postgres y Redis, accesibles por dominios propios, con el fork configurado para sincronización automática con upstream.

**Architecture:** Fork de `saleor/saleor` en GitHub con workflows de CI/CD. Proyecto Railway con servicios separados para API, worker Celery, beat y dashboard. Postgres 16 y Redis 7 como addons de Railway. Storage de media en Cloudflare R2.

**Tech Stack:** Python 3.12, Django, Saleor 3.22.x, Celery, Postgres 16, Redis 7, Docker, GitHub Actions, Railway CLI, Cloudflare R2.

**Estado:** 🔲 Pendiente

---

## Mapa de archivos

```
licona-saleor/                          # Fork de saleor/saleor (repo nuevo en GitHub)
├── Dockerfile                          # Ajustado para Railway (MODIFY del original)
├── railway.json                        # Config de servicios Railway (CREATE)
├── .env.railway.example                # Ejemplo de variables de entorno (CREATE)
├── scripts/
│   ├── railway-entrypoint.sh           # Entrypoint que corre migraciones + gunicorn (CREATE)
│   └── wait-for-db.sh                  # Espera a que Postgres esté listo (CREATE)
├── UPGRADE_NOTES.md                    # Bitácora de cambios locales vs upstream (CREATE)
└── .github/
    └── workflows/
        ├── sync-upstream.yml           # Sync semanal con saleor/saleor (CREATE)
        ├── build-image.yml             # Build + push a GHCR en cada push a main (CREATE)
        └── security-scan.yml          # Trivy scan de la imagen (CREATE)
```

---

## Task 1: Crear el fork de Saleor en GitHub

**Files:**
- Crea: repositorio `licona-saleor` en tu cuenta de GitHub

- [ ] **Step 1: Fork en GitHub**

Ve a https://github.com/saleor/saleor y haz clic en **Fork**. Nombre del fork: `licona-saleor`. Desmarca "Copy the `main` branch only" para traer todas las ramas.

- [ ] **Step 2: Clonar el fork localmente**

```bash
git clone https://github.com/<tu-usuario>/licona-saleor.git
cd licona-saleor
```

- [ ] **Step 3: Configurar el remote upstream**

```bash
git remote add upstream https://github.com/saleor/saleor.git
git remote -v
```

Salida esperada:
```
origin    https://github.com/<tu-usuario>/licona-saleor.git (fetch)
origin    https://github.com/<tu-usuario>/licona-saleor.git (push)
upstream  https://github.com/saleor/saleor.git (fetch)
upstream  https://github.com/saleor/saleor.git (push)
```

- [ ] **Step 4: Verificar la versión base**

```bash
grep -r "^version" pyproject.toml | head -3
git log --oneline -5
```

Debe mostrar commits recientes de Saleor 3.22.x.

- [ ] **Step 5: Crear rama de trabajo para personalizaciones Railway**

```bash
git checkout -b railway/setup
```

- [ ] **Step 6: Commit vacío para marcar el inicio**

```bash
git commit --allow-empty -m "chore: start Railway customizations on top of Saleor 3.22"
git push origin railway/setup
```

---

## Task 2: Crear scripts de entrypoint para Railway

**Files:**
- Create: `scripts/railway-entrypoint.sh`
- Create: `scripts/wait-for-db.sh`

- [ ] **Step 1: Crear `scripts/wait-for-db.sh`**

```bash
cat > scripts/wait-for-db.sh << 'EOF'
#!/bin/sh
# Espera a que Postgres acepte conexiones antes de continuar.
set -e

HOST=$(echo $DATABASE_URL | sed 's|.*@\([^:]*\).*|\1|')
PORT=$(echo $DATABASE_URL | sed 's|.*:\([0-9]*\)/.*|\1|')

echo "Waiting for PostgreSQL at $HOST:$PORT..."
until nc -z "$HOST" "$PORT"; do
  sleep 1
done
echo "PostgreSQL is ready."
EOF
chmod +x scripts/wait-for-db.sh
```

- [ ] **Step 2: Crear `scripts/railway-entrypoint.sh`**

```bash
cat > scripts/railway-entrypoint.sh << 'EOF'
#!/bin/sh
set -e

# Esperar a que la DB esté lista
sh /app/scripts/wait-for-db.sh

# Ejecutar migraciones (idempotente)
python manage.py migrate --noinput

# Crear superusuario si no existe (solo en primer deploy)
if [ "$CREATE_SUPERUSER" = "true" ]; then
  python manage.py shell -c "
from django.contrib.auth import get_user_model
User = get_user_model()
if not User.objects.filter(email='$DJANGO_SUPERUSER_EMAIL').exists():
    User.objects.create_superuser('$DJANGO_SUPERUSER_EMAIL', '$DJANGO_SUPERUSER_PASSWORD')
    print('Superuser created.')
else:
    print('Superuser already exists.')
"
fi

# Iniciar el proceso según el rol del servicio
exec "$@"
EOF
chmod +x scripts/railway-entrypoint.sh
```

- [ ] **Step 3: Commit**

```bash
git add scripts/
git commit -m "feat: add Railway entrypoint scripts"
```

---

## Task 3: Ajustar el Dockerfile para Railway

**Files:**
- Modify: `Dockerfile` (reemplazar el oficial con versión Railway-compatible)

- [ ] **Step 1: Leer el Dockerfile actual**

```bash
cat Dockerfile
```

Tomar nota de las etapas existentes (base, deps, final).

- [ ] **Step 2: Reemplazar con Dockerfile Railway**

```dockerfile
# Dockerfile ajustado para Railway
ARG PYTHON_VERSION=3.12
FROM python:${PYTHON_VERSION}-slim-bookworm AS base

RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    libpq-dev \
    libjpeg-dev \
    zlib1g-dev \
    libssl-dev \
    netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Dependencias de Python
COPY requirements.txt requirements_dev.txt* ./
RUN pip install --no-cache-dir -r requirements.txt

# Código fuente
COPY . .

# Static files (media se sirve desde R2, no desde aquí)
RUN python manage.py collectstatic --noinput || true

# Scripts ejecutables
RUN chmod +x scripts/railway-entrypoint.sh scripts/wait-for-db.sh

EXPOSE 8000

ENTRYPOINT ["scripts/railway-entrypoint.sh"]

# Comando por defecto: API con gunicorn + uvicorn workers
# En Railway, cada servicio sobreescribe CMD según su rol.
CMD ["gunicorn", "--bind", "0.0.0.0:8000", "--workers", "4", "--threads", "2", \
     "--timeout", "120", "saleor.asgi:application", \
     "-k", "uvicorn.workers.UvicornWorker"]
```

Guardar como `Dockerfile`.

- [ ] **Step 3: Commit**

```bash
git add Dockerfile
git commit -m "feat: Railway-compatible Dockerfile with entrypoint"
```

---

## Task 4: Crear `railway.json`

**Files:**
- Create: `railway.json`

- [ ] **Step 1: Crear el archivo**

```json
{
  "$schema": "https://railway.app/railway.schema.json",
  "build": {
    "builder": "DOCKERFILE",
    "dockerfilePath": "Dockerfile"
  },
  "deploy": {
    "startCommand": "gunicorn --bind 0.0.0.0:$PORT --workers 4 --threads 2 --timeout 120 saleor.asgi:application -k uvicorn.workers.UvicornWorker",
    "healthcheckPath": "/health/",
    "healthcheckTimeout": 30,
    "restartPolicyType": "ON_FAILURE",
    "restartPolicyMaxRetries": 3
  }
}
```

Guardar como `railway.json`.

- [ ] **Step 2: Commit**

```bash
git add railway.json
git commit -m "feat: add railway.json deployment config"
```

---

## Task 5: Crear workflow de sincronización con upstream

**Files:**
- Create: `.github/workflows/sync-upstream.yml`

- [ ] **Step 1: Crear el workflow**

```yaml
# .github/workflows/sync-upstream.yml
name: Sync with Saleor upstream

on:
  schedule:
    # Cada lunes a las 9:00 UTC
    - cron: '0 9 * * 1'
  workflow_dispatch:

jobs:
  sync:
    runs-on: ubuntu-latest
    permissions:
      contents: write
      pull-requests: write

    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
          token: ${{ secrets.GITHUB_TOKEN }}

      - name: Fetch upstream tags
        run: |
          git remote add upstream https://github.com/saleor/saleor.git || true
          git fetch upstream --tags

      - name: Get latest stable tag
        id: upstream_tag
        run: |
          LATEST=$(git tag -l '3.*' --sort=-v:refname | grep -E '^3\.[0-9]+\.[0-9]+$' | head -1)
          echo "tag=$LATEST" >> $GITHUB_OUTPUT
          echo "Latest upstream tag: $LATEST"

      - name: Check if PR already exists
        id: check_pr
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          EXISTING=$(gh pr list --head "sync/upstream-${{ steps.upstream_tag.outputs.tag }}" --json number -q '.[0].number')
          echo "pr_number=$EXISTING" >> $GITHUB_OUTPUT

      - name: Create sync branch and PR
        if: steps.check_pr.outputs.pr_number == ''
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          TAG=${{ steps.upstream_tag.outputs.tag }}
          BRANCH="sync/upstream-$TAG"

          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"

          git checkout -b "$BRANCH"
          git merge "upstream/$TAG" --no-edit || true

          git push origin "$BRANCH" --force

          gh pr create \
            --title "chore: sync upstream Saleor $TAG" \
            --body "Automated sync with saleor/saleor@$TAG. Review conflicts and run migration tests before merging." \
            --base main \
            --head "$BRANCH" \
            --label "upstream-sync"
```

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/sync-upstream.yml
git commit -m "ci: add weekly upstream sync workflow"
```

---

## Task 6: Crear workflow de build de imagen Docker

**Files:**
- Create: `.github/workflows/build-image.yml`

- [ ] **Step 1: Crear el workflow**

```yaml
# .github/workflows/build-image.yml
name: Build and push Docker image

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

env:
  REGISTRY: ghcr.io
  IMAGE_NAME: ${{ github.repository }}

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write

    steps:
      - uses: actions/checkout@v4

      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Extract metadata
        id: meta
        uses: docker/metadata-action@v5
        with:
          images: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}
          tags: |
            type=sha,prefix=sha-
            type=ref,event=branch
            type=raw,value=latest,enable=${{ github.ref == 'refs/heads/main' }}

      - name: Build and push
        uses: docker/build-push-action@v5
        with:
          context: .
          push: ${{ github.event_name != 'pull_request' }}
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

- [ ] **Step 2: Configurar permisos de GHCR en el repo**

En GitHub → Settings del repo → Actions → General → Workflow permissions: marcar "Read and write permissions".

- [ ] **Step 3: Commit y push a main**

```bash
git add .github/workflows/build-image.yml
git commit -m "ci: build and push Docker image to GHCR"
git checkout main
git merge railway/setup
git push origin main
```

Verificar en GitHub Actions que el build inicia y completa sin errores.

---

## Task 7: Crear proyecto Railway con Postgres y Redis

**Files:**
- No hay archivos de código. Pasos en Railway dashboard / CLI.

- [ ] **Step 1: Instalar Railway CLI**

```bash
npm install -g @railway/cli
railway login
```

- [ ] **Step 2: Crear proyecto**

```bash
railway init --name licona-store
```

- [ ] **Step 3: Agregar Postgres 16**

En Railway dashboard → New Service → Database → PostgreSQL. Seleccionar versión 16.
Anotar la variable `DATABASE_URL` que Railway genera automáticamente.

- [ ] **Step 4: Agregar Redis 7**

En Railway dashboard → New Service → Database → Redis. Seleccionar versión 7.
Anotar la variable `REDIS_URL`.

- [ ] **Step 5: Verificar conectividad**

```bash
railway run python -c "import psycopg2; psycopg2.connect('$DATABASE_URL'); print('Postgres OK')"
```

---

## Task 8: Desplegar Saleor API en Railway

**Files:**
- Create: `.env.railway.example`

- [ ] **Step 1: Crear `.env.railway.example`**

```bash
# .env.railway.example — Copiar a Railway environment variables (nunca commitear valores reales)

# Django
SECRET_KEY=<openssl rand -hex 32>
ALLOWED_HOSTS=api.licona-store.com,*.railway.app
ALLOWED_CLIENT_HOSTS=licona-store.com,dashboard.licona-store.com,*.railway.app
DEBUG=False

# Base de datos y cache (Railway las inyecta automáticamente como addons)
DATABASE_URL=${{Postgres.DATABASE_URL}}
REDIS_URL=${{Redis.REDIS_URL}}
CELERY_BROKER_URL=${{Redis.REDIS_URL}}

# Email (usar Resend, Mailgun o SendGrid)
DEFAULT_FROM_EMAIL=no-reply@licona-store.com
EMAIL_URL=smtp://apikey:<SENDGRID_API_KEY>@smtp.sendgrid.net:587

# Media storage (Cloudflare R2)
AWS_MEDIA_BUCKET_NAME=licona-saleor-media
AWS_MEDIA_CUSTOM_DOMAIN=media.licona-store.com
AWS_ACCESS_KEY_ID=<R2_ACCESS_KEY>
AWS_SECRET_ACCESS_KEY=<R2_SECRET_KEY>
AWS_S3_ENDPOINT_URL=https://<ACCOUNT_ID>.r2.cloudflarestorage.com
AWS_QUERYSTRING_AUTH=False

# Saleor
DEFAULT_CHANNEL_SLUG=default-channel
ENABLE_ACCOUNT_CONFIRMATION_BY_EMAIL=True
RSA_PRIVATE_KEY=<openssl genrsa 2048 | base64>

# Primer deploy: crear superusuario
CREATE_SUPERUSER=true
DJANGO_SUPERUSER_EMAIL=admin@licona-store.com
DJANGO_SUPERUSER_PASSWORD=<contraseña segura>
```

- [ ] **Step 2: Crear servicio `saleor-api` en Railway**

En Railway dashboard → New Service → GitHub Repo → seleccionar `licona-saleor`.

- [ ] **Step 3: Configurar variables de entorno**

En el servicio `saleor-api` → Variables → Raw Editor. Pegar las variables del `.env.railway.example` con valores reales.

- [ ] **Step 4: Generar SECRET_KEY y RSA_PRIVATE_KEY**

```bash
# SECRET_KEY
openssl rand -hex 32

# RSA_PRIVATE_KEY (base64 para meterla como variable de una línea)
openssl genrsa 2048 | base64 | tr -d '\n'
```

- [ ] **Step 5: Verificar el primer deploy**

Railway dispara el deploy automáticamente al conectar el repo. Verificar en los logs:
- `Waiting for PostgreSQL` → `PostgreSQL is ready.`
- `Running migrations...` → `Applying XX migrations... OK`
- Gunicorn iniciando en el puerto asignado.

- [ ] **Step 6: Probar el endpoint de GraphQL**

```bash
curl https://<railway-generated-url>/graphql/ \
  -H "Content-Type: application/json" \
  -d '{"query": "{ shop { name } }"}'
```

Respuesta esperada:
```json
{"data":{"shop":{"name":"Saleor e-commerce"}}}
```

- [ ] **Step 7: Commit del ejemplo de env**

```bash
git add .env.railway.example
git commit -m "docs: add Railway environment variables example"
git push origin main
```

---

## Task 9: Crear servicios worker y beat

**Files:**
- Ninguno nuevo. Se reusan la misma imagen Docker con comando diferente.

- [ ] **Step 1: Crear servicio `saleor-worker`**

En Railway → New Service → Docker Image → `ghcr.io/<tu-usuario>/licona-saleor:latest`.

Start Command:
```
celery -A saleor worker -E --loglevel=info --concurrency=4
```

Compartir las mismas variables de entorno que `saleor-api` (Railway permite "share variables" entre servicios).

- [ ] **Step 2: Crear servicio `saleor-beat`**

Misma imagen. Start Command:
```
celery -A saleor beat --loglevel=info --scheduler django_celery_beat.schedulers:DatabaseScheduler
```

- [ ] **Step 3: Verificar workers activos**

En los logs de `saleor-worker` debe aparecer:
```
[celery@...] ready.
[celery@...] celery@... OK
```

---

## Task 10: Desplegar Saleor Dashboard

**Files:**
- Ninguno en el fork. Se usa la imagen oficial sin modificar.

- [ ] **Step 1: Crear servicio `saleor-dashboard` en Railway**

Docker Image: `ghcr.io/saleor/saleor-dashboard:3.22.x`

Variables de entorno:
```
API_URL=https://api.licona-store.com/graphql/
APP_MOUNT_URI=/
```

- [ ] **Step 2: Verificar acceso**

Abrir `https://<dashboard-railway-url>/` y verificar que la pantalla de login de Saleor aparece.

- [ ] **Step 3: Login con superusuario**

Usar las credenciales `DJANGO_SUPERUSER_EMAIL` y `DJANGO_SUPERUSER_PASSWORD` configuradas en Task 8.

---

## Task 11: Configurar dominios y Cloudflare R2

- [ ] **Step 1: Configurar dominios en Railway**

Para cada servicio con URL pública, ir a Settings → Custom Domain:
- `saleor-api` → `api.licona-store.com`
- `saleor-dashboard` → `dashboard.licona-store.com`

Railway provisiona SSL automáticamente.

- [ ] **Step 2: Crear bucket en Cloudflare R2 o S3/cloudfront**

En Cloudflare dashboard → R2 → Create bucket → `licona-saleor-media` o en cloudfront.

Configurar CORS para el bucket:
```json
[
  {
    "AllowedOrigins": ["https://licona-store.com", "https://api.licona-store.com"],
    "AllowedMethods": ["GET"],
    "AllowedHeaders": ["*"],
    "MaxAgeSeconds": 86400
  }
]
```

Si es en Cloudfront se debe configurar como corresponda

- [ ] **Step 3: Crear API token de R2**

En R2 → Manage R2 API tokens → Create API token → permisos: Edit (para el bucket `licona-saleor-media`).

Guardar `Access Key ID` y `Secret Access Key` en las variables de entorno de `saleor-api`.

- [ ] **Step 4: Verificar subida de media**

Desde el dashboard de Saleor, subir una imagen de prueba a un producto. Verificar que la URL apunta a `media.licona-store.com` y que la imagen es accesible.

---

## Task 12: Crear `UPGRADE_NOTES.md`

**Files:**
- Create: `UPGRADE_NOTES.md`

- [ ] **Step 1: Crear el archivo**

```markdown
# UPGRADE NOTES — licona-saleor fork

Este archivo documenta todos los cambios aplicados encima del upstream de Saleor.
Antes de cada actualización de upstream, revisar esta lista para detectar conflictos.

## Cambios aplicados

### 2026-04-16 — Setup inicial Railway
- **Archivos modificados:** `Dockerfile`
  - Se reemplazó el Dockerfile original con versión optimizada para Railway.
  - Se añadió `netcat-openbsd` para el script `wait-for-db.sh`.
  - Se ajustó el CMD para recibir `$PORT` de Railway.
- **Archivos creados:** `railway.json`, `scripts/railway-entrypoint.sh`, `scripts/wait-for-db.sh`, `.env.railway.example`
- **Motivación:** Railway no usa el Dockerfile original tal cual; necesita PORT dinámico y entrypoint con migraciones automáticas.

## Pendiente de upstream

Ninguno.

## Historial de actualizaciones de upstream

| Fecha | De | A | Notas |
|---|---|---|---|
| 2026-04-16 | — | 3.22.x | Versión base inicial |
```

- [ ] **Step 2: Commit**

```bash
git add UPGRADE_NOTES.md
git commit -m "docs: add UPGRADE_NOTES to track fork changes vs upstream"
git push origin main
```

---

## Verificación final de Fase 0

- [ ] `curl https://api.licona-store.com/graphql/` devuelve `{"data":{"shop":{"name":"..."}}}`.
- [ ] `https://dashboard.licona-store.com/` muestra pantalla de login de Saleor.
- [ ] Los logs de `saleor-worker` muestran Celery listo.
- [ ] Una imagen subida en el dashboard aparece en `media.licona-store.com/...`.
- [ ] El workflow de GitHub Actions `build-image.yml` pasó en verde.
- [ ] Actualizar `STATUS.md`: Fase 0 → ✅ Completada, Fase 1 → 🔄 En progreso.
