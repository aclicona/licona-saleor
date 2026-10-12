"""Candado AST (B-1246): prohibe `transaction.on_commit(lambda: ...)` que lea una variable de bucle.

El lambda se ejecuta tras el commit, cuando el bucle ya termino: lee el ULTIMO valor de la
variable, no el de la iteracion en que se registro. Con dos stocks agotados en la misma llamada el
evento se emitia dos veces con el ultimo stock y el otro no recibia aviso. Ya se arreglo cuatro
veces (B-1236, B-1238, B-1243 x2) en `saleor/warehouse/management.py` con `functools.partial`.

Ruff B023 detecta lo mismo pero esta en el `ignore` global (heredado de upstream) y hoy tiene
hallazgos en otros sitios, por eso el candado es este test. No usa base de datos.

Arreglo correcto: `functools.partial(f, valor)` o fijar el valor como parametro por defecto
(`lambda valor=valor: f(valor)`). Ver UPGRADE_NOTES.md (B-1246).
"""

import ast
from pathlib import Path

SALEOR_ROOT = Path(__file__).resolve().parents[2]
# Las migraciones no registran callbacks de commit con bucles, y los tests pueden construir
# lambdas a proposito; se excluyen para que el recorrido sea rapido.
EXCLUDED_PARTS = {"migrations", "tests"}
_SCOPE_NODES = (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda, ast.ClassDef)
_LOOP_NODES = (ast.For, ast.AsyncFor)
_COMPREHENSIONS = (ast.ListComp, ast.SetComp, ast.DictComp, ast.GeneratorExp)


def _target_names(target: ast.AST) -> set[str]:
    return {
        n.id
        for n in ast.walk(target)
        if isinstance(n, ast.Name) and isinstance(n.ctx, ast.Store)
    }


def _names_bound_in(nodes: list[ast.AST]) -> set[str]:
    """Nombres que se (re)asignan en `nodes`, sin entrar en funciones/lambdas anidadas."""
    bound: set[str] = set()
    stack = list(nodes)
    while stack:
        node = stack.pop()
        if isinstance(node, ast.Name) and isinstance(node.ctx, ast.Store):
            bound.add(node.id)
        if isinstance(node, _SCOPE_NODES):
            continue
        stack.extend(ast.iter_child_nodes(node))
    return bound


def _lambda_params(node: ast.Lambda) -> set[str]:
    args = node.args
    all_args = [*args.posonlyargs, *args.args, *args.kwonlyargs]
    if args.vararg:
        all_args.append(args.vararg)
    if args.kwarg:
        all_args.append(args.kwarg)
    return {a.arg for a in all_args}


def _free_loads(node: ast.Lambda) -> set[str]:
    """Nombres leidos en el cuerpo del lambda que no son sus parametros.

    Los parametros por defecto (`lambda x=x: ...`) se evaluan al crear el lambda, fuera del
    cuerpo, asi que no cuentan: solo se inspecciona `node.body`.
    """
    loads = {
        n.id
        for n in ast.walk(node.body)
        if isinstance(n, ast.Name) and isinstance(n.ctx, ast.Load)
    }
    return loads - _lambda_params(node)


def _loop_bound_names(ancestors: list[ast.AST]) -> set[str]:
    """Variables ligadas por los bucles que envuelven al lambda (hasta el limite de funcion)."""
    bound: set[str] = set()
    for node in reversed(ancestors):
        if isinstance(node, _SCOPE_NODES):
            break
        if isinstance(node, _LOOP_NODES):
            bound |= _target_names(node.target)
            bound |= _names_bound_in(node.body)
        elif isinstance(node, _COMPREHENSIONS):
            for generator in node.generators:
                bound |= _target_names(generator.target)
    return bound


def _is_on_commit(call: ast.Call) -> bool:
    func = call.func
    return (isinstance(func, ast.Name) and func.id == "on_commit") or (
        isinstance(func, ast.Attribute) and func.attr == "on_commit"
    )


def _on_commit_callbacks(call: ast.Call) -> list[ast.AST]:
    keyword_funcs = [kw.value for kw in call.keywords if kw.arg == "func"]
    return [*call.args[:1], *keyword_funcs]


def find_late_binding_on_commit(tree: ast.AST) -> list[tuple[int, str]]:
    """Devuelve (linea, variable) por cada `on_commit(lambda ...)` que lee una variable de bucle."""
    findings: list[tuple[int, str]] = []

    def visit(node: ast.AST, ancestors: list[ast.AST]) -> None:
        if isinstance(node, ast.Call) and _is_on_commit(node):
            for callback in _on_commit_callbacks(node):
                if not isinstance(callback, ast.Lambda):
                    continue
                late = _free_loads(callback) & _loop_bound_names(ancestors)
                findings.extend((callback.lineno, name) for name in sorted(late))
        for child in ast.iter_child_nodes(node):
            visit(child, [*ancestors, node])

    visit(tree, [])
    return findings


def _source_files():
    for path in sorted(SALEOR_ROOT.rglob("*.py")):
        relative_parts = path.relative_to(SALEOR_ROOT).parts
        if EXCLUDED_PARTS.intersection(relative_parts[:-1]):
            continue
        if path.name.startswith("test_") or path.name == "conftest.py":
            continue
        yield path


def test_no_on_commit_lambda_reads_a_loop_variable():
    # given
    violations: list[str] = []

    # when
    for path in _source_files():
        source = path.read_text(encoding="utf-8")
        if "on_commit" not in source:
            continue
        for line, name in find_late_binding_on_commit(ast.parse(source, str(path))):
            violations.append(
                f"{path.relative_to(SALEOR_ROOT.parent)}:{line} lee `{name}`"
            )

    # then
    assert not violations, (
        "on_commit(lambda) que lee una variable de bucle (late binding: al ejecutarse tras el "
        "commit vera el ultimo valor). Usa functools.partial(f, valor) o `lambda v=v: f(v)`. "
        "Ver UPGRADE_NOTES.md (B-1246):\n" + "\n".join(violations)
    )


def test_detector_flags_loop_variable_and_accepts_safe_forms():
    # given
    unsafe = "for s in stocks:\n    transaction.on_commit(lambda: notify(s))\n"
    unsafe_body_var = (
        "for a in xs:\n    s = a.stock\n    transaction.on_commit(lambda: notify(s))\n"
    )
    unsafe_comprehension = "[on_commit(lambda: f(x)) for x in xs]\n"
    safe_partial = "for s in stocks:\n    on_commit(partial(notify, s))\n"
    safe_default = "for s in stocks:\n    on_commit(lambda s=s: notify(s))\n"
    safe_no_loop = "def f(s):\n    on_commit(lambda: notify(s))\n"

    # when / then
    assert find_late_binding_on_commit(ast.parse(unsafe)) == [(2, "s")]
    assert find_late_binding_on_commit(ast.parse(unsafe_body_var)) == [(3, "s")]
    assert find_late_binding_on_commit(ast.parse(unsafe_comprehension)) == [(1, "x")]
    assert find_late_binding_on_commit(ast.parse(safe_partial)) == []
    assert find_late_binding_on_commit(ast.parse(safe_default)) == []
    assert find_late_binding_on_commit(ast.parse(safe_no_loop)) == []
