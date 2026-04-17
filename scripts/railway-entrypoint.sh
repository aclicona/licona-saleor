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
