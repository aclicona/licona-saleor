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

Por qué vive aquí y no en la raíz del fork o en `scripts/`: el fork todavía no
tiene una suite de tests propia, y `setup.cfg` fija `testpaths = saleor`, así
que un archivo fuera de `saleor/` no lo recogería ni un `pytest` corrido sin
argumentos ni el job `suite` de `ci-fork.yml`. Este archivo es nuevo, con
nombre propio (`test_fork_*`), así que no compite por líneas con upstream en
ningún sync de la rama `stable/3.22.x`.

No usa la base de datos: solo lee dos archivos de texto del repo. No requiere
la fixture `db` ni `@pytest.mark.django_db`.
"""

import re
from pathlib import Path

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
    return jobs["puerta"]["name"]


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
    assert _nombre_del_job_puerta(), (
        f"El job `puerta` en {WORKFLOW} existe pero no tiene `name:`."
    )
