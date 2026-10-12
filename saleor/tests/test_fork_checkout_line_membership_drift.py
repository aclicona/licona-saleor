"""Candado contra pertenencia por contenido sobre líneas de checkout (B-1223 / B-1225 / B-1230).

`CheckoutLine.__eq__` (`saleor/checkout/models.py`) compara solo `variant` y
`quantity`, y `LineInfo` es un `@dataclass` cuyo `==` delega en ese `__eq__`.
Dos líneas del mismo checkout con igual variante y cantidad (`forceNewLine`)
son por tanto "iguales", y cualquier `linea in lista`, `lista.remove(linea)`,
`lista.index(linea)` o `lista.count(linea)` las confunde: descartes silenciosos
de precio personalizado, voucher "una vez por pedido" aplicado dos veces,
línea equivocada eliminada. B-1223 arregló los sitios existentes comparando por
pk / `id()` (ver `_is_same_line_in` en `saleor/checkout/utils.py` y
`_remove_line_infos_by_identity` en `saleor/discount/utils/promotion.py`).

Este test es el candado para que no reaparezcan, p. ej. tras un sync con
upstream: recorre con `ast` el código de producción de `saleor/` y marca

- P1: `x in ys` / `x not in ys` con `x` llamado `line`, `*_line`, `line_info` o
  `*_line_info` e `ys` con nombre de colección de líneas;
- P2: `ys.remove(x)`, `ys.index(x)`, `ys.count(x)` con `ys` de ese tipo;
- P3 (B-1230): `x in ys` / `x not in ys` con CUALQUIER `x` cuando `ys` es una
  colección de `LineInfo` (`lines_info`, `*_line_infos`, `order_lines_info`…).
  `LineInfo`/`CheckoutLineInfo` son `@dataclass` con `eq=True` que delegan en
  `CheckoutLine.__eq__`; P1 solo miraba el nombre del operando izquierdo, así que
  `info in lines_info` (o `i`, `item`, `candidate`…) pasaba. P2 ya cubría
  `lines_info.remove/index/count(x)` por el nombre de la colección.

Si marca un sitio nuevo: compara por pk / `id()`, o añádelo a `LISTA_BLANCA`
con justificación. Una entrada obsoleta de la lista blanca también falla.

LIMITACIÓN: es una heurística por NOMBRE de variable. Se elude renombrando
(`ln in coleccion`) y puede dar falsos positivos (de ahí la lista blanca). Es una
red de seguridad, no una prueba de ausencia. La solución de fondo sería que
upstream elimine `__eq__/__ne__/__hash__` legados o use `@dataclass(eq=False)`
en `LineInfo`; si lo hace, este candado puede retirarse.

No usa la base de datos, fixtures ni red: solo lee código fuente.
"""

import ast
import re
from pathlib import Path

import saleor

RAIZ_SALEOR = Path(saleor.__file__).resolve().parent
RAIZ_REPO = RAIZ_SALEOR.parent

IZQUIERDA = re.compile(r"(^|_)line(_info)?$")
DERECHA = re.compile(r"(^|_)lines?(_infos?)?(_|$)")
DERECHA_EXCLUIDA = re.compile(
    r"(^|_)(ids?|pks?|by_ids?|by_pks?|data|map|dict|qs|queryset|payload|inputs?"
    r"|str|text)(_|$)"
)
DERECHA_EXTRA = {"to_delete", "to_update"}
METODOS = {"remove", "index", "count"}
# B-1230: colecciones de LineInfo / CheckoutLineInfo (el operando puede llamarse como sea).
COLECCION_DE_INFOS = re.compile(r"(^|_)(lines_info|lines?_infos?)(_|$)")

# (ruta relativa a la raíz del repo, línea fuente .strip()) -> justificación
LISTA_BLANCA = {
    (
        "saleor/checkout/problems.py",
        "lines = [line for line in lines if line not in not_available_lines]",
    ): (
        "Benigno: la disponibilidad depende solo del listing del producto; dos "
        "líneas de la misma variante son ambas disponibles o ambas no."
    ),
    (
        "saleor/graphql/order/mutations/order_lines_create.py",
        "if force_new_line or variants_from_existing_lines.count(variant.pk) > 1:",
    ): "Lista de enteros (pks), no de líneas.",
    (
        "saleor/order/utils.py",
        "order_line_discounts.remove(discount)",
    ): "OrderLineDiscount: igualdad de Django por pk.",
}


def _terminal(nodo) -> str | None:
    if isinstance(nodo, ast.Name):
        return nodo.id
    if isinstance(nodo, ast.Attribute):
        return nodo.attr
    return None


def _es_coleccion_de_lineas(nombre: str | None) -> bool:
    if not nombre:
        return False
    if nombre in DERECHA_EXTRA:
        return True
    return bool(DERECHA.search(nombre)) and not DERECHA_EXCLUIDA.search(nombre)


def _es_codigo_de_produccion(ruta: Path) -> bool:
    texto = ruta.as_posix()
    if "/migrations/" in texto or "/tests/" in texto:
        return False
    return not (ruta.name.startswith("test_") or ruta.name == "conftest.py")


def _es_coleccion_de_infos(nombre: str | None) -> bool:
    return (
        bool(nombre)
        and bool(COLECCION_DE_INFOS.search(nombre))
        and not DERECHA_EXCLUIDA.search(nombre)
    )


def _es_aciertos_p3(nodo) -> bool:
    return (
        isinstance(nodo, ast.Compare)
        and len(nodo.ops) == 1
        and isinstance(nodo.ops[0], ast.In | ast.NotIn)
        and _es_coleccion_de_infos(_terminal(nodo.comparators[0]))
    )


def _es_aciertos_p1(nodo) -> bool:
    if not (
        isinstance(nodo, ast.Compare)
        and len(nodo.ops) == 1
        and isinstance(nodo.ops[0], ast.In | ast.NotIn)
        and isinstance(nodo.left, ast.Name)
    ):
        return False
    return bool(IZQUIERDA.search(nodo.left.id)) and _es_coleccion_de_lineas(
        _terminal(nodo.comparators[0])
    )


def _es_aciertos_p2(nodo) -> bool:
    return (
        isinstance(nodo, ast.Call)
        and isinstance(nodo.func, ast.Attribute)
        and nodo.func.attr in METODOS
        and bool(nodo.args)
        and _es_coleccion_de_lineas(_terminal(nodo.func.value))
    )


def escanear(raiz_saleor: Path) -> set[tuple[str, int, str]]:
    """Devuelve {(ruta relativa, línea, código)} de los sitios sospechosos."""
    aciertos = set()
    for ruta in sorted(raiz_saleor.rglob("*.py")):
        if not _es_codigo_de_produccion(ruta):
            continue
        texto = ruta.read_text(encoding="utf-8")
        lineas = texto.splitlines()
        relativa = ruta.relative_to(raiz_saleor.parent).as_posix()
        for nodo in ast.walk(ast.parse(texto, filename=str(ruta))):
            if _es_aciertos_p1(nodo) or _es_aciertos_p2(nodo) or _es_aciertos_p3(nodo):
                codigo = lineas[nodo.lineno - 1].strip()
                aciertos.add((relativa, nodo.lineno, codigo))
    return aciertos


def test_no_hay_pertenencia_por_contenido_sobre_lineas_de_checkout():
    aciertos = escanear(RAIZ_SALEOR)

    nuevos = sorted(a for a in aciertos if (a[0], a[2]) not in LISTA_BLANCA)

    assert not nuevos, (
        "Pertenencia por contenido sobre líneas (CheckoutLine.__eq__ compara "
        "variante y cantidad, B-1223/B-1225):\n"
        + "\n".join(f"  {r}:{n}:{c}" for r, n, c in nuevos)
        + "\ncompara por pk/id(), ver `_is_same_line_in` y "
        "`_remove_line_infos_by_identity`, o añade a la lista blanca con "
        "justificación."
    )


def test_la_lista_blanca_no_tiene_entradas_obsoletas():
    vistos = {(r, c) for r, _, c in escanear(RAIZ_SALEOR)}

    obsoletas = sorted(set(LISTA_BLANCA) - vistos)

    assert not obsoletas, (
        "Entradas de LISTA_BLANCA que ya no coinciden con ningún acierto "
        f"(retíralas): {obsoletas}"
    )


# B-1227: (ruta, "Clase.__eq__") -> por qué la igualdad por contenido es inocua.
# Una definición NUEVA de `__eq__` en producción obliga a revisar si hay `in` /
# `.remove` / `==` sobre colecciones de esas instancias (mismo riesgo que B-1223).
EQ_POR_CONTENIDO_REVISADOS = {
    ("saleor/account/models.py", "Address.__eq__"): (
        "Compara as_data() sin pk. Intencional: checkout/utils.py y "
        "delivery_context.py preguntan 'misma dirección' por contenido."
    ),
    ("saleor/checkout/models.py", "CheckoutLine.__eq__"): (
        "Origen de B-1223; sitios de pertenencia arreglados por pk/id() y "
        "vigilados por los tests de arriba."
    ),
    ("saleor/checkout/models.py", "CheckoutLine.__ne__"): "Par de __eq__.",
    ("saleor/core/db/fields.py", "NonDatabaseFieldBase.__eq__"): (
        "Campo de esquema (creation_counter), no es dato de negocio."
    ),
    ("saleor/webhook/observability/payload_schema.py", "JsonTruncText.__eq__"): (
        "Valor inmutable de texto truncado; igualdad por valor es lo correcto."
    ),
}


def _eq_definidos(raiz_saleor: Path) -> set[tuple[str, str]]:
    encontrados = set()
    for ruta in sorted(raiz_saleor.rglob("*.py")):
        if not _es_codigo_de_produccion(ruta):
            continue
        relativa = ruta.relative_to(raiz_saleor.parent).as_posix()
        arbol = ast.parse(ruta.read_text(encoding="utf-8"), filename=str(ruta))
        for clase in ast.walk(arbol):
            if not isinstance(clase, ast.ClassDef):
                continue
            for miembro in clase.body:
                if isinstance(miembro, ast.FunctionDef) and miembro.name in (
                    "__eq__",
                    "__ne__",
                ):
                    encontrados.add((relativa, f"{clase.name}.{miembro.name}"))
    return encontrados


def test_no_hay_eq_por_contenido_sin_revisar():
    nuevos = sorted(_eq_definidos(RAIZ_SALEOR) - set(EQ_POR_CONTENIDO_REVISADOS))

    assert not nuevos, (
        "Nuevo `__eq__`/`__ne__` en producción (B-1227). Revisa si hay `in`, "
        "`.remove`, `.index`, `.count` o `==` sobre colecciones de esas "
        "instancias (dos objetos distintos e indistinguibles se confundirían) "
        "y añádelo a EQ_POR_CONTENIDO_REVISADOS con justificación:\n"
        + "\n".join(f"  {r}: {c}" for r, c in nuevos)
    )


def test_eq_revisados_no_tiene_entradas_obsoletas():
    obsoletas = sorted(set(EQ_POR_CONTENIDO_REVISADOS) - _eq_definidos(RAIZ_SALEOR))

    assert not obsoletas, f"Entradas que ya no existen (retíralas): {obsoletas}"
