#!/bin/sh
# test_check_slowest_test.sh — pruebas de scripts/check-slowest-test.sh (B-1024).
#
# No necesita venv ni base: genera JUnits de juguete y setup.cfg de prueba en un
# directorio temporal; no escribe nada en el repo.
# Uso: sh scripts/tests/test_check_slowest_test.sh

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 2
GUION="$DIR/../check-slowest-test.sh"
T=$(mktemp -d) || exit 2
trap 'rm -rf "$T"' EXIT HUP INT TERM

cfg() { printf '[tool:pytest]\ntimeout = %s\n' "$1" >"$T/setup.cfg"; }
junit() { # $1 = duración del más lento
  cat >"$T/j.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<testsuites><testsuite name="pytest" tests="3">
<testcase classname="a.test_x" name="test_rapido" time="0.5"/>
<testcase classname="a.test_y" name="test_lento" time="$1"/>
<testcase classname="a.test_z" name="test_medio" time="2.0"/>
</testsuite></testsuites>
XML
}

FALLOS=0
# caso <nombre> <exit esperado> <patrón que debe salir> <patrón que NO debe salir | -> [env...]
# Corre el guion con el resumen a un archivo y junta stdout + resumen.
correr() {
  : >"$T/resumen.md"
  SALIDA=$(env SETUP_CFG="$T/setup.cfg" GITHUB_STEP_SUMMARY="$T/resumen.md" "$@" sh "$GUION" "$T/j.xml" 2>&1)
  COD=$?
  SALIDA="$SALIDA
$(cat "$T/resumen.md")"
}
verifica() {
  if eval "$2"; then echo "ok   - $1"; else
    echo "FAIL - $1"; printf '%s\n' "$SALIDA" | sed 's/^/       | /'; FALLOS=$((FALLOS + 1))
  fi
}
tiene() { printf '%s\n' "$SALIDA" | grep -q -- "$1"; }

cfg 600; junit 30.0; correr A=1
verifica "1 por debajo del umbral: sin warning, resumen con la duración máxima" \
  '[ "$COD" -eq 0 ] && ! tiene "::warning::" && tiene "30.0 s"'

junit 400.0; correr A=1
verifica "2 por encima del umbral: warning con nombre y duración" \
  '[ "$COD" -eq 0 ] && tiene "::warning::.*a.test_y::test_lento.*400.0 s"'

junit 30.0; correr UMBRAL_SEGUNDOS=1
verifica "3 UMBRAL_SEGUNDOS bajo fuerza el warning" \
  '[ "$COD" -eq 0 ] && tiene "::warning::.*test_lento"'

rm -f "$T/j.xml"; correr A=1
verifica "4 falta el XML: notice y exit 0" '[ "$COD" -eq 0 ] && tiene "::notice::" && ! tiene "::warning::"'

printf '<testsuites><testcase' >"$T/j.xml"; correr A=1
verifica "5 XML corrupto: exit 0 y notice" '[ "$COD" -eq 0 ] && tiene "::notice::" && ! tiene "::warning::"'

cfg 100; junit 60.0; correr A=1
verifica "6 timeout leído del setup.cfg de prueba (100 -> umbral 50)" \
  '[ "$COD" -eq 0 ] && tiene "::warning::.*umbral de 50 s"'

cfg 100; junit 40.0; correr A=1
verifica "7 con timeout 100, 40 s no avisa" '[ "$COD" -eq 0 ] && ! tiene "::warning::"'

[ "$FALLOS" -eq 0 ] || { echo "$FALLOS fallo(s)"; exit 1; }
echo "todo ok"
