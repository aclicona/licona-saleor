"""Detecta la deriva entre la branch protection del fork y el nombre real del job.

`scripts/check-branch-protection.sh` afirma, en su constante `CONTEXTO_ESPERADO`,
que el required status check configurado en GitHub para la rama de despliegue es
la cadena literal "Puerta rapida". Esa cadena está ACOPLADA al `name:` del job
`puerta` en `.github/workflows/ci-fork.yml`: GitHub identifica los required
status checks por ese nombre visible, no por el id del job (`puerta`).

Si alguien renombra el job (por ejemplo al traducirlo o al reordenar el
workflow) y no toca el guion en el mismo commit, la branch protection en
GitHub queda esperando para siempre un check que nunca vuelve a reportarse.
Nada de lo que corre en CI avisa de eso: el job sigue verde con su nombre
nuevo, y GitHub simplemente nunca marca como cumplido un requisito que ya no
existe. El síntoma es un PR o un push a `stable/*` colgado sin explicación
aparente.

Este test es la señal automática que evita ese silencio: compara ambas
fuentes de verdad (el guion y el workflow) y falla en rojo el día que se
separen, con instrucciones de qué hacer.

Este test cubre solo la mitad interna de esa deriva: la coherencia entre
el guion y el workflow dentro del propio árbol (corre en CI, sin red ni
credenciales). No puede ver si esa cadena coincide con el required status
check que GitHub tiene configurado de verdad — esa otra mitad la cubre
`scripts/check-branch-protection.sh` corriendo contra la API de GitHub.
Por eso un rename consistente (job y guion cambiados juntos, a la misma
cadena nueva) deja este test en verde: las dos fuentes siguen coincidiendo
entre sí, aunque GitHub siga esperando el nombre viejo. Quien lo atrapa es
el guion, que al comparar `contexts` contra la protección real sale con
exit 1. Ninguna de las dos piezas sustituye a la otra.

Por qué vive aquí y no en la raíz del fork o en `scripts/`: el fork todavía no
tiene una suite de tests propia, y `setup.cfg` fija `testpaths = saleor`, así
que un archivo fuera de `saleor/` no lo recogería ni un `pytest` corrido sin
argumentos ni el job `suite` de `ci-fork.yml`. Este archivo es nuevo, con
nombre propio (`test_fork_*`), así que no compite por líneas con upstream en
ningún sync de la rama `stable/3.23.x`.

No usa la base de datos: solo lee dos archivos de texto del repo. No requiere
la fixture `db` ni `@pytest.mark.django_db`.
"""

import json
import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest
import yaml

# El archivo vive en <raíz>/saleor/tests/, así que la raíz del repo está dos
# niveles arriba: tests/ -> saleor/ -> raíz.
RAIZ = Path(__file__).resolve().parents[2]
GUION = RAIZ / "scripts" / "check-branch-protection.sh"
WORKFLOW = RAIZ / ".github" / "workflows" / "ci-fork.yml"


def _contexto_esperado_del_guion() -> str:
    """Extrae el valor de CONTEXTO_ESPERADO="..." del guion de branch protection."""
    contenido = GUION.read_text(encoding="utf-8")
    coincidencia = re.search(r'^CONTEXTO_ESPERADO="(.*)"$', contenido, re.MULTILINE)
    assert coincidencia is not None, (
        f'No encontré una línea `CONTEXTO_ESPERADO="..."` en {GUION}. '
        "Si el guion cambió de formato, actualiza este test para que siga "
        "leyendo la constante real; si el guion desapareció, este test ya "
        "no tiene nada que comparar y debería eliminarse junto con él."
    )
    return coincidencia.group(1)


def _nombre_del_job_puerta() -> str:
    """Lee el `name:` del job `puerta` en el workflow del fork."""
    workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    jobs = workflow.get("jobs", {})
    assert "puerta" in jobs, (
        f"El job `puerta` ya no existe en {WORKFLOW}. "
        "`check-branch-protection.sh` configura el required status check "
        "asumiendo que ese job sigue ahí con ese nombre; si se renombró el "
        "id del job (no solo su `name:`), revisa también la branch "
        "protection real en GitHub."
    )
    # Sin `name:`, GitHub usa el id del job ("puerta") como nombre visible
    # del check: ese es el fallback correcto (no None ni ""), para que el
    # test siga comparando contra lo que GitHub mostraría en la realidad.
    return jobs["puerta"].get("name", "puerta")


def test_contexto_esperado_coincide_con_el_nombre_del_job_puerta():
    r"""El required status check declarado en el guion debe ser el `name:` real del job.

    Si este test se pone rojo, el guion y el workflow se separaron: alguien
    cambió el `name:` del job `puerta` en `ci-fork.yml` (o la constante
    `CONTEXTO_ESPERADO` en `check-branch-protection.sh`) sin tocar la otra
    mitad. Consecuencia concreta si esto llega a producción sin corregirse:
    la branch protection de GitHub queda esperando para siempre un check con
    el nombre viejo, que ya no vuelve a reportarse — el PR o el push a
    `stable/*` se queda colgado, sin ningún error visible que lo explique.

    Cómo arreglarlo: iguala las dos cadenas (cambia el `name:` del job o la
    constante del guion, lo que corresponda a la intención real) y además
    actualiza la branch protection YA CONFIGURADA en GitHub — vive fuera de
    git, así que este commit no la toca sola:
        gh api -X PUT repos/<owner>/<repo>/branches/<rama>/protection \\
          --input <payload-con-el-nombre-correcto>.json
    """
    contexto_esperado = _contexto_esperado_del_guion()
    nombre_job = _nombre_del_job_puerta()

    assert contexto_esperado == nombre_job, (
        f"CONTEXTO_ESPERADO del guion ('{contexto_esperado}') ya no coincide "
        f"con el name: del job `puerta` ('{nombre_job}'). "
        "Mientras estén separados, la branch protection de GitHub espera un "
        "required status check que nunca llega: el merge o el push a "
        "stable/* se queda colgado sin aviso. Arréglalo igualando las dos "
        "cadenas (el name: del job o la constante del guion) y actualiza "
        "también la protección real en GitHub con "
        "`gh api -X PUT .../protection`, porque esa configuración vive "
        "fuera de git y este commit no la sincroniza sola."
    )


def test_guion_y_job_existen():
    """Guarda mínima: el guion define la constante y el job `puerta` existe.

    Si esto falla, el problema no es una deriva de nombres sino que falta
    una de las dos piezas por completo (el guion no se creó, o el job se
    borró del workflow) — un fallo distinto y anterior al que verifica el
    test de arriba.
    """
    assert GUION.exists(), f"No existe {GUION}."
    assert WORKFLOW.exists(), f"No existe {WORKFLOW}."
    assert _contexto_esperado_del_guion(), (
        f"{GUION} existe pero CONTEXTO_ESPERADO está vacío o no se pudo leer."
    )
    # No reutiliza _nombre_del_job_puerta(): con el fallback a "puerta" esa
    # función ya siempre devuelve una cadena no vacía, así que este assert
    # nunca podría fallar. Se comprueba la clave `name` directamente.
    jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
    assert "name" in jobs["puerta"], (
        f"El job `puerta` en {WORKFLOW} existe pero no tiene `name:`."
    )


# ─── Contrato de los campos: el guion contra un `gh` falso ─────────────────────
# El guion ahora afirma once puntos (ver su cabecera). Estos casos lo ejecutan
# con un `gh` falso en el PATH que sirve un JSON de /protection y le aplica el
# `--jq` real con `jq`, para fijar que cada campo que puede bloquear el push de
# despliegue produce exit 1, que la ausencia de `restrictions` y
# `required_pull_request_reviews` es el estado conforme, y que una respuesta
# vacía o `{}` es "no sé" (2) y no una cascada de derivas. Sin red.

_GH_FALSO = """#!/bin/sh
[ "$1" = auth ] && exit 0
EP=$2; shift 2
JQ=""; while [ $# -gt 0 ]; do [ "$1" = "--jq" ] && JQ=$2; shift; done
case "$EP" in
  */rules/branches/*)
    [ "$CASO" = rules_error ] && { echo "gh: Internal Server Error (HTTP 500)" >&2; exit 1; }
    if [ -f "$FIX/rules.json" ]; then jq -r "$JQ" "$FIX/rules.json"; else echo '[]' | jq -r "$JQ"; fi ;;
  */protection)
    [ "$CASO" = 404 ] && { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    [ -f "$FIX/protection.json" ] || exit 0
    jq -r "$JQ" "$FIX/protection.json" ;;
  *) echo "stable/3.23"; echo "${PROTECTED:-true}" ;;
esac
"""

_PROTECCION_CONFORME = {
    "required_status_checks": {"strict": False, "contexts": ["Puerta rapida"]},
    "enforce_admins": {"enabled": False},
    "allow_force_pushes": {"enabled": True},
    "allow_deletions": {"enabled": False},
    "block_creations": {"enabled": False},
    "lock_branch": {"enabled": False},
    "required_linear_history": {"enabled": False},
    "required_signatures": {"enabled": False},
    "required_conversation_resolution": {"enabled": False},
    "allow_fork_syncing": {"enabled": False},
    "url": "https://example.invalid",
}


def _ejecutar_guion(tmp_path, cuerpo, caso="", protegida="true", reglas=None):
    if shutil.which("jq") is None or shutil.which("sh") is None:
        pytest.skip("hace falta `jq` y `sh` para simular el `--jq` de gh")
    gh = tmp_path / "bin" / "gh"
    gh.parent.mkdir()
    gh.write_text(_GH_FALSO, encoding="utf-8")
    gh.chmod(0o755)
    if cuerpo is not None:
        (tmp_path / "protection.json").write_text(cuerpo, encoding="utf-8")
    if reglas is not None:
        (tmp_path / "rules.json").write_text(json.dumps(reglas), encoding="utf-8")
    entorno = {
        **os.environ,
        "PATH": f"{gh.parent}{os.pathsep}{os.environ['PATH']}",
        "FIX": str(tmp_path),
        "CASO": caso,
        "PROTECTED": protegida,
    }
    return subprocess.run(
        ["sh", str(GUION)], env=entorno, capture_output=True, text=True, check=False
    ).returncode


def _con(**cambios):
    return json.dumps({**_PROTECCION_CONFORME, **cambios})


@pytest.mark.parametrize(
    ("cuerpo", "esperado"),
    [
        (json.dumps(_PROTECCION_CONFORME), 0),
        (_con(lock_branch={"enabled": True}), 1),
        (_con(block_creations={"enabled": True}), 1),
        (_con(required_linear_history={"enabled": True}), 1),
        (_con(required_signatures={"enabled": True}), 1),
        (_con(restrictions={"users": [], "teams": [], "apps": []}), 1),
        (_con(required_pull_request_reviews={"required_approving_review_count": 1}), 1),
        (_con(enforce_admins={"enabled": True}), 1),
        ("", 2),
        ("{}", 2),
    ],
    ids=[
        "conforme",
        "lock_branch",
        "block_creations",
        "linear_history",
        "signatures",
        "restrictions",
        "pr_reviews",
        "enforce_admins",
        "cuerpo_vacio",
        "objeto_vacio",
    ],
)
def test_guion_exit_code_segun_la_proteccion(tmp_path, cuerpo, esperado):
    assert _ejecutar_guion(tmp_path, cuerpo) == esperado


def test_guion_404_con_rama_protegida_es_no_se(tmp_path):
    assert _ejecutar_guion(tmp_path, None, caso="404", protegida="true") == 2


def test_guion_404_con_rama_sin_proteger_es_deriva(tmp_path):
    assert _ejecutar_guion(tmp_path, None, caso="404", protegida="false") == 1


# ─── Repository rulesets (B-769) ───────────────────────────────────────────────
# `GET /repos/<repo>/rules/branches/<rama>` devuelve las reglas efectivas. Las
# cinco que bloquean el push directo de despliegue son deriva; el resto no.


@pytest.mark.parametrize(
    "tipo",
    [
        "pull_request",
        "non_fast_forward",
        "required_linear_history",
        "required_signatures",
        "update",
    ],
)
def test_guion_ruleset_que_bloquea_el_push_es_deriva(tmp_path, tipo):
    reglas = [{"type": tipo, "ruleset_source_type": "Repository", "ruleset_id": 42}]
    assert _ejecutar_guion(tmp_path, _con(), reglas=reglas) == 1


def test_guion_ruleset_con_reglas_ajenas_al_push_es_conforme(tmp_path):
    reglas = [
        {"type": "deletion", "ruleset_id": 7},
        {"type": "creation", "ruleset_id": 7},
    ]
    assert _ejecutar_guion(tmp_path, _con(), reglas=reglas) == 0


def test_guion_sin_rulesets_es_conforme(tmp_path):
    assert _ejecutar_guion(tmp_path, _con(), reglas=[]) == 0


def test_guion_api_de_rulesets_caida_es_no_se(tmp_path):
    assert _ejecutar_guion(tmp_path, _con(), caso="rules_error") == 2


def test_guion_api_de_rulesets_caida_no_tapa_una_deriva_clasica(tmp_path):
    cuerpo = _con(lock_branch={"enabled": True})
    assert _ejecutar_guion(tmp_path, cuerpo, caso="rules_error") == 1


# Cadena literal de la que depende el guard del repo raíz `ecommerce`
# (`scripts/railway-seguro/ci_desplegable.py`, constante `JOB_SUITE`, B-792/B-822).
NOMBRE_JOB_SUITE = "Suite completa (17k tests)"


def test_existe_un_job_con_el_nombre_que_espera_el_guard_de_ci_desplegable():
    """El guard de encendido busca el job de suite por igualdad con esta cadena.

    `scripts/railway-seguro/ci_desplegable.py` (repo raíz, fuera de este fork)
    declara `JOB_SUITE = "Suite completa (17k tests)"` y solo da luz verde si un
    run de `ci-fork.yml` trae un job con ESE `name:` en `success`. Si alguien
    renombra el job, el guard sale con exit 2 («ningún job se llama ...») y
    bloquea todo encendido. Cómo arreglarlo: cambia a la vez el `name:` del job
    y `JOB_SUITE` en el guard del raíz (y la cadena de este test).
    """
    jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
    # Sin `name:`, GitHub muestra el id del job; se replica ese fallback.
    nombres = [job.get("name", id_job) for id_job, job in jobs.items()]
    assert NOMBRE_JOB_SUITE in nombres, (
        f"Ningún job de {WORKFLOW} se llama '{NOMBRE_JOB_SUITE}' (nombres: "
        f"{nombres}). El guard `scripts/railway-seguro/ci_desplegable.py` del "
        "repo raíz compara `JOB_SUITE` por igualdad con esa cadena: renombrar "
        "el job sin actualizarlo hace que el guard dé exit 2 y bloquee todo "
        "encendido."
    )


# Segunda y tercera cadena de la que depende el mismo guard (B-841): el nombre
# del archivo `ci-fork.yml` (constante `WORKFLOW` del guard; ya lo cubre
# implícitamente `WORKFLOW` de este módulo, que lo lee por ruta y falla si
# desaparece) y el input `alcance` con la opción `completo` del
# `workflow_dispatch`, que es el comando de dispatch que el guard imprime en
# sus rechazos (`gh workflow run ci-fork.yml -f alcance=completo`).
INPUT_ALCANCE = "alcance"
VALOR_ALCANCE_COMPLETO = "completo"


def test_workflow_dispatch_admite_alcance_completo_como_espera_el_guard():
    """`on.workflow_dispatch.inputs.alcance` existe y admite `completo`.

    `scripts/railway-seguro/ci_desplegable.py` (repo raíz) imprime, al rechazar,
    un `gh workflow run ci-fork.yml -f alcance=completo`. Si se renombra el
    input o su opción, el comando impreso deja de funcionar y el encendido
    queda bloqueado sin salida clara. Cómo arreglarlo: cambia a la vez el input
    en `ci-fork.yml` y el comando/constantes del guard del raíz.
    """
    workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    # PyYAML (YAML 1.1) parsea la clave `on` como el booleano True.
    disparadores = workflow.get("on", workflow.get(True))
    assert isinstance(disparadores, dict), f"{WORKFLOW} no declara `on:` como mapa."
    assert "workflow_dispatch" in disparadores, (
        f"{WORKFLOW} ya no declara `workflow_dispatch`: el guard no puede "
        "disparar la suite completa."
    )
    inputs = (disparadores["workflow_dispatch"] or {}).get("inputs") or {}
    assert INPUT_ALCANCE in inputs, (
        f"`workflow_dispatch` de {WORKFLOW} no tiene el input "
        f"'{INPUT_ALCANCE}' (tiene: {list(inputs)}); el comando de dispatch "
        "del guard `ci_desplegable.py` dejaría de funcionar."
    )
    alcance = inputs[INPUT_ALCANCE] or {}
    if alcance.get("type") == "choice":
        assert VALOR_ALCANCE_COMPLETO in alcance.get("options", []), (
            f"El input '{INPUT_ALCANCE}' es `choice` pero sus opciones "
            f"{alcance.get('options')} no incluyen '{VALOR_ALCANCE_COMPLETO}'."
        )
