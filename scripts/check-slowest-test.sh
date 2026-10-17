#!/bin/sh
# check-slowest-test.sh — ¿el test más lento de la suite se acerca al timeout? (B-1024)
#
# B-1019 fijó `timeout = 600` por test (setup.cfg, [tool:pytest]). Nadie vigilaba el
# margen: el test más lento medido tardó 206,9 s (primer test de un worker xdist en frío).
# Este guion lee el JUnit de la suite, escribe en el resumen del job la duración máxima y
# el top 5, y avisa con `::warning::` si el más lento pasa de la mitad del timeout.
#
# ─── Contrato de salida ──────────────────────────────────────────────────────
#   0 — SIEMPRE. Es un termómetro, nunca una puerta: si falta el XML, está corrupto o
#       el intérprete falla, emite `::notice::` ("no se pudo medir") y sale 0. Romper el
#       job por esto taparía el resultado real de la suite.
#
# ─── Entrada ─────────────────────────────────────────────────────────────────
#   $1 (o JUNIT_XML)   ruta del XML; por defecto junit/test-results.xml
#   SETUP_CFG          setup.cfg del que leer `timeout`; por defecto el de la raíz del repo
#   UMBRAL_SEGUNDOS    umbral en segundos; por defecto timeout/2 (sirve para forzar el
#                      warning en una prueba)
#   GITHUB_STEP_SUMMARY  si no está definida, el resumen va a stdout
#
# ─── Convenciones ────────────────────────────────────────────────────────────
# · sh POSIX puro; el análisis del XML lo hace python3 con la stdlib (xml.etree).
# · Sin `set -e` a propósito: nada de aquí debe poder romper el job.

PYTHON="${PYTHON:-python3}"
ETIQUETA="[check-slowest-test]"
TIMEOUT_RESPALDO=600

DIR_GUION=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || DIR_GUION=.
XML="${1:-${JUNIT_XML:-junit/test-results.xml}}"
CFG="${SETUP_CFG:-$DIR_GUION/../setup.cfg}"

if [ ! -f "$XML" ]; then
  echo "::notice::$ETIQUETA No se pudo medir el test más lento: no existe $XML."
  exit 0
fi

if ! command -v "$PYTHON" >/dev/null 2>&1; then
  echo "::notice::$ETIQUETA No se pudo medir el test más lento: no hay intérprete '$PYTHON'."
  exit 0
fi

"$PYTHON" - "$XML" "$CFG" "$TIMEOUT_RESPALDO" "${UMBRAL_SEGUNDOS:-}" "${GITHUB_STEP_SUMMARY:-}" <<'PY'
import configparser
import sys
import xml.etree.ElementTree as ET

xml_path, cfg_path, respaldo, umbral_env, resumen_path = sys.argv[1:6]


def leer_timeout():
    cfg = configparser.ConfigParser(interpolation=None)
    try:
        cfg.read(cfg_path)
        return float(cfg.get("tool:pytest", "timeout"))
    except Exception:
        return float(respaldo)


def main():
    try:
        casos = []
        for tc in ET.parse(xml_path).getroot().iter("testcase"):
            casos.append((float(tc.get("time", "0")), tc.get("classname", ""), tc.get("name", "")))
    except Exception as exc:
        print(f"::notice::[check-slowest-test] No se pudo medir el test más lento: {xml_path} ilegible ({type(exc).__name__}).")
        return
    if not casos:
        print(f"::notice::[check-slowest-test] No se pudo medir el test más lento: {xml_path} no trae testcases.")
        return

    timeout = leer_timeout()
    umbral = float(umbral_env) if umbral_env else timeout / 2
    casos.sort(key=lambda c: c[0], reverse=True)
    maximo = casos[0]

    lineas = [
        "### Test más lento",
        "",
        f"Duración máxima: **{maximo[0]:.1f} s** (timeout por test: {timeout:g} s, umbral de aviso: {umbral:g} s).",
        "",
        "| # | Test | Duración (s) |",
        "|---|------|-------------|",
    ]
    for i, (t, clase, nombre) in enumerate(casos[:5], 1):
        lineas.append(f"| {i} | `{clase}::{nombre}` | {t:.1f} |")
    texto = "\n".join(lineas) + "\n"
    try:
        if resumen_path:
            with open(resumen_path, "a", encoding="utf-8") as f:
                f.write(texto)
        else:
            print(texto)
    except OSError as exc:
        print(f"::notice::[check-slowest-test] No se pudo escribir el resumen ({exc}).")

    if maximo[0] > umbral:
        print(
            f"::warning::[check-slowest-test] {maximo[1]}::{maximo[2]} tardó {maximo[0]:.1f} s, "
            f"más que el umbral de {umbral:g} s (timeout por test: {timeout:g} s). B-1024."
        )


main()
PY
if [ $? -ne 0 ]; then
  echo "::notice::$ETIQUETA No se pudo medir el test más lento: falló el análisis."
fi
exit 0
