#!/bin/sh
# test_railway_config.sh — drift-test de railway.saleor-{api,worker,beat}.json (B-876).
#
# Esos archivos reproducen lo que hay en el panel de Railway (leído el 2026-10-06).
# Afirma: api migra en su preDeploy; worker/beat solo esperan (nunca migran); los
# startCommand coinciden con el panel; y como con Dockerfile un startCommand
# SUSTITUYE el ENTRYPOINT (docs.railway.com/deployments/start-command), que
# `railway-entrypoint.sh` solo corre donde el startCommand lo invoca explícitamente.
# Uso: sh scripts/tests/test_railway_config.sh

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 2
RAIZ="$DIR/../.."
FALLOS=0
verifica() { # <nombre> <exit code>
  if [ "$2" -eq 0 ]; then echo "ok   - $1"; else echo "FAIL - $1"; FALLOS=$((FALLOS + 1)); fi
}
# campo <archivo> <ruta.json> -> imprime el valor (JSON compacto) o "<ausente>"
campo() {
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."):
    d = d.get(k) if isinstance(d, dict) else None
print("<ausente>" if d is None else json.dumps(d))
' "$RAIZ/$1" "$2"
}
igual() { [ "$(campo "$1" "$2")" = "$3" ]; echo $?; }

for s in api worker beat; do
  f="railway.saleor-$s.json"
  verifica "$s: JSON válido con \$schema de Railway" "$(python3 -c 'import json,sys; sys.exit(0 if "railway.com/railway.schema.json" in json.load(open(sys.argv[1]))["$schema"] else 1)' "$RAIZ/$f" 2>/dev/null; echo $?)"
  verifica "$s: builder DOCKERFILE" "$(igual "$f" build.builder '"DOCKERFILE"')"
  verifica "$s: restartPolicy igual que railway.json" "$(igual "$f" deploy.restartPolicyType "$(campo railway.json deploy.restartPolicyType)")"
done

verifica "api: preDeploy migra" "$(igual railway.saleor-api.json deploy.preDeployCommand '["python manage.py migrate --noinput"]')"
verifica "api: sin startCommand (usa ENTRYPOINT+CMD del Dockerfile)" "$(igual railway.saleor-api.json deploy.startCommand '<ausente>')"
verifica "api: healthcheck /health/ 300 s" "$([ "$(campo railway.saleor-api.json deploy.healthcheckPath)" = '"/health/"' ] && [ "$(campo railway.saleor-api.json deploy.healthcheckTimeout)" = 300 ]; echo $?)"
for s in worker beat; do
  f="railway.saleor-$s.json"
  verifica "$s: preDeploy solo espera (wait-for-migrations)" "$(igual "$f" deploy.preDeployCommand '["sh scripts/wait-for-migrations.sh"]')"
  verifica "$s: ningún comando de deploy contiene 'migrate --noinput'" "$(! grep -q 'migrate --noinput' "$RAIZ/$f"; echo $?)"
done
verifica "worker: startCommand = panel" "$(igual railway.saleor-worker.json deploy.startCommand "\"sh -c 'celery -A saleor worker -E --concurrency=4'\"")"
verifica "beat: startCommand = panel" "$(igual railway.saleor-beat.json deploy.startCommand '"sh scripts/railway-entrypoint.sh celery -A saleor beat"')"

# El startCommand sustituye al ENTRYPOINT: el entrypoint solo corre si se invoca a mano.
verifica "beat: invoca railway-entrypoint.sh explícitamente" "$(campo railway.saleor-beat.json deploy.startCommand | grep -q 'scripts/railway-entrypoint.sh'; echo $?)"
verifica "worker: NO invoca railway-entrypoint.sh (documentado: no corre, sin wait-for-db)" "$(! campo railway.saleor-worker.json deploy.startCommand | grep -q 'railway-entrypoint'; echo $?)"
verifica "Dockerfile declara el ENTRYPOINT que un startCommand sustituye" "$(grep -q '^ENTRYPOINT .*railway-entrypoint.sh' "$RAIZ/Dockerfile"; echo $?)"

echo
if [ "$FALLOS" -eq 0 ]; then echo "OK"; else echo "$FALLOS fallo(s)"; exit 1; fi
