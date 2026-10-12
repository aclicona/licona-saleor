"""Candado de raíz (B-1232): `LineInfo` y sus subclases comparan por identidad.

`LineInfo`, `CheckoutLineInfo` y `EditableOrderLineInfo` son `@dataclass(eq=False)`:
`==` y `hash` son los de `object` (identidad). Con `eq=True`, `==` comparaba campo a
campo y delegaba en `CheckoutLine.__eq__` (variante + cantidad), de modo que dos líneas
distintas del mismo checkout (`forceNewLine`) eran "iguales" y `x in lines_info`,
`.remove`, `.index` o `.count` confundían una con otra (B-1223 / B-1225 / B-1227).

Si un merge de upstream revierte `eq=False`, este test falla. El candado heurístico
`test_fork_checkout_line_membership_drift.py` (P1-P3) queda como segunda línea.

No usa base de datos: se construyen instancias con dobles simples.
"""

import dataclasses
from types import SimpleNamespace

import pytest

from ..checkout.fetch import CheckoutLineInfo
from ..core.pricing.interface import LineInfo
from ..order.fetch import EditableOrderLineInfo

CLASES = [LineInfo, CheckoutLineInfo, EditableOrderLineInfo]


def _instancia(cls, line):
    campos = {
        f.name: None
        for f in dataclasses.fields(cls)
        if f.default is dataclasses.MISSING and f.default_factory is dataclasses.MISSING
    }
    campos.update(line=line, collections=[], discounts=[], rules_info=[])
    return cls(
        **{
            k: v
            for k, v in campos.items()
            if k in {f.name for f in dataclasses.fields(cls)}
        }
    )


@pytest.mark.parametrize("cls", CLASES)
def test_dataclass_declara_eq_false(cls):
    assert cls.__dataclass_params__.eq is False


@pytest.mark.parametrize("cls", CLASES)
def test_igual_contenido_no_es_igual(cls):
    # given: la misma línea subyacente, dos infos con contenido idéntico
    linea = SimpleNamespace(pk=1)
    a = _instancia(cls, linea)
    b = _instancia(cls, linea)

    # then: distintas por identidad
    assert a != b
    assert a == a  # noqa: PLR0124
    assert a not in [b]
    assert a in [a, b]
    assert [a, b].index(b) == 1
    assert [a, b].count(a) == 1


@pytest.mark.parametrize("cls", CLASES)
def test_hashable_por_identidad(cls):
    linea = SimpleNamespace(pk=1)
    a = _instancia(cls, linea)
    b = _instancia(cls, linea)

    assert len({a, b}) == 2
    assert {a: 1}[a] == 1
    assert b not in {a: 1}


def test_remove_quita_la_instancia_exacta():
    linea = SimpleNamespace(pk=1)
    a = _instancia(CheckoutLineInfo, linea)
    b = _instancia(CheckoutLineInfo, linea)
    infos = [a, b]

    infos.remove(b)

    assert infos == [a]
    assert infos[0] is a


def _subclases(cls):
    for sub in cls.__subclasses__():
        yield sub
        yield from _subclases(sub)


def test_toda_subclase_de_line_info_declara_eq_false():
    subclases = set(_subclases(LineInfo))

    assert {CheckoutLineInfo, EditableOrderLineInfo} <= subclases
    for cls in subclases:
        assert cls.__dataclass_params__.eq is False, cls
        assert cls.__eq__ is object.__eq__, cls
