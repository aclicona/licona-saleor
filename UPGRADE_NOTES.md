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

**Sin cambios en:**

- Lógica de negocio de Saleor
- Modelos, migraciones ni settings de Django
- Código Python del core

---

## Pendiente de upstream

Ninguno.

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
