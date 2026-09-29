"""Detecta la deriva entre `scripts/check-github-settings.sh` y el árbol de workflows.

`scripts/check-github-settings.sh` declara dos constantes que describen lo que este
fork espera encontrar en `.github/workflows/` y en los secrets de Actions del
repositorio:

- `WORKFLOWS_PROPIOS`: rutas (relativas a la raíz del repo, separadas por coma) de los
  workflows que son de este fork — no de upstream — y sobre los que el guion pide el
  `state: active` real vía la API de Actions.
- `SECRETS_ESPERADOS`: nombres de secrets de Actions (separados por coma) que esos
  workflows propios tienen permiso de usar. Hoy esa lista está VACÍA a propósito:
  ningún workflow propio usa un secret distinto de `GITHUB_TOKEN` (el token efímero
  que GitHub inyecta solo, no un secret configurado a mano).

Ambas constantes están ACOPLADAS al contenido real de los tres workflows propios
(`ci-fork.yml`, `security-scan.yml`, `sync-upstream.yml`). Si alguien borra un
workflow del árbol, añade un `secrets.ALGO` nuevo, o quita el bloque `permissions:`
de un job, y no toca el guion (o el workflow) en el mismo commit, las dos fuentes se
separan en silencio: nada en CI avisa, porque nada más lee estas dos constantes.

Este test cubre solo la mitad interna de esa deriva: la coherencia entre el guion y
el árbol de `.github/workflows/`, dentro del propio repo (corre en CI, sin red ni
credenciales). La otra mitad — el estado real de GitHub: workflows deshabilitados,
`default_workflow_permissions` del repo, política de aprobación de PR de fork,
secrets efectivamente configurados — la cubre `scripts/check-github-settings.sh`
corriendo contra la API de GitHub. Ninguna de las dos piezas sustituye a la otra.

Por qué NO se implementa la dirección inversa (todo workflow propio que exista en el
árbol debe estar en `WORKFLOWS_PROPIOS`): dentro del árbol no hay un discriminador
fiable propio-vs-upstream. No hay marcador en los archivos, y `git log` tampoco sirve
como discriminador — que es la salida que parece obvia y no lo es. El job `suite` de
`ci-fork.yml`, que es el que ejecuta ESTE archivo, usa `actions/checkout@v5` SIN
`fetch-depth`, o sea el default: un clon superficial de profundidad 1. En CI no hay
historial que consultar, así que "¿quién escribió este archivo?" no tiene respuesta
ahí. (Los dos jobs de `sync-upstream.yml` sí piden `fetch-depth: 0`, porque necesitan
el historial para mergear upstream; pero eso no ayuda a un test que corre en otro
workflow.) Se deja ese motivo escrito en vez de inventar un marcador nuevo en los
workflows solo para que este test pueda leerlo.

Por qué vive en `saleor/tests/` y no en la raíz del fork o en `scripts/`: mismo
motivo que `test_fork_branch_protection_drift.py` — el fork no tiene una suite de
tests propia fuera de `saleor/`, y `setup.cfg` fija `testpaths = saleor`, así que un
archivo fuera de ahí no lo recogería ni un `pytest` corrido sin argumentos ni el job
`suite` de `ci-fork.yml`.

Por qué es un archivo nuevo y no una ampliación de `test_fork_branch_protection_drift.py`:
ese archivo está atado, por nombre y por docstring, a `check-branch-protection.sh` y a
la branch protection de una sola rama. Este archivo cubre un guion distinto
(`check-github-settings.sh`) con un contrato distinto (workflows + secrets, no un
único required status check). Un test por guion evita que un solo archivo termine
mezclando dos contratos que cambian por separado.

No usa la base de datos: solo lee archivos de texto del repo (el guion `.sh` con
regex, los workflows `.yml` con `yaml.safe_load`). No requiere la fixture `db` ni
`@pytest.mark.django_db`.
"""

import re
from pathlib import Path

import yaml

# El archivo vive en <raíz>/saleor/tests/, así que la raíz del repo está dos
# niveles arriba: tests/ -> saleor/ -> raíz.
RAIZ = Path(__file__).resolve().parents[2]
GUION = RAIZ / "scripts" / "check-github-settings.sh"

PREFIJO_WORKFLOWS = ".github/workflows/"

# `${{ secrets.NOMBRE }}` con espacios opcionales alrededor de `secrets.NOMBRE`. Se
# aplica string por string sobre el árbol YAML ya cargado (ver
# `_secrets_referenciados_en_workflow`), nunca sobre el texto crudo del archivo — el
# porqué está en el docstring del test que lo usa.
PATRON_SECRET = re.compile(r"\$\{\{\s*secrets\.([A-Za-z_][A-Za-z0-9_]*)\s*\}\}")

SECRET_IMPLICITO = "GITHUB_TOKEN"


def _workflows_propios_del_guion() -> list[str]:
    """Extrae la lista de rutas de WORKFLOWS_PROPIOS="..." del guion.

    Devuelve las rutas tal como aparecen en el guion (separadas por coma, sin
    normalizar más allá de quitar espacios sueltos). No valida aquí que la lista sea
    no vacía ni que las rutas existan — eso lo comprueban los tests que usan esta
    función, cada uno con su propio motivo para fallar.
    """
    contenido = GUION.read_text(encoding="utf-8")
    coincidencia = re.search(r'^WORKFLOWS_PROPIOS="(.*)"$', contenido, re.MULTILINE)
    assert coincidencia is not None, (
        f'No encontré una línea `WORKFLOWS_PROPIOS="..."` en {GUION}. '
        "Si el guion cambió de formato, actualiza este test para que siga "
        "leyendo la constante real; si el guion desapareció, este test ya "
        "no tiene nada que comparar y debería eliminarse junto con él."
    )
    valor = coincidencia.group(1)
    if valor == "":
        return []
    return [ruta.strip() for ruta in valor.split(",")]


def _secrets_esperados_del_guion() -> set[str]:
    """Extrae el conjunto de SECRETS_ESPERADOS="..." del guion.

    Distingue dos fallos distintos: si la línea no aparece en absoluto, el guion
    cambió de formato (falla con un assert explicativo, como
    `_workflows_propios_del_guion`). Si la línea aparece pero su valor es la cadena
    vacía, eso es el estado CORRECTO hoy (ningún workflow propio usa un secret propio
    distinto de GITHUB_TOKEN) y esta función devuelve un conjunto vacío — no `{""}`,
    que sería un secret fantasma de nombre vacío.
    """
    contenido = GUION.read_text(encoding="utf-8")
    coincidencia = re.search(r'^SECRETS_ESPERADOS="(.*)"$', contenido, re.MULTILINE)
    assert coincidencia is not None, (
        f'No encontré una línea `SECRETS_ESPERADOS="..."` en {GUION}. '
        "Si el guion cambió de formato, actualiza este test para que siga "
        "leyendo la constante real; si el guion desapareció, este test ya "
        "no tiene nada que comparar y debería eliminarse junto con él."
    )
    valor = coincidencia.group(1)
    if valor == "":
        return set()
    return {nombre.strip() for nombre in valor.split(",") if nombre.strip()}


def _secrets_referenciados_en_workflow(nodo: object) -> set[str]:
    """Recorre recursivamente un objeto ya cargado por `yaml.safe_load`.

    Devuelve todos los nombres de secrets referenciados como
    `${{ secrets.NOMBRE }}`.

    CRÍTICO: opera sobre la estructura YA CARGADA (dicts/lists/strings), nunca sobre
    el texto crudo del archivo. `yaml.safe_load` descarta los comentarios al parsear,
    así que un `${{ secrets.X }}` (o, como en `ci-fork.yml` línea 11, la cadena
    literal `secrets.GITHUB_TOKEN` sin siquiera el envoltorio `${{ }}`) escrito dentro
    de un comentario `#` nunca llega a esta función: desaparece antes, en el parseo.
    Un regex sobre el texto crudo del archivo sí lo vería y lo contaría como un uso
    real cuando no lo es — ese es exactamente el falso positivo medido en
    `ci-fork.yml`. Recorrer el árbol ya parseado es inmune por construcción, no por
    cuidado al escribir el regex.

    Recoge también las claves de los dicts (no solo los valores) por si acaso algún
    día un secret apareciera referenciado ahí.
    """
    hallados: set[str] = set()

    if isinstance(nodo, str):
        hallados.update(PATRON_SECRET.findall(nodo))
    elif isinstance(nodo, dict):
        for clave, valor in nodo.items():
            if isinstance(clave, str):
                hallados.update(PATRON_SECRET.findall(clave))
            hallados.update(_secrets_referenciados_en_workflow(valor))
    elif isinstance(nodo, list):
        for elemento in nodo:
            hallados.update(_secrets_referenciados_en_workflow(elemento))

    return hallados


def test_workflows_esperados_existen_en_el_arbol():
    """Cada ruta de WORKFLOWS_PROPIOS debe existir como archivo en el árbol.

    Es el isomorfo del fallo de B-548: si alguien borra un workflow del árbol y no
    toca la lista del guion, el guion sigue exigiendo para siempre el `state: active`
    de algo que ya no existe. Contra la API de Actions eso es un exit 1 inarreglable
    de verdad — no hay ningún ajuste de GitHub que active un workflow cuyo archivo se
    borró, así que el único arreglo posible es quitar la entrada de la lista, y este
    test es la señal de que hay que hacerlo.
    """
    for ruta_relativa in _workflows_propios_del_guion():
        ruta = RAIZ / ruta_relativa
        assert ruta.is_file(), (
            f"WORKFLOWS_PROPIOS en {GUION} incluye '{ruta_relativa}', pero no existe "
            f"ningún archivo en {ruta}. Si el workflow se borró del árbol a "
            "propósito, quita esa entrada de WORKFLOWS_PROPIOS en el mismo commit: "
            "mientras siga ahí, el guion le exigirá para siempre `state: active` a "
            "la API de Actions sobre un archivo que no existe, y eso no tiene "
            "arreglo posible salvo borrar la entrada."
        )


def test_workflows_esperados_declaran_bloque_permissions():
    """Cada workflow propio debe declarar `permissions` a nivel raíz o en TODOS sus jobs.

    Hechos medidos hoy: `ci-fork.yml` lo declara a nivel raíz del workflow
    (`contents: read`, `actions: write`); `security-scan.yml` lo declara en su único
    job `trivy` (`contents: read`, `security-events: write`); `sync-upstream.yml` lo
    declara en sus dos jobs, `sync` (`contents: write`, `pull-requests: write`,
    `actions: write`) y `check-new-minor` (`contents: read`, `issues: write`). Nada en
    la CI protege ese bloque.

    Si alguien lo borra, el workflow no queda sin permisos: cae al ajuste de repo NO
    versionado "Workflow permissions" (Settings → Actions → General), en silencio.
    Ese ajuste vale hoy algo distinto del default que GitHub aplica a los repos
    nuevos desde 2023 (`read`), así que un borrado accidental —o un repo replicado
    para un cliente, que arranca con el default— puede tumbar pasos como
    `actions/upload-artifact` con 403 sin que nada en el propio commit lo avise. Es
    exactamente el fallo que el comentario de cabecera de `ci-fork.yml` junto al
    bloque `permissions:` existe para prevenir.

    Un workflow sin `jobs`, o con `jobs` vacío, es un fallo aparte con su propio
    mensaje: no se deja pasar por vacuidad (`all([])` da `True` y dejaría pasar un
    workflow que en realidad no tiene ningún alcance declarado en ningún sitio).
    """
    for ruta_relativa in _workflows_propios_del_guion():
        ruta = RAIZ / ruta_relativa
        workflow = yaml.safe_load(ruta.read_text(encoding="utf-8"))

        if "permissions" in workflow:
            continue  # declarado a nivel raíz: cubre todos los jobs por definición.

        jobs = workflow.get("jobs") or {}
        assert jobs, (
            f"{ruta_relativa} no declara `permissions` a nivel raíz y tampoco tiene "
            "ningún job — no hay nada de donde heredar un alcance explícito. Sin "
            "`permissions` en algún sitio, el workflow entero corre con el ajuste de "
            "repo no versionado 'Workflow permissions' (Settings → Actions → "
            "General), que puede cambiar sin que este commit se entere."
        )

        jobs_sin_permisos = sorted(
            nombre_job
            for nombre_job, definicion_job in jobs.items()
            if not isinstance(definicion_job, dict)
            or "permissions" not in definicion_job
        )
        assert not jobs_sin_permisos, (
            f"{ruta_relativa} no declara `permissions` a nivel raíz, y el/los job(s) "
            f"{jobs_sin_permisos} tampoco lo declaran. Mientras falte en los dos "
            "sitios, ese workflow (o esos jobs) heredan el ajuste de repo NO "
            "versionado 'Workflow permissions' (Settings → Actions → General) en "
            "silencio: nada en este commit ni en la CI avisa del cambio de alcance. "
            "Arréglalo añadiendo `permissions:` a nivel raíz del workflow, o a cada "
            "job de la lista de arriba."
        )


def test_secrets_referenciados_estan_en_la_lista_esperada():
    r"""Todo `${{ secrets.X }}` (X != GITHUB_TOKEN) en un workflow propio debe estar en SECRETS_ESPERADOS.

    `GITHUB_TOKEN` queda fuera a propósito: es el token efímero que GitHub inyecta
    solo en cada run, no un secret que alguien configuró a mano en el repo, así que
    no tiene sentido pedir que aparezca en una lista de secrets "esperados".

    Recorre el YAML ya cargado con `yaml.safe_load`, nunca el texto crudo del
    archivo — ver el docstring de `_secrets_referenciados_en_workflow` para el
    porqué exacto: `ci-fork.yml` línea 11 nombra `secrets.GITHUB_TOKEN` dentro de un
    comentario `#`, y ese comentario desaparece al parsear con `yaml.safe_load`. Un
    regex sobre el archivo tal cual lo vería como un uso real; recorrer la estructura
    cargada es inmune a ese falso positivo medido.

    Si este test se pone rojo: o bien un workflow propio empezó a usar un secret
    nuevo y hay que añadirlo a `SECRETS_ESPERADOS` en el guion **en el mismo commit**,
    o bien es una señal a tomar en serio por otro motivo — un secret que el workflow
    referencia pero que no existe configurado en el repo no falla el run: GitHub lo
    resuelve como cadena vacía, sin ningún error visible.
    """
    esperados = _secrets_esperados_del_guion()

    for ruta_relativa in _workflows_propios_del_guion():
        ruta = RAIZ / ruta_relativa
        workflow = yaml.safe_load(ruta.read_text(encoding="utf-8"))

        referenciados = _secrets_referenciados_en_workflow(workflow) - {
            SECRET_IMPLICITO
        }
        inesperados = sorted(referenciados - esperados)

        assert not inesperados, (
            f"{ruta_relativa} referencia el/los secret(s) {inesperados} vía "
            "`${{ secrets.* }}`, pero no está en SECRETS_ESPERADOS de "
            f"{GUION}. Añádelo a esa constante en el mismo commit que introduce el "
            "uso. Si no lo haces, el workflow sigue corriendo: un secret que se "
            "referencia pero que no existe configurado en el repo llega como cadena "
            "vacía, sin ningún error — el fallo, si lo hay, aparece después y lejos "
            "de aquí."
        )


def test_lista_esperada_no_incluye_rutas_dinamicas():
    """Ninguna entrada de WORKFLOWS_PROPIOS puede caer fuera de `.github/workflows/`.

    Blinda un gotcha medido: la API `actions/workflows` de GitHub devuelve, junto a
    los workflows reales, una entrada SINTÉTICA (`dynamic/dependabot/update-graph`,
    nombre visible "Dependency Graph") que no tiene ningún archivo correspondiente en
    el árbol. Si alguien la copia a `WORKFLOWS_PROPIOS` pensando que es un workflow
    más, `test_workflows_esperados_existen_en_el_arbol` la buscaría como archivo y
    fabricaría una deriva falsa el día uno — un fallo que no señala nada roto, solo
    una entrada mal copiada. Este test la atrapa antes, con un mensaje que explica
    qué pasó en vez de dejar que parezca un workflow borrado.
    """
    for ruta_relativa in _workflows_propios_del_guion():
        assert ruta_relativa.startswith(PREFIJO_WORKFLOWS), (
            f"WORKFLOWS_PROPIOS en {GUION} incluye '{ruta_relativa}', que no empieza "
            f"por '{PREFIJO_WORKFLOWS}'. Si esto vino de copiar una fila de la API "
            "`actions/workflows` de GitHub, revisa si es la entrada SINTÉTICA "
            "'dynamic/dependabot/update-graph' (nombre visible 'Dependency Graph'): "
            "no tiene archivo en el árbol y nunca debería estar en esta lista."
        )


def test_guion_y_workflows_existen():
    """Guarda mínima: el guion existe y las dos constantes se pueden leer.

    Si esto falla, el problema no es una deriva entre el guion y los workflows sino
    que falta una pieza por completo — un fallo distinto y anterior al que verifican
    los demás tests de este archivo.

    Asimetría a propósito entre las dos constantes: WORKFLOWS_PROPIOS no puede estar
    vacía (sin workflows propios no hay nada que este guion proteja) pero
    SECRETS_ESPERADOS legítimamente sí puede estarlo hoy — lo que se comprueba es que
    la LÍNEA exista (el guion sigue teniendo el campo), no que su valor sea no vacío.
    """
    assert GUION.exists(), f"No existe {GUION}."

    workflows = _workflows_propios_del_guion()
    assert workflows, f"{GUION} existe pero WORKFLOWS_PROPIOS está vacía."

    contenido = GUION.read_text(encoding="utf-8")
    assert (
        re.search(r'^SECRETS_ESPERADOS="(.*)"$', contenido, re.MULTILINE) is not None
    ), (
        f'{GUION} existe pero no tiene una línea `SECRETS_ESPERADOS="..."`. A '
        "diferencia de WORKFLOWS_PROPIOS, su valor sí puede estar legítimamente "
        "vacío (hoy lo está: ningún workflow propio usa un secret distinto de "
        "GITHUB_TOKEN) — lo que no puede faltar es la línea misma."
    )
