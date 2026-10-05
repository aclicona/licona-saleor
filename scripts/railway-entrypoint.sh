#!/bin/sh
set -e

# Esperar a que la DB esté lista (override WAIT_FOR_DB solo para tests)
sh "${WAIT_FOR_DB:-/app/scripts/wait-for-db.sh}"

# Este entrypoint YA NO migra (B-386). Migra únicamente el preDeployCommand de
# saleor-api (`python manage.py migrate --noinput`); worker y beat esperan con
# scripts/wait-for-migrations.sh. Ver UPGRADE_NOTES.md (2026-10-05).

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
