# UPGRADE NOTES — licona-saleor fork

Este archivo documenta **todos los cambios aplicados encima del upstream de Saleor**.
Antes de cada actualización de upstream, revisar esta lista para detectar conflictos potenciales.

> **Regla de oro:** Solo actualizar de una minor a la siguiente consecutiva.
> Para ir de 3.22 → 3.24 hay que pasar por 3.23 primero.

---

## B-1449 — preDeploy de saleor-api en config-as-code incluye el chequeo de índices INVALID (2026-10-18)

El 2026-10-13 Andrés cambió en el panel de Railway el Pre-deploy Command de saleor-api a
`sh scripts/check-invalid-indexes.sh && python manage.py migrate --noinput` (B-1290). `railway.saleor-api.json`
(`deploy.preDeployCommand`) se alinea con el panel y `scripts/tests/test_railway_config.sh` exige ahora el chequeo y
`migrate`. Sin esto, un deploy desde el json quitaría el chequeo. Solo config/tests, sin cambio de código de Saleor.

---

## B-1416 — tests de `scripts/tests` aislados de `GIT_DIR` heredado (2026-10-17)

Dentro de un hook de git, `GIT_DIR` absoluto gana sobre `git -C`: cuatro tests de guiones (`test_resolve_uv_lock`,
`test_publish_upstream_tags`, `test_resolve_venv_python`, `test_with_venv`) escribían `user.name=t`/`user.email=t@t`,
commits y ramas en el repo externo (así aparecieron commits con autor `t <t@t>`). Cada uno hace ahora
`unset $(git rev-parse --local-env-vars)` al inicio; `test_tests_aislados_de_git_dir.sh` lo vigila ejecutando cada
test con `GIT_DIR` apuntando a un repo centinela. Solo `scripts/tests/`, sin efecto en runtime.

---

## B-1020 — `test_http_client_disallows_private_ip_ranges`: DNS fijado a la IP de la cassette (2026-10-17)

El test (código de **upstream**, `Fix test http client (#17262)`) hace una resolución DNS real de `example.com`.
`requests-hardened` conecta a la IP resuelta y `vcrpy` construye la URL como `https://<ip>/` sin corchetes; en un
equipo con IPv6 (p. ej. el Mac de desarrollo) la IP es IPv6 y el matcher `port` de VCR falla con
`Port could not be cast to integer value`. En CI (sin IPv6) pasa. El cliente (`saleor/core/http_client.py`) no tiene
el fallo: `requests_hardened` sí entrecomilla IPv6 con `[]`.

- **Arreglo:** solo test. `saleor/core/tests/test_http_client.py` fija `socket.getaddrinfo` de `example.com` a la IPv4
  de la cassette (`23.215.0.136`) y añade `test_http_client_disallows_private_ipv6_ranges` (`::1`, `fd00::1`, `fe80::1`).
- **Al sincronizar upstream:** si el conflicto aparece en ese archivo, conservar el parche; si upstream ya lo corrigió
  (a 2026-10-17 `upstream/main` y `upstream/3.23` siguen idénticos a nuestro archivo), descartar esta entrada.

---

## B-1234 — fuga de estado: `DeprecatedDummyCreditCardGatewayPlugin.DEFAULT_ACTIVE` quedaba en `True` entre tests (2026-10-16)

El fixture autouse `setup_dummy_credit_card_gateway` de `saleor/payment/gateways/dummy_credit_card/tests/test_dummy_credit_card.py`
(código de **upstream**, commit `f3c1a9678d` «Deprecate plugins») asignaba `DEFAULT_ACTIVE = True` directamente sobre la
clase sin restaurarlo. Con `-n 4`, los tests del mismo worker que corrían después veían el gateway `dummy_credit_card`
activo y `test_checkout_available_payment_gateways` y `..._currency_specified_USD` (`saleor/graphql/checkout/tests/test_checkout.py`)
fallaban por un gateway de más. Sueltos pasaban.

- **Arreglo:** `monkeypatch.setattr(..., "DEFAULT_ACTIVE", True)` en ese fixture (solo test, sin código de producción).
- **Al sincronizar upstream:** si el conflicto aparece en ese archivo, conservar el `monkeypatch`; si upstream ya lo corrigió, descartar esta entrada.

---

## B-1288 — `scripts/check-invalid-indexes.sh`: detectar índices INVALID antes de migrar (2026-10-13)

El sync 3.23.41 trajo migraciones de upstream `atomic = False` con `CREATE UNIQUE INDEX CONCURRENTLY` seguido de
`ADD CONSTRAINT ... USING INDEX`, sin `IF NOT EXISTS`. Si el pre-deploy de Railway (`migrate --noinput`) se corta entre
los dos pasos, queda un índice con `indisvalid = false` y TODO despliegue posterior falla con «already exists» sin
explicar la causa.

- **Qué hace:** `scripts/check-invalid-indexes.sh` consulta `pg_index` + `pg_class` + `pg_namespace` (excluye
  `pg_catalog`, `information_schema`, `pg_toast`) vía `manage.py shell -c` y **solo lee**: nunca borra. Mismo estilo
  que `check-migrations.sh` (sh POSIX, `${PYTHON:-python}`, etiqueta `[check-invalid-indexes]`, todo por stdout).
- **Contrato:** `0` no hay inválidos · `1` los hay (lista `esquema.indice (tabla)` + receta literal
  `DROP INDEX CONCURRENTLY IF EXISTS "esquema"."indice";` y re-desplegar; avisa de que un `CREATE INDEX CONCURRENTLY`
  en curso también aparece como inválido) · `2` no se pudo responder (base caída, entorno roto; "no sé", no "hay").
  Un crash silencioso nunca se lee como 0: el éxito exige la marca `CHECK_DONE`.
- **Tests:** `scripts/tests/test_check_invalid_indexes.sh` (PYTHON falso, sin Postgres) y
  `scripts/tests/test_check_invalid_indexes_pg.sh` (Postgres efímero real con un índice INVALID fabricado
  con `CREATE UNIQUE INDEX CONCURRENTLY` sobre duplicados; hace SKIP si no hay `initdb` o Django).
- **Cableado PENDIENTE DE ANDRÉS (no hecho a propósito):** el `preDeployCommand` del panel de Railway de `saleor-api`
  debería pasar a `sh scripts/check-invalid-indexes.sh && python manage.py migrate --noinput`. No se tocó
  `railway.saleor-*.json` (reflejan el panel; `test_railway_config.sh` y `drift_config.py` se pondrían en rojo). Al
  cambiar el panel, actualizar el JSON en el mismo paso. Nota: con el `&&`, exit 1 también detiene el despliegue
  (deseado: obliga a mirar el índice).
- **Upstream:** archivo nuevo del fork; no choca con ningún merge.

---

## B-1283 — sync upstream 3.23.41: conflicto en `saleor/checkout/utils.py` (2026-10-13)

El merge de `3.23.41` dejo marcadores en `saleor/checkout/utils.py`: el fork anade `_is_same_line_in` (B-1223,
pertenencia por pk) y upstream anade `_match_lines_data_to_locked_lines` (apunta las lineas de entrada a las que ya existen
tras bloquear el checkout; se usa en `add_variants_to_checkout`). No se excluyen: **conviven las
dos funciones**, una tras otra. B-1223 queda intacto (los 3 usos de `_is_same_line_in` en `_append_line_to_update`
siguen) y el codigo nuevo de upstream no hace `in`/`not in` sobre `CheckoutLine`: indexa por `variant_id` (`defaultdict`).
Sin ajustes adicionales en otros sitios.

**Al hacer merge de upstream:** si vuelve a chocar en ese bloque, conservar ambas funciones.

---

## B-1232 — `LineInfo` y sus subclases comparan por identidad: `@dataclass(eq=False)` (2026-10-11)

Cierre de raiz de B-1223 / B-1227 / B-1230. El candado de B-1230 (P3) es una heuristica por NOMBRE de coleccion: una
coleccion de infos llamada `items`/`infos`/`rest`, `set(lines_info)`, un `dict` con infos como clave o un `==` directo
entre dos infos lo eluden. En vez de seguir ampliando la heuristica, las clases dejan de comparar por contenido:

- `LineInfo` (`saleor/core/pricing/interface.py`), `CheckoutLineInfo` (`saleor/checkout/fetch.py`) y
  `EditableOrderLineInfo` (`saleor/order/fetch.py`) pasan de `@dataclass` a `@dataclass(eq=False)`. Una subclase
  `@dataclass` con eq por defecto REGENERARIA `__eq__`, por eso las tres llevan `eq=False`. `==` y `hash` son los de
  `object` (identidad): dos infos con contenido igual son distintas y `x in [copia]` es `False`.
- Antes eran **no hashables** (eq=True sin frozen => `__hash__ = None`); ahora son hashables por identidad (ningun uso
  de produccion las metia en `set`/`dict`, asi que no cambia nada).
- `OrderLineInfo` (no hereda de `LineInfo`, campo `line` = `OrderLine` que compara por pk) queda como estaba.

**Inventario (AST, `saleor/` con tests): 0 usos de produccion dependian de la igualdad por contenido.** El unico `==`
entre infos en produccion es `order/fetch.py` `reattach_apply_once_per_order_voucher_info`
(`get_the_cheapest_line(lines_info) == initial_cheapest_line_info`), y ambos operandos salen de la MISMA lista
(`order/calculations.py`: `initial_cheapest_line = get_the_cheapest_line(lines_info)` antes de mutar), asi que la
identidad es equivalente (y mas correcta). `voucher.py:219` y `promotion.py:442` ya comparaban por `id()`.
Dependian de la igualdad por contenido solo **tests**, reescritos sin cambiar lo que prueban:
- ~50 tests (`saleor/graphql/checkout/tests/**`, `saleor/graphql/account/tests/queries/test_me.py`,
  `saleor/checkout/tests/test_order_from_checkout.py`) hacian `mock.assert_called_with(..., lines)` (o con un
  `CheckoutInfo`, que lleva `lines`) con lineas vueltas a leer con `fetch_checkout_lines`; ahora pasan
  `SameLineInfos(lines)` / `SameCheckoutInfo(checkout_info)` (`saleor/tests/utils.py`), que exigen misma clase, misma
  linea (pk) y el resto de campos iguales uno a uno (lo que comprobaba el `==` anterior).
- `saleor/checkout/tests/test_line_identity.py`: la precondicion `info_a == info_b` pasa a
  `info_a.line == info_b.line` y `info_a != info_b`.

**Candado:** `saleor/tests/test_fork_line_info_identity.py` afirma `__dataclass_params__.eq is False` en las tres
clases, que dos instancias de contenido igual son `!=`, `not in`, no colisionan en `set`/`dict` y `list.remove`
quita la instancia exacta. Sin base de datos.

**Al hacer merge de upstream:** si el merge revierte alguno de los `eq=False` (p. ej. un conflicto en esas tres
declaraciones o una subclase nueva con `@dataclass` a secas), `test_fork_line_info_identity.py` falla: reponer
`eq=False`. Una subclase nueva de `LineInfo` con `@dataclass` a secas tambien hace fallar el test
(`test_toda_subclase_de_line_info_declara_eq_false` recorre `__subclasses__` de las clases ya importadas).
`eq=False` es la defensa de raiz; el candado heuristico P1-P3 de B-1223/B-1225/B-1230 NO se retira y queda como
segunda linea (cubre `CheckoutLine.__eq__`, que sigue comparando por variante + cantidad).

---

## B-1230 — candado ampliado a colecciones de LineInfo con cualquier operando (2026-10-11)

Seguimiento de B-1227. El candado de B-1225 solo marcaba `x in ys` si `x` se llamaba `line`/`line_info`; un
`info in lines_info` (o `item`, `candidate`...) pasaba, y `LineInfo`/`CheckoutLineInfo` (`@dataclass` eq=True) delegan en
`CheckoutLine.__eq__`. Se anade el patron P3 en `saleor/tests/test_fork_checkout_line_membership_drift.py`: `in`/`not in`
con CUALQUIER operando izquierdo cuando la coleccion es `lines_info`/`*_line_info(s)`. `.remove/.index/.count` ya estaban
cubiertos por P2. Produccion actual: 0 aciertos nuevos, lista blanca sin cambios. Mutacion verificada (un `info in
lines_info` en `saleor/core/` pone el candado en rojo; al retirarlo vuelve a verde). Sigue siendo heuristica por nombre.

**Al hacer merge de upstream:** igual que B-1225: si el candado marca un sitio, comparar por pk / `id()`, no a la lista blanca.

---

## B-1227 — inventario de __eq__ por contenido y dataclasses comparables (2026-10-11)

Seguimiento de B-1223/B-1225: ¿hay otra clase con igualdad por contenido que cause el mismo bug? Inventario AST de
`saleor/` (sin tests/migraciones): 5 `__eq__`/`__ne__` propios y 120 `@dataclass` (ninguno con `eq=False`; 17 `NamedTuple`,
que comparan por tupla) y busqueda de `in` / `not in` / `.remove` / `.index` / `.count` / `==` / claves de set o dict
sobre sus instancias. **Resultado: 0 riesgos nuevos; no hay cambio de comportamiento.**

| Clase (archivo:linea) | Igualdad | Usos de pertenencia | Clasificacion |
|---|---|---|---|
| `CheckoutLine.__eq__` (`checkout/models.py:511`) | variante + cantidad; `__hash__` por pk | los 7 sitios de B-1223/B-1225 | ya arreglado / vigilado |
| `LineInfo`, `CheckoutLineInfo` (`core/pricing/interface.py:21`, `checkout/fetch.py:54`) | `@dataclass` eq: campo a campo (delega en `CheckoutLine.__eq__`) | `voucher.py:219` (`id()`), `promotion.py:442` (`id()`) | ya arreglado (B-1223); sin `==` entre infos ni claves de set/dict (no son hashables) |
| `Address.__eq__` (`account/models.py:108`) | `as_data()` sin pk; `__hash__` por pk | `checkout/utils.py:378,385` (`!=` y `old_address not in user.addresses.all()`), `delivery_context.py:158,321` | BENIGNO: preguntan «misma direccion» por contenido, es la intencion (no borrar la direccion vieja si el usuario ya tiene una igual) |
| `OrderLineInfo`, `EditableOrderLineInfo`, `FulfillmentLineData`, `OrderBulk*Line`, `GiftCardLineData` (dataclass eq por contenido, campo `line` = `OrderLine`) | `OrderLine` no define `__eq__` (pk) | solo `line_data.line.id in ...` / `line_info.line.pk in ...` (`order/actions.py:1411,1732`, `order/calculations.py:717`, `order/fetch.py:271`) | BENIGNO: pertenencia por pk/id, no por instancia |
| `CheckoutLineProblem*` (`checkout/problems.py:14,21`) | dataclass eq | `problems.py:175` `line not in not_available_lines` (lista blanca del candado) | BENIGNO: la disponibilidad depende solo del listing, dos lineas iguales son ambas (no) disponibles |
| `DeliveryMethodBase`, `ShippingMethodInfo`, `CollectionPointInfo`, `CheckoutInfo` | dataclass eq | ninguno (`delivery_context.py:164` y `checkout_delivery_method_update.py:106` comparan `Warehouse`, modelo por pk) | BENIGNO |
| `NonDatabaseFieldBase.__eq__` (`core/db/fields.py:63`), `JsonTruncText.__eq__` (`webhook/observability/payload_schema.py:13`) | `creation_counter` / valor | no son entidades de negocio | BENIGNO |
| resto de dataclasses (payment, taxes, attribute, webhook, ...) | por valor | sin pertenencia sobre instancias con modelos sin guardar | BENIGNO (datos de valor) |

Candado ampliado (`saleor/tests/test_fork_checkout_line_membership_drift.py`): ademas de los `in/remove` sobre lineas,
falla si aparece un `__eq__`/`__ne__` NUEVO en produccion que no este en `EQ_POR_CONTENIDO_REVISADOS` (con su porque), y
si una entrada queda obsoleta. No intenta marcar dataclasses: son 120 y casi todas de valor puro (falsos positivos).

**Al hacer merge de upstream:** un `__eq__` nuevo hace fallar el candado; revisar sus usos de pertenencia antes de listarlo.

---

## B-1223 — pertenencia de lineas por pk, no por `CheckoutLine.__eq__` (2026-10-11)

Auditoria de todo `saleor/`: `CheckoutLine.__eq__` (`saleor/checkout/models.py`) compara `variant` y `quantity`, y
`LineInfo` es un `@dataclass`, asi que su `==` delega en ese `__eq__`. `OrderLine` no define `__eq__` (igualdad de Django
por pk) y no se toca. Cuatro sitios hacian `in` / `list.remove` sobre lineas del MISMO checkout (no cruzan checkouts:
las lineas se cargan filtradas por `checkout_id`), y dos lineas del mismo checkout con igual variante y cantidad
(`forceNewLine`) se confundian:

- `saleor/checkout/utils.py` (`_append_line_to_update`): `line not in to_delete` / `line not in to_update` -> helper
  `_is_same_line_in` (compara pk). Antes, `checkoutLinesUpdate` que borraba la linea A y fijaba precio/motivo en la
  linea B (igual a A) descartaba en silencio el cambio de B.
- `saleor/discount/utils/voucher.py` (`attach_voucher_to_line_info`): `line_info in discounted_lines_by_voucher` ->
  comparacion por `id()` del objeto. Antes, con un voucher `apply_once_per_order` y dos lineas iguales de distinto precio
  (`price_override`, solo staff), el voucher se adjuntaba a las dos (doble descuento).
- `saleor/discount/utils/promotion.py` (`delete_gift_line` y el reemplazo de la linea regalo): `lines_info.remove(x)` ->
  `_remove_line_infos_by_identity` (por `id()`); `remove` quitaba la primera linea "igual", no necesariamente la pedida.

Tests: `saleor/checkout/tests/test_line_identity.py` (4); con el codigo viejo los 4 fallan.

**Al hacer merge de upstream:** upstream/main (782a751f62) mantiene el `__eq__` y los mismos `not in to_delete` /
`in discounted_lines_by_voucher` / `lines_info.remove`; si el conflicto cae en esas lineas, conservar la comparacion por
identidad. Upstream ya no tiene `checkout_line_delete.py` (B-1217 queda sin efecto alli).

---

## B-1225 — candado contra pertenencia por contenido sobre lineas de checkout (2026-10-11)

Seguimiento de B-1223. Inventario de `saleor/` (sin tests): 0 consumidores de la igualdad por contenido de
`CheckoutLine.__eq__` / `LineInfo.__eq__` en produccion (nada depende de que dos lineas "iguales" se confundan). Antes
de B-1223 habia 7 sitios de pertenencia sobre lineas: 6 arreglados (3 en `checkout/utils.py`, 2 en
`discount/utils/promotion.py`, 1 en `discount/utils/voucher.py`) y 1 benigno (`checkout/problems.py`: la disponibilidad
depende solo del listing del producto, asi que dos lineas de la misma variante son ambas disponibles o ambas no). El
escaner marca ademas dos falsos positivos (`order_lines_create.py`: lista de pks; `order/utils.py`: `OrderLineDiscount`,
igualdad de Django por pk), por lo que da 9 aciertos sobre `c334d80900^` y 3 sobre HEAD (los de la lista blanca).

- Candado: `saleor/tests/test_fork_checkout_line_membership_drift.py` (AST, sin BD propia). Marca `x in ys` /
  `x not in ys` y `ys.remove/index/count(x)` cuando `x` se llama `line`/`line_info` e `ys` parece coleccion de lineas.
  Heuristica por nombre: se elude renombrando la variable. Tiene lista blanca por (ruta, linea fuente) con justificacion
  y falla tambien si una entrada queda obsoleta.
- Tests de punta a punta de B-1223 (commit 14e80cce71): `test_checkout_add_voucher_code_apply_once_per_order_with_equal_lines`
  (`saleor/graphql/checkout/tests/mutations/test_checkout_add_promo_code.py`) y
  `test_delete_gift_line_keeps_regular_line_equal_to_the_gift_line` (`saleor/checkout/tests/test_line_identity.py`).

**Al hacer merge de upstream:** si upstream anade un `in` / `remove` sobre lineas, el candado lo marca: arreglarlo
comparando por pk / `id()` (`_is_same_line_in`, `_remove_line_infos_by_identity`), NO silenciarlo en la lista blanca.
Se recomienda abrir un issue upstream: eliminar los `__eq__/__ne__/__hash__` legados de `CheckoutLine` o declarar
`@dataclass(eq=False)` en `LineInfo`; si lo aceptan, el candado puede retirarse.

---

## B-1236 — `allocate_stocks`: el aviso de agotado usaba siempre el ultimo stock (late-binding) (2026-10-12)

`saleor/warehouse/management.py` (`allocate_stocks`, bucle `for allocation in allocations`): el callback de
`transaction.on_commit` era `lambda: trigger_product_variant_out_of_stock(allocation.stock, ...)`. El lambda lee
`allocation` al ejecutarse (tras el commit), cuando el bucle ya termino, asi que si dos stocks distintos se agotaban en la
misma llamada, el evento `PRODUCT_VARIANT_OUT_OF_STOCK` se emitia dos veces con el stock de la ULTIMA asignacion y el
otro stock nunca recibia el aviso. Es un bug preexistente de upstream (no lo introdujo B-1218). Fix minimo: `partial(
trigger_product_variant_out_of_stock, allocation.stock, requestor=requestor)`, que fija el stock al registrar el callback.

Test: `test_allocate_stocks_out_of_stock_event_fires_with_each_exhausted_stock`
(`saleor/warehouse/tests/test_stock_management.py`): dos variantes con un stock cada una, ambos agotados en la misma
llamada; con el codigo viejo falla (`[1, 1] != [1, 2]`: el mismo stock dos veces). Los tests vecinos
`..._two_new_allocations_exhaust_stock_with_previous_allocation` y `..._leave_stock_does_not_trigger_out_of_stock`
fijan el comportamiento de B-1218 (suma agrupada de asignaciones).

Pendiente: conviene reportarlo upstream (saleor/saleor). El mismo patron (`lambda` sobre la variable del bucle) existia en
`decrease_stock`; se arreglo despues en B-1238 (ver abajo).

**Al hacer merge de upstream:** si upstream ya lo arreglo, retirar el parche y dejar el test.

---

## B-1238 — `decrease_stock`: el aviso de agotado usaba siempre el ultimo stock (late-binding) (2026-10-12)

`saleor/warehouse/management.py` (`decrease_stock`, bucle final `for stock in Stock.objects.filter(id__in=...)`): mismo
bug que B-1236. El callback de `transaction.on_commit` era `lambda: trigger_product_variant_out_of_stock(stock, ...)`; se
evalua tras el commit y lee la ULTIMA `stock` del bucle, asi que si dos stocks quedaban agotados en la misma llamada el
evento `PRODUCT_VARIANT_OUT_OF_STOCK` salia dos veces con el ultimo y el otro nunca se avisaba. Fix minimo:
`partial(trigger_product_variant_out_of_stock, stock, requestor=requestor)`.

Test: `test_decrease_stock_out_of_stock_event_fires_with_each_exhausted_stock`
(`saleor/warehouse/tests/test_stock_management.py`): dos lineas de variantes distintas, ambos stocks agotados en una llamada;
con el codigo viejo falla (`[2, 2] != [1, 2]`).

Pendiente: reportar ambos sitios (`allocate_stocks` y `decrease_stock`) upstream en un solo issue (saleor/saleor).

**Al hacer merge de upstream:** si upstream ya lo arreglo, retirar el parche y dejar el test.

---

## B-1243 — `deallocate_stock` y `deallocate_stock_for_orders`: el aviso de "vuelve a haber stock" usaba siempre el ultimo stock (late-binding) (2026-10-12)

`saleor/warehouse/management.py`: mismo bug que B-1236 y B-1238. En `deallocate_stock`
(`for allocation_before_update in allocations_before_update`) y en `deallocate_stock_for_orders`
(`for allocation in allocations_for_back_in_stock...`) el callback de `transaction.on_commit` era
`lambda: trigger_product_variant_back_in_stock(<stock del bucle>, ...)`; se evalua tras el commit y lee el ULTIMO stock
del bucle, asi que si dos stocks volvian a tener disponibilidad en la misma llamada el evento
`PRODUCT_VARIANT_BACK_IN_STOCK` salia dos veces con el ultimo y el otro nunca se avisaba. Fix minimo:
`partial(trigger_product_variant_back_in_stock, <stock>, requestor=requestor)` en ambos sitios.

Tests (`saleor/warehouse/tests/test_stock_management.py`):
`test_deallocate_stock_back_in_stock_event_fires_with_each_restored_stock` y
`test_deallocate_stock_for_orders_back_in_stock_event_fires_with_each_restored_stock`: dos lineas de variantes distintas con
ambos stocks agotados, liberados en una llamada; con el codigo viejo fallan (`[2, 2] != [1, 2]`).

Pendiente: incluir estos dos sitios en el issue upstream (saleor/saleor) de B-1244.

**Al hacer merge de upstream:** si upstream ya lo arreglo, retirar el parche y dejar los tests.

---

## B-1218 — `allocate_stocks` sin N+1 al crear el pedido en `checkoutComplete` (2026-10-12)

`saleor/warehouse/management.py` (`allocate_stocks`, bloque posterior a `Allocation.objects.bulk_create`): dos bucles
por asignacion pasan a consultas unicas. (1) `alloc.stock` (FK lazy, 1 SELECT de `warehouse_stock` por asignacion) se
sustituye por `Stock.objects.in_bulk(...)`; cada asignacion recibe una copia (`copy.copy`) del stock y el mapa de
`bulk_update` usa las instancias originales, de modo que la `F("quantity_allocated") + n` sigue aplicandose solo a la
instancia que se persiste. (2) `Allocation.objects.filter(stock_id=...).aggregate(Sum(...))` por asignacion pasa a un
`values("stock_id").annotate(Sum(...))` para todos los stocks (1 consulta, mismo punto de la transaccion: despues del
`bulk_create`). El `select_for_update` de stocks/asignaciones, su orden, `InsufficientStock` y el orden de asignacion
entre almacenes no se tocan. Medido por el candado `n1-catalogo` de `avisos_ecommerce.sh`: `CheckoutComplete`
151 SQL con 2 lineas y 167 con 10 (+2 por linea) -> conteo independiente del numero de lineas.

Test: `test_allocate_stocks_selects_count_does_not_depend_on_lines_number`
(`saleor/warehouse/tests/test_stock_management.py`): cuenta los SELECT de `allocate_stocks` con 2 y con 10 lineas; con el
codigo viejo falla (6 != 22).

**Al hacer merge de upstream:** si el conflicto aparece en ese bloque de `allocate_stocks`, conservar la carga de los
stocks y la suma de asignaciones en una sola consulta por bloque. Si upstream ya lo arreglo, retirar el parche y dejar el
test. Verificar con el candado `[n1-catalogo]` (`CheckoutComplete sql_N2 == sql_N10`).

---

## B-1217 — `checkoutLineDelete` sin N+1 al comprobar que la linea pertenece al checkout (2026-10-11)

`saleor/graphql/checkout/mutations/checkout_line_delete.py`: `if line and line in checkout.lines.all():` pasa a
`if line and checkout.lines.filter(pk=line.pk).exists():`. El `in` invoca `CheckoutLine.__eq__`
(`saleor/checkout/models.py`), que compara `variant` y `quantity` y carga el FK `variant` de cada linea recorrida:
+1 SELECT por linea (80 SQL con 2 lineas, 88 con 10, medido por el candado `n1-catalogo` de `avisos_ecommerce.sh`).
Con el parche el conteo no depende del numero de lineas (77 = 77 con N=2 y N=10). No se toca `CheckoutLine.__eq__`
(tiene mas usuarios). Efecto lateral deseado: la comprobacion es por pk, asi que una linea de OTRO checkout con la
misma variante y cantidad ya no pasa por "perteneciente" (con `__eq__` si pasaba y se borraba).

Test: `test_checkout_line_delete_selects_count_does_not_depend_on_lines_number`
(`saleor/graphql/checkout/tests/mutations/test_checkout_line_delete.py`): cuenta los SELECT de borrar la ultima linea
con 2 y con 10 lineas (cantidades distintas, para que el `in` viejo no corte en la primera); con el codigo viejo falla
(40 != 48).

**Al hacer merge de upstream:** si el conflicto aparece en esa linea, conservar la comparacion por pk (o cualquier
variante que no pase por `CheckoutLine.__eq__`). Si upstream ya la arreglo, retirar el parche y dejar el test, que
sigue siendo valido. Verificar con el candado `[n1-catalogo]` (`CheckoutLineDelete sql_N2 == sql_N10`).

---

## B-1019 — timeout global por test con `pytest-timeout` (2026-10-07)

`pyproject.toml`: `pytest-timeout>=2.3.1,<3` en el grupo `dev` (solo test; el runtime no cambia) y `uv.lock` con la entrada
`pytest-timeout 2.4.0` (diff acotado a ese paquete). `setup.cfg [tool:pytest]`: `timeout = 600` y `timeout_method = signal`.
Un test (incluidos sus fixtures) que pase de 600 s falla con `Failed: Timeout (>600.0s)` y la linea exacta donde estaba parado,
en vez de dejar la suite de 17k colgada hasta el `timeout-minutes` del job.

**Por que 600 s:** el test mas lento medido en los JUnit de CI (`resultados-pytest`) es de ~140 s (run 37684326393) y ~207 s
(run 37671233116): siempre el primer test de un worker de xdist (arranque en frio), p. ej. `test_address_form_for_country[*]`
y `test_asgiref`. 300 s dejaba solo ~1,4x de margen sobre 207 s; 600 s da ~3x. Un test de verdad colgado cuesta 10 min, muy por
debajo del limite del job (30 min).

**Por que `signal` y no `thread`:** medido con xdist (`-n2`, timeout bajo forzado): `thread` hace `os._exit` del worker;
xdist lo reporta como `worker crashed` y lo reemplaza, repitiendo el test hasta `maximum crashed workers` (9 fallos por un solo
test) y la traza de hilos se pierde (el stderr del worker no llega). `signal` falla solo ese test, con traceback, y el worker
sigue vivo. Limite conocido: `signal` no interrumpe una llamada C que ignore senales; para eso el CI ya pasa
`-o faulthandler_timeout=300` (vuelca los hilos a los 300 s). Un test que necesite mas:
`@pytest.mark.timeout(1200)`.

**Verificacion:** test temporal con `time.sleep(6)` y `-o timeout=3`: falla en ~3 s con traza, con `-n0` y `-n2`; retirado,
no se commitea.

---

## B-1015 — un test que llega al broker real falla en segundos, no se cuelga (2026-10-07)

`saleor/tests/settings.py`: `CELERY_BROKER_URL = "redis://127.0.0.1:1/1"` (puerto cerrado, rechazo inmediato; tambien se
fija en `os.environ`, porque Celery da precedencia a la variable de entorno y `pytest-celery` exporta
`redis://localhost:6379/1`), `CELERY_BROKER_CONNECTION_MAX_RETRIES = 0`, `CELERY_BROKER_CONNECTION_RETRY(_ON_STARTUP) = False`,
`CELERY_BROKER_CONNECTION_TIMEOUT = 2` y `CELERY_TASK_PUBLISH_RETRY = False`. Solo configuracion de test; `saleor/settings.py`
no cambia. Test de regresion: `saleor/core/tests/test_celery_broker_unreachable.py` (producer de beat, producer real y `.delay()` sin
eager deben lanzar `OperationalError` en < 10 s).

**Por que:** B-1008 (suite colgada 60 min al 99 %) se debio a que `celery.beat.Scheduler.producer` llama a
`ensure_connection(max_retries=broker_connection_max_retries)`; el valor por defecto (100 reintentos con backoff) son ~45 min de
espera contra un broker inexistente en CI. B-1008 lo arreglo en un test; esto lo cierra para cualquiera futuro. Medido:
`max_retries=0` en kombu 5.5.4 falla al instante (no significa «infinito»).

**Verificacion:** sin el cambio (broker inalcanzable) el test se corta por `timeout 150` sin terminar; con el cambio pasa en ~2 s
por test. El canario `test_beat_dispatch_in_memory.py` usa `memory://` propio y no se ve afectado. Si un test legitimo necesita un
broker, que construya su propia app/conexion (como el canario), no que reutilice `saleor.celeryconf.app`.

---

## B-1270 — los linters corren en cada push a `stable/*` (2026-10-12)

`.github/workflows/ci-fork.yml`: el job `linters` («Linters (pre-commit)», nombre sin cambios) pasa de
`(push solo si created) && (dispatch solo si alcance != rapido)` a solo `dispatch con alcance != rapido`, la misma condicion
que `suite`: corre en PR, dispatch `completo` y **todo push a `stable/*`**. Solo `imagen` conserva el corte (push que crea la
rama). Se corrigieron los comentarios de `puerta`, `concurrency`, `linters` y `suite` que describian el corte anterior.

**Por qué:** con el corte, el aviso `[linters-fork]` del worker no podía medir el HEAD y 6 pushes quedaron sin linters.
B-666 (ahorro de minutos) queda superada, como ya se declaró para la suite en B-1005: repo público, pre-commit ~5-6 min.

**Primer run con linters en push (run 38335120637, `cdeeb2a96d`): rojo en mypy.** El fix de B-1249 (`6500a992d2`) dejó
`lambda user=user: user` en `saleor/graphql/plugins/dataloaders.py`, y mypy no infiere el tipo de ese lambda («Cannot infer
type of lambda»). Entró sin que nadie lo viera justo por el corte que este cambio quita. Arreglo: una función tipada
`_requestor_getter(requestor) -> Callable[[], Requestor]` crea un getter por requestor. Sigue sin late binding y el test de
B-1249 sigue en verde. Es un parche local más sobre un archivo de upstream (el mismo que tocó B-1249).

**Conflicto potencial al actualizar upstream:** **ninguno** en `ci-fork.yml` (archivo propio). `dataloaders.py` sí es de
upstream: si upstream arregla el late binding por su cuenta, quedarse con su versión y comprobar mypy.

---

## B-1005 — la suite completa corre en cada push a `stable/*` (2026-10-07)

`.github/workflows/ci-fork.yml`: el job `suite` («Suite completa (17k tests)», nombre sin cambios) pasa de
`(push solo si created) && (dispatch solo si alcance != rapido)` a solo `dispatch con alcance != rapido`, es
decir corre en PR, dispatch `completo` y **todo push a `stable/*`**. `linters` e `imagen` conservan su corte
(solo push que crea la rama). El bloque `concurrency` ya existía y no se tocó.

**Por qué:** el guard `scripts/railway-seguro/ci_desplegable.py` (repo raíz) exige ese job en success sobre el SHA
exacto del HEAD de `stable/3.23`; con el corte de B-666 cualquier push normal dejaba el HEAD sin run y obligaba
a lanzar un dispatch a mano. B-666 (ahorro de minutos con repo privado) queda superada: el repo es público
(runners estándar gratis). Un commit `[skip ci]` en `stable/*` sigue sin run y el guard lo rechaza (correcto).

---

## Deriva JSON vs panel de Railway: builder de beat (2026-10-06, reporte B-978)

**Qué divergía:** `railway.saleor-beat.json` decía `builder: DOCKERFILE` (+ `dockerfilePath`), pero el
panel de `saleor-beat` usa **RAILPACK**. `test_railway_config.sh` afirmaba DOCKERFILE para los tres:
se comparaba consigo mismo y nunca vio la diferencia. **Los `railway.saleor-*.json` no están enlazados
en el panel** (ningún servicio tiene config file), así que son espejos inertes: **manda el panel**.
Corregido: el JSON de beat dice RAILPACK; el test espera DOCKERFILE en api/worker y RAILPACK en beat.
Cambiar el builder del panel es otra decisión (Andrés), no parte de este arreglo.
**Cómo comprobar deriva:** `scripts/railway-seguro/drift_config.py` del root de ecommerce compara la
salida de `get-service-config` con estos JSON (builder, dockerfilePath, startCommand, preDeploy,
healthcheck).

---

## Config-as-code por servicio de Railway (2026-10-06, reporte B-876)

**Qué hay:** `railway.saleor-api.json`, `railway.saleor-worker.json` y `railway.saleor-beat.json`
reproducen **exactamente** el preDeployCommand, startCommand y healthcheck que hoy viven en el panel
de Railway (leídos el 2026-10-06), más lo que ya aporta `railway.json` (builder DOCKERFILE,
restart ON_FAILURE x3). `scripts/tests/test_railway_config.sh` (lo corre `ci-fork.yml`) verifica:
api migra en su preDeploy; worker/beat solo esperan (`sh scripts/wait-for-migrations.sh`); los
startCommand coinciden con el panel.

**Estado: documentación verificada, NO fuente activa.** Ningún servicio apunta aún a estos archivos
(todos leen `railway.json` por defecto). Para activarlos, Andrés debe, en el panel de Railway
(proyecto licona-store, entorno production), por servicio: *Settings -> Config-as-code -> ruta del
archivo* = `/railway.saleor-api.json` (api), `/railway.saleor-worker.json` (worker),
`/railway.saleor-beat.json` (beat) y verificar en el siguiente deploy (icono de archivo en el detalle
del deployment) que los valores vienen del archivo. Ojo: con ruta personalizada el servicio **deja de
leer `railway.json`**; por eso cada archivo es autosuficiente. `preDeployTimeoutSeconds` (900) no
está en el esquema de config-as-code y sigue solo en el panel. Cualquier cambio en el panel o en el
archivo debe replicarse en el otro (el test solo ve el archivo).

**Gotcha — startCommand vs ENTRYPOINT:** con Dockerfile, un start command configurado **sustituye
al ENTRYPOINT** de la imagen en forma exec (https://docs.railway.com/deployments/start-command).
Consecuencia hoy: `saleor-beat` invoca `railway-entrypoint.sh` a mano (wait-for-db + CREATE_SUPERUSER
+ exec) pero `saleor-worker` **no lo corre** (su startCommand es `sh -c 'celery ...'`); worker se
apoya en su preDeploy `wait-for-migrations.sh` (que ya exige DB accesible). `saleor-api` no tiene
startCommand: usa ENTRYPOINT+CMD del Dockerfile. Nota: config-as-code está **deprecado** en Railway
(archivos existentes funcionan hasta 2026-12-01; sucesor: Infrastructure as Code,
`.railway/railway.ts`), así que esto es un puente.

---

## Migraciones al preDeployCommand de saleor-api (2026-10-05, reporte B-386, parte 1/2)

**Problema (B-386/B-387):** el `railway-entrypoint.sh` migraba al arrancar la api, pero worker y beat
arrancaban a la vez con código nuevo sobre un esquema todavía viejo (carrera "código nuevo sobre
esquema viejo"). Además `SKIP_MIGRATIONS` era una convención por variable, fácil de olvidar.

**Cambio (parte 1, en el repo):**

- `scripts/railway-entrypoint.sh` ya **no migra**: se quitó el bloque `migrate` y la rama
  `SKIP_MIGRATIONS`. Conserva `wait-for-db.sh`, `CREATE_SUPERUSER` y `exec "$@"`. Se añadió el override
  `WAIT_FOR_DB` (por defecto `/app/scripts/wait-for-db.sh`) solo para poder testearlo.
- `scripts/wait-for-migrations.sh` — **nuevo, sin equivalente en upstream.** Envuelve
  `check-migrations.sh` en un bucle (`MIGRATIONS_POLL_SECONDS`=10, `MIGRATIONS_WAIT_SECONDS`=600) y
  falla (exit 1) al vencer. Nunca corre `migrate`.
- Tests: `scripts/tests/test_wait_for_migrations.sh` y `scripts/tests/test_railway_entrypoint.sh`.
- `Dockerfile`: solo el comentario del `ENTRYPOINT`.

**Modelo resultante (se aplica en Railway en la parte 2, ventana de despliegue):**

- **saleor-api** es el único migrador: `preDeployCommand` = `python manage.py migrate --noinput`.
- **saleor-worker y saleor-beat**: `preDeployCommand` = `sh scripts/wait-for-migrations.sh`; esperan a que
  la api deje la base a la altura del código.

**Orden de despliegue obligatorio:** configurar el `preDeployCommand` de saleor-api **ANTES** de mergear
este cambio. Con el entrypoint nuevo y sin preDeploy, un deploy no migra nada. El estado inverso
(preDeploy configurado y entrypoint viejo) es inocuo: el `migrate` queda idempotente.

**Gotchas:**

- En un servicio con builder Dockerfile, `startCommand` **reemplaza el ENTRYPOINT** de la imagen:
  saleor-worker nunca pasó por `railway-entrypoint.sh`, así que nunca migró por esa vía.
- `SKIP_MIGRATIONS` queda **muerta** (nada la lee). Retirarla de las variables de Railway es decisión de
  Andrés.
- **Config as Code (`railway.json`) está deprecado, con corte el 2026-12-01.** Por eso el preDeployCommand
  se configura como ajuste de servicio en Railway y no en `railway.json`.

---

## Re-fork sobre 3.23.36 (2026-09-29, reporte B-588)

Parte 2/4 del salto autorizado en B-584. La rama `stable/3.23` nace **del tag `3.23.36`** (estrategia A,
re-fork limpio), no de `stable/3.22`; el payload del fork se reaplicó encima. Verificado solo en local:
**no se ha desplegado nada** (eso es B-523, parte 4/4).

**Base:** tag `3.23.36` (`44dd076f00`). El tip de `upstream/3.23` va un commit por delante
(`e77fd1f2f2`, `ci: replace path filters in tests and e2e...`, solo workflows de CI de upstream): no se
incorporó porque la regla es partir del tag estable.

**Delta del fork medido** (`git diff 3.22.71 origin/stable/3.22`; `3.22.71` es el merge-base con
upstream) y qué se hizo con cada pieza:

| Pieza | Clase | Tratamiento |
|---|---|---|
| `Dockerfile`, `manage.py`, `pyproject.toml`, `.env.example`, `.gitattributes`, `.gitignore`, `saleor/asgi/__init__.py`, `saleor/celeryconf.py`, `uv.lock` | payload | reaplicado con `git apply -3` sobre 3.23.36 (+85/−13 líneas de código y config, tras el `uv.lock`) |
| `railway.json`, `scripts/{check-branch-protection,check-github-settings,check-migrations,check-schema-fidelity,railway-entrypoint,wait-for-db}.sh`, `.github/workflows/{ci-fork,security-scan,sync-upstream}.yml`, `UPGRADE_NOTES.md`, `docs/superpowers/plans/*`, `saleor/tests/test_fork_*_drift.py` | propio | copiado de `origin/stable/3.22` |
| `AGENTS.md` | propio (reemplaza el de upstream) | se conserva el del fork, como con el `merge=ours` de siempre; upstream 3.23 trae su propio `AGENTS.md` (+122 líneas) que se descarta |
| `saleor/discount/migrations/0052_drop_sales_constraints.py` | parche descartado | se queda la versión de upstream 3.23.36 (ver abajo) |
| `.github/workflows/test-env-cleanup-cron.yml` | borrado deliberado del fork (2026-09-03) | borrado de nuevo en el árbol |
| `.github/workflows/changelog-check.yml`, `.../graphql-inspector.yml` | no eran cambios nuestros: copias rancias de upstream que el sync no actualizaba (`.github/workflows/` del fork no sigue a upstream) | se toma la versión de upstream 3.23.36 (el pin `3.22:` del inspector desaparece: 3.23 usa `base.sha`) |

No apareció lógica de negocio fuera de lo descrito.

**Los tres conflictos previstos (B-578) y su resolución real:**

1. `.env.example`: al partir de 3.23.36 no chocó (upstream no lo tocó entre 3.22.71 y 3.23.36); el
   payload se aplicó limpio. El conflicto medido venía del merge, no del re-fork.
2. `Dockerfile`: upstream 3.23 cambió el `CMD` (`--lifespan=off` → `--lifespan=auto`). Se conserva
   **`--lifespan=auto` de upstream** sobre nuestro `ENTRYPOINT` de Railway y el `CMD` con `--host=::`
   y `--port=${PORT:-8000}`. Ojo: es un cambio de comportamiento heredado respecto a 3.22.
3. `.github/workflows/test-env-cleanup-cron.yml`: upstream lo conserva; nosotros lo retiramos el
   2026-09-03. Se borra del árbol (no se deshabilita por UI).

Conflictos adicionales no previstos, ambos triviales: `.gitignore` (upstream tocó `.claude` y añadió
`!.semgrep/`: se conserva lo de upstream y se añaden nuestras 2 entradas) y `saleor/asgi/__init__.py`
(upstream importa ahora `settings` para `usage_telemetry_middleware`: conviven ambos imports;
`load_dotenv()` sigue antes de leer `settings.SEND_USAGE_TELEMETRY`, así que un `.env` con esa variable se respeta).

**`discount/0052`:** el parche del fork (tragarse cualquier excepción) se **descarta** y queda el de
upstream (commit `f47392d874`, fix in-place, solo FK/UNIQUE). **Precondición abierta, que no cubre este
reporte y sigue en B-633:** Django no reejecuta una migración ya aplicada, así que hay que comprobar en
la **BD real** (no en el archivo) que los constraints objetivo ya se soltaron antes de desplegar.

**`uv.lock`:** se parte del lock de upstream 3.23.36 y solo cambia por nuestra dependencia directa
`python-dotenv`: **+2 líneas** (`uv tool run uv@0.12.1 lock`, la versión que pinea el `Dockerfile`).
`uv lock --check` con esa versión: verde.

**Tag de archivo:** `archive/stable-3.22-fork` (anotado, publicado en `origin` el 2026-09-29) apunta a
`origin/stable/3.22` (`21ee0a61c4`), el último estado del fork en 3.22.

**Publicación (2026-09-30, turno `20260930-031348`):** `stable/3.23` se empujó a `origin` en
`bcabfad312`. Crear la rama **no despliega**: Railway sigue apuntando a `stable/3.22`. El push exige
que el token de `gh` tenga el scope `workflow` (todo re-fork toca `.github/workflows/`) y que git use
ese token (`gh auth setup-git`), no uno viejo del llavero.

**Cambio nuevo del fork, nacido del primer CI sobre la rama — `pyproject.toml`, `[tool.ruff]`
`extend-exclude = [ ".semgrep" ]` (+4 líneas con su comentario).** El primer run de `ci-fork.yml`
sobre `stable/3.23` (`36688509531`) salió rojo en `Puerta rapida` → `Ruff`: 76 errores, **todos** en
cuatro fixtures de `.semgrep/` que existen idénticos en 3.22. La causa no es el payload: upstream 3.23
añadió `!.semgrep/` a `.gitignore`, y ruff respeta `.gitignore`; en 3.22 la regla `.*` escondía el
directorio y en 3.23 deja de hacerlo. Se reproduce en `3.23.36` puro con `ruff check .`. Se excluye en
`pyproject.toml` y no con `--exclude` en el workflow porque el job `Linters (pre-commit)` pasa los
archivos por ruta y solo la config del proyecto (`--force-exclude`) los filtra ahí, y porque así el
`ruff check .` local y el del CI dicen lo mismo. **Conflicto potencial al actualizar upstream:** bajo
(upstream no tiene `extend-exclude` en `[tool.ruff]`); si algún día lo añade, fusionar las dos listas.

**Verificación local (2026-09-29, venv desechable con las deps de 3.23.36, Postgres 16 desechable):**

| Comprobación | Resultado |
|---|---|
| `manage.py check` | 0 issues |
| `makemigrations --check --dry-run` | `No changes detected` |
| `check-migrations.sh` sobre BD vacía → tras `migrate` | exit 1 (todas pendientes) → exit 0 (`migrate` completo en 36 s, incluida `discount.0052` sobre PG 16) |
| `check-migrations.sh` contra la BD local de Andrés (solo lectura) | exit 1: **65 pendientes**, las 65 medidas en B-578; no se migró |
| `check-schema-fidelity.sh` | exit 0, `schema.graphql` fiel byte a byte |
| `ruff check .` / `ruff format --check .` (excluye `.semgrep/`, como el pre-commit) | limpio |
| `pytest -m "not e2e" -n 12` | 17 859 passed, 1 skipped, **2 failed** en 167 s |

Los 2 fallos (`test_http_client.py::test_http_client_disallows_private_ip_ranges[http|https]`)
**se reproducen idénticos en 3.23.36 puro**: dependen de red saliente del entorno, no del payload.
El tag puro recoge 17 855 tests; los 7 restantes son los dos tests de deriva del fork (verdes).

**Pendiente del cierre del salto (B-523, no hecho aquí):** apuntar `sync-upstream.yml` a `stable/3.23`,
cambiar la rama por defecto del repo y cerrar el issue `upstream-minor`. Los textos de este archivo que
dicen `3.22` describen la línea anterior y se actualizan en B-523.

### Sincronización a 3.23.37 (2026-09-30, turno `20260930-060258`, B-665)

**Qué trajo upstream (`3.23.36..3.23.37`, 4 commits):** `setPassword` y `confirmAccount` emiten ahora
`ACCOUNT_CONFIRMED` + `CUSTOMER_UPDATED`/`STAFF_UPDATED` al confirmar una cuenta (#19834); la tarea de
backfill del `search_vector` de usuarios gana cursor (#19841); CI de upstream: filtros de ruta sustituidos
por un chequeo en el job (#19787, toca `tests-and-linters.yml`, `e2e.yml` y una action nueva
`detect-python-changes`); bump de versión. **Sin migraciones nuevas** (`git diff --stat 3.23.36 3.23.37 -- '*/migrations/*'` vacío).
`Dockerfile` sin cambios. **`schema.graphql` cambia** (+18/−4: solo docstrings y `@webhookEventsInfo` de
`confirmAccount`/`setPassword`; ningún tipo, campo ni argumento nuevo o retirado).

**Conflictos:** uno, `uv.lock` (upstream sube la versión del paquete `saleor` 3.23.36 → 3.23.37; el fork
lleva +2 líneas de `python-dotenv`). Resolución: se conserva el lock del fork con la versión subida a mano;
`git diff 3.23.37 -- uv.lock` queda en exactamente las 2 líneas del payload. Los workflows de upstream
(`tests-and-linters.yml`, `e2e.yml`) se fusionaron sin conflicto. Merge (no rebase), historia intacta.

**Referencias re-apuntadas a `stable/3.23`:** `sync-upstream.yml` (2 × `ref:` y `--base`, más un comentario),
`security-scan.yml` (`branches:`), `check-branch-protection.sh` y `check-github-settings.sh` (`RAMA` por
defecto y ejemplo del comentario), comentario de `ci-fork.yml` sobre la vía de despliegue y docstring de
`test_fork_branch_protection_drift.py`. Se dejan a propósito (históricos o ilustrativos): `ci-fork.yml:5`,
`sync-upstream.yml:4` (la rama por defecto de GitHub sigue siendo `stable/3.22` hasta el cierre del salto),
y los ejemplos de `check-*.sh` que citan `stable/3.22` como caso de rama con `/`.

**Verificación local (venv desechable con `uv sync --frozen`, Postgres 16 y Redis desechables):**
`manage.py check` 0 issues; `makemigrations --check --dry-run` sin cambios; `check-schema-fidelity.sh` exit 0;
`migrate` sobre BD vacía completo (~35 s), `check-migrations.sh` exit 0 después; `ruff check .` limpio y
`ruff format --check .` limpio; `saleor/tests/test_fork_*` 7 passed; `pytest -m "not e2e" -n 12`:
17 864 passed, 1 skipped, 3 failed: los 2 de `test_http_client_disallows_private_ip_ranges` (red saliente
del entorno, ya conocidos) y `order/tests/test_notifications.py::test_get_default_fulfillment_payload`,
que no toca nada del delta y pasa aislado y con su archivo completo (flake bajo xdist).

---

## Cambios aplicados

> Estado autoritativo en `stable/3.23`: las entradas de abajo son la historia de cada parche. Contra
> 3.23.36 siguen vigentes todas **excepto** el fix de `discount.0052` (2026-04-17), descartado a favor
> del de upstream, y el `build-image.yml` ya retirado.

### 2026-04-16 — Setup inicial Railway (base: 3.22.48)

**Archivos modificados:**

- `Dockerfile`
  - Agregado `netcat-openbsd` en apt-get para el script `wait-for-db.sh`.
  - Reemplazado `CMD` directo por `ENTRYPOINT ["scripts/railway-entrypoint.sh"]` + `CMD` original.
  - Motivo: Railway inyecta `$PORT` dinámicamente y necesita ejecutar migraciones en el arranque.

**Archivos creados:**

- `railway.json` — Configuración de build y deploy para Railway.
- `scripts/railway-entrypoint.sh` — Ejecuta `migrate` y opcionalmente crea superusuario antes de iniciar el proceso.
- `scripts/wait-for-db.sh` — Espera a que Postgres acepte conexiones (útil en Railway donde DB puede tardar en estar lista).
- `.env.railway.example` — Plantilla de variables de entorno para Railway (sin valores reales).
- `.github/workflows/sync-upstream.yml` — Sync semanal automático con upstream.
- `.github/workflows/build-image.yml` — Build y push de imagen Docker a GHCR en cada push a `stable/3.22`.
  ⚠️ **Retirado del árbol el 2026-09-03 sin haber tenido nunca un run verde** (0 éxitos en 36 runs,
  la imagen nunca llegó a existir en GHCR y nadie la consumía). Ver la entrada de esa fecha.
- `.github/workflows/security-scan.yml` — Escaneo Trivy semanal de vulnerabilidades en la imagen.

### 2026-04-17 — Fix migración discount.0052 para PostgreSQL 15+ (base: 3.22.48)

**Archivos modificados:**

- `saleor/discount/migrations/0052_drop_sales_constraints.py`
  - Envuelto cada `execute DROP CONSTRAINT` en `BEGIN/EXCEPTION WHEN others THEN null END`.
  - Motivo: PostgreSQL 15+ lanza `InvalidTableDefinition` al intentar dropear el constraint
    `*_id_not_null` en tablas donde `id` es parte de la PK (ej. `discount_sale_collections`).
    El `IF EXISTS` no es suficiente para este tipo de error; hay que capturar la excepción.
  - **Conflicto potencial al actualizar upstream:** Si Saleor corrige esta migración en el upstream,
    puede haber un conflicto en este archivo. Revisar y descartar el parche local si el fix upstream
    lo resuelve correctamente.

**Sin cambios en:**

- Lógica de negocio de Saleor
- Modelos ni settings de Django
- Código Python del core

### 2026-04-29 — Carga de `.env` para desarrollo local (base: 3.22.48)

**Archivos modificados:**

- `manage.py`
  - `from dotenv import load_dotenv` + `load_dotenv()` dentro de `if __name__ == "__main__":`,
    antes del `os.environ.setdefault("DJANGO_SETTINGS_MODULE", ...)`.
- `saleor/asgi/__init__.py`
  - `from dotenv import load_dotenv` en el bloque de imports de cabecera (como third-party, entre la
    stdlib y los imports relativos) + `load_dotenv()` a nivel de módulo antes del
    `os.environ.setdefault("DJANGO_SETTINGS_MODULE", ...)`.
  - **Corregido el 2026-08-22:** el import se había dejado suelto en la línea 34, después de las
    definiciones de función. `ruff check .` lo marcaba con `E402` (module level import not at top of
    file) e `I001` (import block un-sorted) — eran los **únicos 2 errores de lint del fork entero**.
    Mover el import a la cabecera deja `ruff check .` en `All checks passed!`. La posición de la
    **llamada** sí importa (tiene que preceder a la lectura de settings); la del import no.
- `saleor/celeryconf.py`
  - `from dotenv import load_dotenv` en los imports + `load_dotenv()` tras ellos.

**Motivo:** upstream espera las variables ya exportadas en el entorno (en Railway las inyecta la
plataforma). Para desarrollo local con `.env` hacía falta cargarlas explícitamente en los tres puntos
de entrada: comandos de gestión, ASGI y Celery (worker y beat).

**En producción es inocuo:** sin archivo `.env` presente, `load_dotenv()` es un no-op y las variables
siguen viniendo del entorno de Railway.

> ⚠️ **Riesgo conocido — `python-dotenv` no es dependencia directa.** Hoy llega de forma
> **transitiva**, como extra de `uvicorn[standard]` y con marker
> `platform_python_implementation != 'PyPy'` (ver `uv.lock`). Como el import es a nivel de módulo en
> `saleor/asgi/__init__.py` y `saleor/celeryconf.py`, si un cambio de resolución de dependencias
> dejara de traerlo, **los tres servicios (`saleor-api`, `saleor-worker`, `saleor-beat`) fallarían al
> arrancar** con `ModuleNotFoundError`. Hoy no ocurre porque los tres comparten la misma imagen, que
> sí instala `uvicorn[standard]`. Corrección pendiente: declarar `python-dotenv` como dependencia
> directa en `pyproject.toml`.
>
> ✅ **Resuelto el 2026-08-22** — ver la entrada de esa fecha más abajo.

**Conflicto potencial al actualizar upstream:** bajo. Son adiciones en zonas estables de los tres
archivos; un cambio de upstream en las mismas líneas es improbable pero revisable.

**Archivos modificados (higiene):**

- `.gitignore` — añadido `celerybeat-schedule*` (estado local de Celery beat, se regenera).

### 2026-08-22 — `python-dotenv` como dependencia directa (base: 3.22.48)

**Archivos modificados:**

- `pyproject.toml`
  - Añadida `"python-dotenv>=1.1.1,<2"` a `[project].dependencies`, en orden alfabético entre
    `python-dateutil` y `python-http-client`, con el estilo `>=mínimo,<major siguiente` que usa el
    resto del archivo. El mínimo es la versión que ya estaba resuelta en el lock, así que la
    restricción no fuerza ningún cambio de resolución.
- `uv.lock`
  - Regenerado con `uv lock` (uv 0.8.14, la misma versión que fija el hook `uv-lock` de
    `.pre-commit-config.yaml`; el `Dockerfile` usa la serie `0.8`). El diff son **exactamente dos
    líneas añadidas**: `python-dotenv` entra en `[[package]] name = "saleor"` → `dependencies` y en
    `metadata.requires-dist`. Ninguna versión de ningún paquete cambió; siguen siendo 239 paquetes
    resueltos y `python-dotenv` sigue clavada en 1.1.1.

**Motivo (por qué, no solo qué):** desde el 2026-04-29 hay `from dotenv import load_dotenv` **a nivel
de módulo** en `saleor/asgi/__init__.py` y `saleor/celeryconf.py` (y dentro de `__main__` en
`manage.py`), pero el paquete nunca se declaró. Llegaba de rebote como extra de `uvicorn[standard]`,
y encima condicionado al marker `platform_python_implementation != 'PyPy'`.

Que hoy funcione es una coincidencia de empaquetado, no un contrato: los tres servicios de producción
—`saleor-api`, `saleor-worker` y `saleor-beat`— comparten **la misma imagen Docker**, y esa imagen
instala `uvicorn[standard]` porque la API sirve con uvicorn. El worker y el beat **no necesitan
uvicorn para nada**; el día que se construya una imagen separada y más delgada para ellos —o que un
upgrade de `uvicorn` mueva `python-dotenv` fuera del extra `standard`—, los tres arrancarían con
`ModuleNotFoundError: No module named 'dotenv'` **antes de emitir un solo log útil**. Es un fallo de
arranque, silencioso en la revisión de código y ruidoso en producción.

Declararla directa convierte esa dependencia implícita en explícita: el resolvedor la garantiza
aunque `uvicorn` desaparezca del árbol.

**Verificación:** `uv tree --invert --package python-dotenv` pasa de listar un solo consumidor
(`uvicorn (extra: standard)`) a listar dos (`saleor` y `uvicorn`). Además `manage.py check` limpio y
`ruff check .` en `All checks passed!`.

**Conflicto potencial al actualizar upstream:** medio-bajo. `pyproject.toml` y `uv.lock` son
archivos que upstream toca a menudo (bumps de dependencias), así que el sync semanal puede marcar
conflicto ahí. La resolución es siempre la misma: conservar la línea de `python-dotenv` y regenerar
el lock. Upstream no usa `python-dotenv`, por lo que nunca va a añadir la línea por su cuenta.

---

### 2026-08-27 — CI propia del fork y verificación de los PR de sync (base: 3.22.67)

**Archivos añadidos:**

- `.github/workflows/ci-fork.yml` — **nuevo, sin equivalente en upstream.** Tres jobs: `puerta`
  (import + ruff + `manage.py check` + `makemigrations --check`, techo 15 min), `linters`
  (`pre-commit run --all`, techo 20 min) y `suite` (la suite completa sin e2e, techo 60 min).
  Dispara con `pull_request` sobre `stable/*` y con `workflow_dispatch` (input `alcance`:
  `completo` | `rapido`).

**Archivos modificados:**

- `.github/workflows/sync-upstream.yml` — el job `sync` pasa de un `run:` monolítico a cinco pasos
  con `id`. Añade una **puerta rápida en línea** (techo 10 min, sin tests) cuando el merge sale sin
  conflictos, dispara `ci-fork.yml` sobre la rama de sync, y **reescribe el cuerpo del PR** para que
  el estado de verificación sea lo primero que se lee. El job `check-new-minor` **no se tocó**
  (verificado por diff de bloque: 117 líneas idénticas antes y después).
- `manage.py` — **una línea en blanco** tras `from dotenv import load_dotenv`, que es lo que pide
  `ruff-format`. Ver el motivo abajo.

**Motivo — por qué existe un `ci-fork.yml` en vez de arreglar `tests-and-linters.yml`:**

Medido el 2026-08-27 contra la API de Actions de GitHub, no supuesto:

```
gh api repos/aclicona/licona-saleor/actions/workflows/tests-and-linters.yml -q .state
→ deleted
```

Lo mismo para `check-licenses.yaml` y `check-migration-tasks.yml`. Los tres archivos **existen** en
`stable/3.22`, que es la rama por defecto, y aun así GitHub los tiene por borrados. La explicación más
probable —**inferencia, no medición**— es que el registro de Actions del fork heredara el borrado que
upstream hizo en `ec664a1d32` (*fix(build): always run linters + add `sfw`*, #19573), un commit que
solo vive en ramas de upstream. Lo medido es el `state` y el historial vacío, no la causa; para el
arreglo la causa da igual. Consecuencia medida:
`gh run list --workflow tests-and-linters.yml` devuelve **vacío** — la suite de este fork **no ha
corrido ni una sola vez** desde que se creó en abril de 2026.

Aun sin ese problema, tocar `tests-and-linters.yml` sería un error: es un archivo de upstream, y
`sync-upstream.yml` descarta a propósito todo `.github/workflows/` que venga de upstream (porque el
`GITHUB_TOKEN` tiene prohibido empujar cambios ahí). Un archivo con nombre propio tiene **cero
conflictos de merge por definición**.

**Motivo — por qué el PR de sync necesita verificación dentro de su propio job:**

GitHub no dispara workflows con eventos originados por `secrets.GITHUB_TOKEN` (salvaguarda antibucle
documentada; las únicas excepciones son `workflow_dispatch` y `repository_dispatch`). El PR #3
(`sync/upstream-3.22.67`) llegó a revisión humana con **cero** checks: sus seis CheckRuns son todos
`SKIPPED` y con timestamp del evento `closed` al mergear, no de la apertura. Ese sync traía dos CVE.

Se descartó la alternativa del PAT: una credencial de larga vida que caduca en silencio reproduce
exactamente el fallo que se está arreglando —algo que deja de verificar sin avisar— y sería un punto
único de fallo en la cadena de suministro de **todas** las instancias de cliente a la vez.

**Motivo — la línea en blanco de `manage.py`:**

`pre-commit run --all` sobre `stable/3.22` limpio da **`ruff format` en Failed, 1 archivo
reformateado**: `manage.py`, que es un parche local del fork (el `load_dotenv` del 2026-04-29). El
resto está verde. El
parche entró sin pasar por el formateador del propio fork **porque ese formateador nunca ha corrido**,
que es justo lo que arregla este cambio. Tomar el reformateo es lo que evita que `ci-fork.yml` nazca
en rojo por una razón que no tiene nada que ver con lo que vigila.

**Verificación (2026-08-27, sobre `stable/3.22`):**

- `pre-commit run --all` tras el reformateo → **los diez hooks en verde, exit 0**:
  `trailing-whitespace`, `end-of-file-fixer`, `ruff`, `ruff-format`, `mypy`, `deptry`, `semgrep`,
  `uv-lock`, `Check for uncreated migrations` y `Check GraphQL schema is up to date`.
  ⚠️ En la corrida **anterior** al reformateo, `semgrep` salió `Failed — files were modified by this
  hook`. Es un **falso positivo por cascada**: pre-commit le atribuyó la modificación que había dejado
  `ruff-format`. Con el árbol formateado pasa. No perseguirlo.

- `.venv/bin/ruff check .` → `All checks passed!`
- `.venv/bin/python manage.py check` → `System check identified no issues (0 silenced).`
- `.venv/bin/python manage.py makemigrations --check --dry-run` → `No changes detected`, exit 0
- `python -c "import saleor"` → OK, `3.22.67`
- Los cuatro son exactamente los comandos de la puerta rápida, así que la línea base de la puerta
  está medida antes de existir.
- Se comprobó además, apuntando `CACHE_URL` a un puerto muerto, que **la puerta no necesita Redis**:
  `manage.py check` y `makemigrations --check` salen 0 igual. Por eso el job `sync` declara solo
  Postgres.

**Primer run real de `ci-fork.yml`** (`workflow_dispatch` sobre `stable/3.22`,
[run 33126906393](https://github.com/aclicona/licona-saleor/actions/runs/33126906393)) — los tres jobs
en verde:

| Job | Resultado | Duración |
|---|---|---|
| `Puerta rapida` | `success` | 1 min 31 s |
| `Linters (pre-commit)` | `success` | 5 min 34 s |
| `Suite completa (17k tests)` | `success` — **17 265 passed, 2 skipped, 0 failed** | 17 min 40 s |

⚠️ **Dato que corrige la línea base documentada del proyecto:** los **17 fallos "preexistentes"** que
aparecen al correr la suite en macOS local **no existen en Linux CI**. La primera ejecución de esta
suite en CI en toda la vida del fork sale limpia. Los 17 son un artefacto del entorno local, no una
deuda del fork.

**Permisos, explícitos en los dos workflows y a propósito.** `ci-fork.yml` declara
`contents: read` + `actions: write` (lo exige `actions/upload-artifact`), y `sync-upstream.yml` añade
`actions: write` al job `sync` (lo exige `gh workflow run`). Sin declararlos, el scope sale del ajuste
de repo *Workflow permissions*, que **no está versionado** y que GitHub pone en solo lectura para los
repos nuevos desde 2023 — o sea que un repo replicado para un cliente los rompería, y de forma
engañosa: el job `suite` saldría rojo por el `upload-artifact`, no por los tests.

**Conflicto potencial al actualizar upstream:** **ninguno.** `ci-fork.yml` y `sync-upstream.yml` no
existen en upstream, y el propio `sync-upstream.yml` descarta todo `.github/workflows/` que llegue
del merge. La línea en blanco de `manage.py` sí puede conflictuar, pero `manage.py` ya era un archivo
con parche local y ya estaba en la lista de conflictos previsibles.

### 2026-09-01 — Guion de chequeo de migraciones (base: 3.22.67)

**Archivos añadidos:**

- `scripts/check-migrations.sh` — **nuevo, sin equivalente en upstream.** Responde una sola
  pregunta —¿está la base migrada a la altura del código?— y **no muta nada**: nunca corre
  `migrate`. Existe porque `manage.py migrate --check` es mudo (0 bytes en stdout, verde o rojo)
  y solo habla por exit code; el guion genera el mensaje: ante pendientes lista **cuáles**
  (vía `showmigrations --plan`) y el comando exacto para aplicarlas.
  Contrato de salida: **0** = base al día · **1** = hay migraciones pendientes (accionable:
  migrar) · **2** = **no se pudo responder** la pregunta (base inaccesible o inexistente,
  Postgres apagado, entorno Python roto). **2 significa "no sé", no "está mal"**: conflarlo con 1
  llevaría a correr `migrate` contra una base apagada.
  Intérprete configurable con `${PYTHON:-python}` (local recibe `.venv/bin/python`; en la imagen
  vale el del PATH). `sh` POSIX puro, como los otros dos guiones de `scripts/`.
  **Sonda de conexión previa (B-383):** antes de `migrate --check` corre `manage.py shell -c`
  con `ensure_connection()` + `SELECT 1`; si falla, exit 2 directo (base o entorno), sin depender de
  que `migrate --check` deje un Traceback. El Traceback / código≠1 se conserva como segunda red.
  Pruebas con intérprete falso (sin Postgres): `sh scripts/tests/test_check_migrations.sh`.

**Motivo:** vive en el fork porque la imagen del fork es el **único artefacto que viaja a todas las
instancias de cliente**. Ahí una sola fuente sirve a sus tres llamadores —`dev.sh` en local, la
sesión nocturna y (cuando el humano lo apruebe) el `preDeployCommand` de Railway— sin adaptarla.
El caso que lo motiva está medido: el 2026-08-28 la API local devolvió HTTP 500 en todo GraphQL
porque el sync a 3.22.67 trajo migraciones y nadie migró la base local.

**Conflicto potencial al actualizar upstream:** **ninguno.** El archivo no existe en upstream, así
que no hay nada del otro lado con qué chocar. En un re-fork limpio se copia con el resto de
`scripts/`.

### 2026-09-03 — Guion de fidelidad del esquema GraphQL y `push` en la CI (base: 3.22.67)

**Archivos añadidos:**

- `scripts/check-schema-fidelity.sh` — **nuevo, sin equivalente en upstream.** Hermano de
  `check-migrations.sh`: mismo tipo de pregunta (¿el artefacto derivado y commiteado sigue
  sincronizado con el código?), mismo contrato de salida, mismo compromiso de no mutar nada.
  Responde si `saleor/graphql/schema.graphql` es byte a byte lo que emite
  `manage.py get_graphql_schema`. **Nunca escribe sobre el esquema**: genera a un temporal
  (`mktemp -d`, fuera del repo, borrado con `trap`).
  Contrato de salida: **0** = fiel · **1** = deriva real (accionable: regenerar, y el guion
  imprime el comando exacto) · **2** = **no se pudo responder** (entorno Python roto,
  `manage.py` caído, Postgres apagado, salida vacía o que no parece un SDL).
  **La distinción 1/2 es la razón de ser del guion.** El comando de la comprobación —
  `manage.py get_graphql_schema | diff saleor/graphql/schema.graphql -` — falla de forma
  engañosa: si `manage.py` muere, su stdout sale **vacío** y `diff` reporta las ~38 000 líneas
  del archivo como diferentes. Eso parece deriva catastrófica y en realidad es "no pude
  preguntar". Por eso el guion valida el **exit code**, que la salida **no esté vacía** y que
  **empiece por `schema {`** ANTES de mirar el diff.
  Intérprete configurable con `${PYTHON:-python}`, `sh` POSIX puro, funciona desde cualquier
  cwd (resuelve la raíz desde `$0`) — las mismas convenciones que `check-migrations.sh`.

**Archivos modificados:**

- `.github/workflows/ci-fork.yml` — tres cambios:
  1. Trigger `push: branches: ['stable/*']` nuevo.
  2. Paso nuevo en `puerta`: `uv run sh scripts/check-schema-fidelity.sh`, colocado junto a
     `No faltan migraciones`, que es su hermano conceptual.
  3. `github.event_name != 'push' &&` antepuesto a los `if:` de `linters` y `suite`, con el
     segundo término entre paréntesis.

**Motivo — por qué el invariante no estaba vigilado en ningún sitio:**

`saleor/graphql/schema.graphql` está commiteado en el fork y **el storefront Nuxt vendoriza esa
copia** para generar sus tipos TypeScript. Si un parche local toca la capa GraphQL y nadie
regenera, el archivo miente aquí y la mentira se descubre allá: en otro repo, días después.
Medido el 2026-09-03, el enforcement era **cero en el camino que se usa**:

| Vía | Estado medido |
|---|---|
| Hook `gql-schema-check` de `.pre-commit-config.yaml` | Declarado, pero **`.git/hooks/` solo tiene los `.sample`**: `pre-commit install` nunca se corrió. No se dispara en ningún commit local. |
| `ci-fork.yml` | Disparaba solo en `pull_request` sobre `stable/*` y `workflow_dispatch`. **Sin trigger `push`.** |
| Despliegue real | **Push directo a `stable/3.22`, sin PR.** |

O sea: el único camino que se usa no pasaba por ninguna de las dos comprobaciones.

**Motivo — por qué el check entra en `puerta` y no en `linters`:**

`puerta` es el job que corre siempre, y el check de esquema es de la **misma clase** que
`makemigrations --check`: artefacto derivado desincronizado del código. `linters` corre
`pre-commit run --all` **entero** —mypy, semgrep, deptry, ~20 min de runner— para un resultado
que cuesta **9,5 s** (medido en local, ver abajo); y además `linters` no corre en `push`, que es
justo el camino a cubrir. `suite` tampoco entra en `push`: 60 min de runner que no gatean nada,
porque **Railway despliega el commit en paralelo sin esperar a la CI**.

**El gotcha de las condiciones, y por qué había que tocarlas.** Los `if:` antiguos eran
`${{ github.event_name != 'workflow_dispatch' || inputs.alcance != 'rapido' }}`, que evalúa
**TRUE en `push`** (no es dispatch → la `or` corta en true). Añadir el trigger sin tocarlos
habría puesto los **tres** jobs a correr en cada push — 20 min de linters y 60 de suite por
commit, exactamente lo contrario de lo que se busca. Los paréntesis del segundo término tampoco
son decorativos: en las expresiones de GitHub `&&` liga más fuerte que `||`, así que sin ellos
la condición sería `(A && B) || C` y volvería a dar true en un dispatch `rapido`.

**Qué es y qué NO es este trigger, dicho sin adornos.** En `push`, `puerta` es una **alarma
post-hoc, no un gate**. Railway no espera a la CI: cuando el job termina, la versión mala ya está
arriba. Lo que aporta es la X roja en el commit y el correo al autor — que alguien se entere en
minutos en vez de en el próximo `npm run codegen` del storefront. Un gate de verdad exigiría rama
protegida y PR obligatorio; esa es otra decisión, con otro coste de flujo, y no se toma aquí.

**Política de fallo, deliberadamente distinta por capa.** En CI, exit 1 y exit 2 fallan los dos:
un "no sé" en CI es rojo (falla cerrado). Un llamador que deba **callar** ante el 2 —la sesión
nocturna, por ejemplo— tiene que distinguirlo, y por eso el guion no colapsa los dos códigos.

**Verificación (2026-09-03, sobre el worktree `hardening/gate-esquema-1.43`):**

- Los tres códigos de salida, medidos de verdad:

| Caso | Cómo se forzó | Resultado |
|---|---|---|
| Esquema fiel | tal cual, e invocado desde `/` para probar la independencia del cwd | **exit 0** |
| Deriva real | copia del esquema con una línea borrada y cuatro añadidas, restaurada después | **exit 1**, `+1 línea(s) que faltan · -5 línea(s) que sobran` + comando de regeneración |
| Intérprete que muere | `PYTHON=/usr/bin/false` (existe, ejecutable, sale 1, stdout vacío) | **exit 2**, no 1 |
| Python real sin dependencias | `PYTHON=/usr/bin/python3` | **exit 2**, `Línea reveladora: ModuleNotFoundError: No module named 'dotenv'` |
| Intérprete mudo que sale 0 | `PYTHON=/usr/bin/true` | **exit 2**, `salió 0 pero no imprimió nada` |
| Intérprete inexistente | `PYTHON=/no/existe/python` | **exit 2** |

  Tras el caso de deriva, el `sha256` del esquema volvió a ser idéntico al de partida
  (`b4070edb…`) y `git status` quedó limpio: el guion **no escribió** sobre el archivo en ningún
  momento; la deriva la fabricó el test, no el guion.

- Coste: **9,48 s** (`time`, en local). Es lo que se le añade a `puerta`.
- `sh -n scripts/check-schema-fidelity.sh` → sintaxis OK. `shellcheck` **no está instalado** en la
  máquina; el guion no pasó por él.
- `python3 -c "import yaml; yaml.safe_load(...)"` sobre `ci-fork.yml` → válido; los triggers
  quedan `['push', 'pull_request', 'workflow_dispatch']` y `puerta` sigue **sin `if:`**.
  `actionlint` **no está instalado**; la validación es de YAML, no de la semántica de Actions.
- Tabla de verdad de los `if:` de `linters` y `suite`, con
  `A = event_name != 'push'` y `B = event_name != 'workflow_dispatch'`, `C = inputs.alcance != 'rapido'`:

| Evento | A | B | C | `A && (B \|\| C)` | Jobs que corren |
|---|---|---|---|---|---|
| `push` sobre `stable/*` | false | true | true | **false** | solo `puerta` |
| `pull_request` | true | true | true (`inputs` vacío) | **true** | los tres |
| `workflow_dispatch` `alcance: completo` | true | false | true | **true** | los tres |
| `workflow_dispatch` `alcance: rapido` | true | false | false | **false** | solo `puerta` |

- **Verificado en GitHub el 2026-09-03**, no solo razonado sobre el YAML. Push de `5d27391e` a
  `stable/3.22` a las 19:21 → run
  [33821463025](https://github.com/aclicona/licona-saleor/actions/runs/33821463025), evento `push`:
  `Puerta rapida` **success**, `Linters (pre-commit)` **skipped**, `Suite completa` **skipped** —
  exactamente la fila `push` de la tabla de arriba. El paso nuevo salió
  `[check-schema-fidelity] El esquema commiteado es fiel al código`, en **~10 s** (00:23:05 →
  00:23:15 UTC).
- **Y de paso quedó medido el agujero que el trigger `push` viene a tapar:** los dos PR abiertos del
  repo —#4 (sync 3.22.68) y #5 (bump de dependencias)— tienen runs de `ci-fork.yml` en estado
  `action_required` con **0 s y CERO jobs ejecutados**. Es el gotcha ya documentado (un PR abierto
  con `secrets.GITHUB_TOKEN` no dispara workflows), pero su consecuencia no se había medido: el job
  `linters` —el único que corría `pre-commit run --all` y con él `gql-schema-check`— **solo se ha
  ejecutado dos veces en la vida del repo**, ambas por `workflow_dispatch` manual el 2026-08-27.

- **`AGENTS.md` (= `CLAUDE.md`, que es un symlink a él) — corregida una ruta que causaba justo
  este defecto.** La sección "Comandos clave" decía
  `python manage.py get_graphql_schema > schema.graphql`: ruta equivocada. Seguirla crea un
  `schema.graphql` huérfano en la raíz del repo y deja **sin regenerar** el archivo versionado
  de verdad, `saleor/graphql/schema.graphql` — es decir, la documentación del propio fork
  describía el camino más corto para producir la deriva que este guion viene a detectar. Ahora
  apunta a la ruta correcta y remite a `scripts/check-schema-fidelity.sh`.
  **Deuda de merge: ninguna adicional.** `AGENTS.md` ya está listado más abajo como
  "reemplazamos el de upstream entero", resuelto automáticamente vía `merge=ours` en
  `.gitattributes`.

**Conflicto potencial al actualizar upstream: ninguno.** Los **dos** archivos son propios del
fork: `scripts/check-schema-fidelity.sh` no existe en upstream, y `ci-fork.yml` tampoco (y
`sync-upstream.yml` descarta a propósito todo `.github/workflows/` que llegue del merge). Cero
deuda de merge por definición: no hay nada del otro lado con qué chocar.

### 2026-09-03 — Retirada de dos workflows en rojo crónico (base: 3.22.67)

**Archivos eliminados:**

- `.github/workflows/build-image.yml` — **propio del fork, creado el 2026-04-16.** Construía y
  empujaba `ghcr.io/aclicona/licona-saleor` en cada push y PR sobre `stable/3.22`.
  **Nunca tuvo un run verde: 0 éxitos en 36 runs**, desde su primer día hasta hoy. La causa es una
  línea que falta, no una que sobre: el workflow pide `cache-to: type=gha` a
  `docker/build-push-action@v5` sin haber corrido antes `docker/setup-buildx-action@v3`, así que
  el build usa el driver `docker` por defecto y muere siempre con
  `ERROR: failed to build: Cache export is not supported for the docker driver.`
- `.github/workflows/test-env-cleanup-cron.yml` — **heredado de upstream.** Cron diario (`0 2 * * *`
  UTC) que asume un lambda `test-env-manager` y una cuenta AWS de entornos de test de Saleor Inc.
  Nosotros no tenemos ni el lambda ni la cuenta ni los secretos (`AWS_TESTENVS_ACCOUNT_ID`,
  `AWS_TESTENVS_CICD_ROLE_NAME`), así que muere en el primer paso.
  **12 de 12 runs en rojo.** Nótese que es el *cron*: `test-env-cleanup.yml` (el disparado por
  evento de PR) se queda, porque sin `schedule` no se ejecuta solo.

**Por qué borrar y no arreglar `build-image.yml` — lo medido, no lo opinado:**

| Pregunta | Medición del 2026-09-03 |
|---|---|
| ¿Existe la imagen? | `gh api /users/aclicona/packages/container/licona-saleor/versions` → **`404 Package not found`**. Nunca se publicó ni una versión. |
| ¿Quién la consume? | `grep -rn "ghcr.io/aclicona/licona-saleor"` sobre los **tres** repos y todas las docs → **cero coincidencias**. |
| ¿La usa Railway? | No. `railway.json` declara `"builder": "DOCKERFILE"`: Railway construye desde el fuente. |
| ¿La usa el escaneo? | No. `security-scan.yml:20` hace `docker build -t licona-saleor:scan .` en local; no lee GHCR. |

Un artefacto que nunca existió y que nadie lee no es una pieza rota: es una pieza que no está en
el sistema. **El artefacto de replicabilidad real de este fork es el `Dockerfile` versionado +
`uv.lock` + el SHA de `stable/3.22`**, que es lo que Railway construye. Arreglar el workflow
habría añadido un segundo camino de build —con su propia caché, su propio drift y su propia
superficie de mantenimiento— para producir bits que nadie iba a descargar.

**Por qué corría prisa, y no era estética.** `build-image.yml` disparaba en `push` a `stable/3.22`,
o sea en la **misma lista de checks del commit** que el guardarraíl `puerta` de `ci-fork.yml`
instalado hoy. Medido sobre el HEAD `30e235659e`: `Puerta rapida: success`, `trivy: success`,
`build: failure` → **estado agregado del commit = `failure`**. El guardarraíl recién puesto nacía
ya dentro de una X roja permanente, que es la forma más rápida de enseñarle a un equipo que las X
rojas de este repo no significan nada.

**Regla general que esto fija, aplicable a todo el fork:**

> **Lo que no está en el árbol no existe para la instancia N+1.** Se borra en el árbol, **nunca**
> con `gh workflow disable` ni desde la UI de Actions.

El modelo de negocio es single-tenant replicable: cada cliente es un clone. El estado de "disabled"
de un workflow vive en la base de datos de GitHub del repo original y **no se clona**; el archivo
sí. Deshabilitar por UI produce una instancia N+1 que arranca con el cron rojo del día uno y con
un humano preguntándose por qué "en el repo de referencia no salía".

**Archivos modificados:**

- `.github/workflows/sync-upstream.yml` — el reset de `.github/workflows/` pasa a ser una
  restauración **completa** del directorio:

  ```sh
  rm -rf .github/workflows
  if ! git checkout "$BASE_SHA" -- .github/workflows/; then
    echo "::error::No se pudo restaurar .github/workflows/ desde $BASE_SHA."
    exit 1
  fi
  ```

  **Motivo:** `git checkout <sha> -- <dir>` **restaura** lo que existe en `<sha>` pero **no elimina**
  lo que el merge haya dejado en el índice y `<sha>` no tenga. El comentario del propio archivo ya
  daba por hecho que descartaba "los workflows de upstream" en bloque; no era cierto. El defecto ya
  existía —bastaba con que upstream añadiera un workflow para que el push muriera con el error de
  permiso `workflows` que ese mismo comentario documenta—, y borrar archivos del fork lo amplía:
  upstream **sigue teniendo** `test-env-cleanup-cron.yml`, así que cada merge semanal lo
  re-añadiría y el `checkout` no lo quitaría. El `git add -A` que ya estaba tres líneas más abajo
  estagea las eliminaciones sin cambio adicional.

  **Por qué el `if !` en vez del `|| true` heredado:** el paso corre con `set -uo pipefail`, **sin
  `-e`**. Con `rm -rf` delante, un `|| true` convertiría un `checkout` fallido en "borra los 24
  workflows y ábrelo como PR de sync". Se comprueba a mano y se sale con 1: falla cerrado.

- `UPGRADE_NOTES.md` — la línea de "Archivos creados" del 2026-04-16 documentaba `build-image.yml`
  como pieza activa; ahora dice que se retiró y apunta aquí. La receta de salto de minor (3.22 →
  3.23) mandaba "apuntar `build-image.yml` y `sync-upstream.yml` a `stable/3.23`": era una
  instrucción hacia un archivo que ya no existe.

**Receta literal de reintroducción**, si algún día hace falta publicar imagen. Lo que faltaba era
un paso, en este orden, antes del `build-push-action`:

```yaml
      - name: Set up Buildx
        uses: docker/setup-buildx-action@v3
```

Sin él, el driver por defecto es `docker`, que no implementa export de caché; con él se levanta el
driver `docker-container`, que sí. Es la línea que habría bastado, y es exactamente la razón por la
que borrarlo no es "renunciar a algo difícil".

**Condiciones que tendrían que cumplirse para que valga la pena volver a añadirlo** — ninguna se
cumple hoy, y por eso no se añade:

1. **Varias instancias que deban recibir bits idénticos** sin reconstruir cada una. Hoy hay una
   instancia y Railway reconstruye; con N clientes, N builds de la misma imagen es desperdicio y,
   peor, N oportunidades de que los bits difieran.
2. **El build de Railway convertido en cuello de botella** (tiempo de despliegue o minutos de
   build) de forma medida, no supuesta.
3. **Necesidad de rollback a una imagen pinneada** por digest que el historial de despliegues de
   Railway no cubra.

Si se reintroduce: el workflow vuelve **al árbol** (no se rehabilita nada por UI), se le añade el
`setup-buildx-action`, y **se verifica que el package existe en GHCR** antes de anotarlo aquí como
pieza activa — que es precisamente el paso que no se dio en abril.

**Conflicto potencial al actualizar upstream:** **ninguno, por construcción.**
`build-image.yml` es propio del fork y `sync-upstream.yml` también.
`test-env-cleanup-cron.yml` **sí** existe en upstream y el merge semanal lo re-añadiría — es
justo el caso que cubre el `rm -rf` de arriba, que lo vuelve a borrar en cada sync sin
intervención humana. Coste de sync recurrente: **cero**, y por la misma razón de siempre:
`.github/workflows/` del fork no sigue a upstream (decisión del 2026-08-22).

### 2026-09-25 — Guion de branch protection y test de deriva del context (base: 3.22.67)

**Archivos añadidos:**

- `scripts/check-branch-protection.sh` — **nuevo, sin equivalente en upstream.** Tercer hermano
  de `check-migrations.sh` y `check-schema-fidelity.sh`: misma pregunta de fondo (¿el estado
  externo sigue sincronizado con lo que el fork afirma?), mismo contrato de tres códigos, mismo
  compromiso de **no mutar nada**. Responde si la branch protection de la rama de despliegue
  coincide con el contrato esperado. Solo hace GET: **ninguna llamada suya usa `-X`**, y el
  `gh api -X PUT ...` que imprime como remedio **jamás lo ejecuta**. Junto a ese remedio el
  guion ahora imprime un aviso: `PUT /protection` reemplaza el objeto entero, así que aplicarlo
  a ciegas borraría en silencio cualquier ajuste que el cliente ya tuviera puesto a propósito.
  Contrato de salida: **0** = coincide · **1** = deriva real (la rama existe pero no está
  protegida, o algún campo no cuadra) · **2** = **no se pudo responder** (no hay `gh`, no hay
  sesión autenticada, el repo o la rama no existen, el token no tiene permiso de admin para
  leer la protección, o la respuesta de la API es ilegible o incompleta).
  **La distinción 1/2 es la razón de ser del guion**, y aquí el modo de fallo es más sutil que
  en sus hermanos: el 404 de `/branches/<rama>/protection` es ambiguo en **tres** sentidos, no
  dos. Puede significar "la rama no existe" (typo en `REPO`/`RAMA`), "la rama existe y NO está
  protegida" —deriva real, exit 1— o, medido contra la API real, "la rama existe y SÍ está
  protegida, pero el token no tiene permiso de **admin** sobre el repo para leer el detalle"
  —exit 2, no exit 1—. Este tercer caso es el que se confundía con el segundo:
  `GET /repos/{owner}/{repo}/branches/{rama}/protection` devuelve **404, no 403**, cuando falta
  ese permiso, así que asumir "404 en `/protection` = no protegida" invierte el resultado justo
  en el caso que más importa (una réplica de cliente, o un `GITHUB_TOKEN` de CI sin
  `permissions: administration: read`). Por eso el guion consulta **primero**
  `/branches/<rama>` —que sí expone `.protected` sin permiso de admin, medido— y usa ese campo
  como desempate antes de mirar `/protection`: `.protected == false` más 404 en `/protection` es
  deriva real (exit 1); `.protected == true` más 404 en `/protection` es "no sé" (exit 2), y en
  ese caso el guion **no** imprime el `PUT` de remedio, porque sugerirlo sobre una rama que sí
  está protegida sería un consejo destructivo. La rama del 403 (token sin ningún acceso al
  repo) sigue existiendo como mecanismo secundario, pero ya no es la vía principal a exit 2: el
  mecanismo real es este 404 ambiguo, desambiguado por `.protected`. Leer el detalle completo
  de la protección sigue exigiendo un token con `admin` sobre el repo (o
  `permissions: administration: read` si esto se cablea alguna vez en un workflow).
  Parametrizable por entorno con defaults de este fork —`REPO="${REPO:-aclicona/licona-saleor}"`
  y `RAMA="${RAMA:-stable/3.22}"`—, de modo que la réplica de un cliente se verifica sin editar
  el guion: `REPO=cliente/su-saleor sh scripts/check-branch-protection.sh`. El `/` de la rama se
  escapa a `%2F` en la ruta de `gh api`. Una sola llamada para los cinco campos, con el `--jq`
  **embebido de `gh`** (no añade dependencia de un `jq` externo) y emitiendo una línea por campo
  —no `@tsv`: con `IFS` de tabulador el shell colapsa los campos vacíos y la lectura se
  desincroniza en silencio. Antes de comparar nada, el guion valida que la salida traiga
  exactamente cinco líneas y que los campos booleanos no lleguen vacíos; si no, **exit 2,
  nunca 1** — mismo principio que la guarda de `check-schema-fidelity.sh` ("salida no vacía Y
  parece un esquema" antes de mirar el diff). Sin esa validación, una respuesta vacía con
  exit 0 fabricaría cinco derivas, y una truncada a tres líneas desincronizaría los campos en
  silencio. `sh` POSIX puro, sin `set -e`, como los otros guiones de `scripts/`.

- `saleor/tests/test_fork_branch_protection_drift.py` — **nuevo, sin equivalente en upstream.**
  Mismo patrón que los tests de deriva que el proyecto ya usa en sus repos hermanos
  (`test_celery_queues_drift`, `test_smoke_baseline_prompt_drift`): compara dos fuentes que
  **tienen que** decir lo mismo y se pone rojo el día que se separan. Aquí las dos fuentes son
  la constante `CONTEXTO_ESPERADO` de `check-branch-protection.sh` y el `name:` del job `puerta`
  en `.github/workflows/ci-fork.yml` (hoy, las dos: `Puerta rapida`).
  **Por qué hace falta:** GitHub identifica los required status checks por su **nombre visible
  literal**, no por el id del job. Un rename inocente del `name:` deja la branch protection
  esperando **para siempre** un check que ya nunca vuelve a reportarse — y el síntoma no señala
  la causa: el job sigue verde con su nombre nuevo y el PR o el push se queda colgado sin
  ningún error. Nada más en la CI avisa de eso.
  Vive en `saleor/tests/` y no en la raíz porque `setup.cfg` fija `testpaths = saleor`: un
  archivo fuera de `saleor/` no lo recogería ni un `pytest` sin argumentos ni el job `suite` de
  `ci-fork.yml`. **No usa base de datos** —solo lee dos archivos de texto—, así que no pide la
  fixture `db` ni `@pytest.mark.django_db`. Es el **primer test propio del fork**.

**Motivo (por qué, no solo qué):** la branch protection de `stable/3.22` se activó en agosto y
desde entonces vivía **solo en la configuración de GitHub**. No está versionada, nadie la
revisa, y —lo que de verdad duele— **al replicar el fork para un cliente simplemente no está,
sin que nada lo diga**. Es el mismo modo de fallo que ya mordió dos veces en este repo: permiso
o ajuste implícito que no viaja con el código, se rompe lejos y miente cerca (el `schedule` que
solo dispara desde la rama por defecto; el "Workflow permissions" que GitHub pone en `read` en
los repos nuevos). El guion no puede hacer que la protección viaje —eso GitHub no lo permite—,
pero sí convierte el silencio en una **afirmación verificable**: la réplica puede preguntar y
obtener un sí o un no, con el comando de arreglo impreso.

**Contrato afirmado** (verificado el 2026-09-25 contra el repo real; coincide exactamente):

| Campo | Esperado | Consecuencia si cambia |
|---|---|---|
| `required_status_checks.contexts` | `["Puerta rapida"]` | Vacío: ningún check gatea el merge. Otro nombre: la rama espera un check que nunca llega y el merge queda bloqueado para siempre |
| `required_status_checks.strict` | `false` | En `true` exige la rama al día con la base antes de mergear |
| `enforce_admins.enabled` | `false` | **No es cosmético.** En `true` el push directo de despliegue queda en **deadlock permanente**: la vía real de despliegue de este fork es push directo a `stable/3.22`, sin PR |
| `allow_force_pushes.enabled` | `true` | En `false` bloquea **también a los admins** y rompe el rollback con `git push --force-with-lease` |
| `allow_deletions.enabled` | `false` | En `true` cualquiera con permiso de push puede borrar la rama de despliegue |

El guion no se limita a nombrar el campo que no cuadra: imprime **esperado vs encontrado y la
consecuencia concreta** de esa tabla, y acumula todas las derivas en una sola corrida en vez de
cortar en la primera.

**Límite de esa afirmación:** el guion valida esos cinco campos y **solo** esos. La API
devuelve más —`lock_branch`, `restrictions`, `required_pull_request_reviews`,
`required_conversation_resolution`, entre otros— y un exit 0 no afirma nada sobre ellos: un
repo con `lock_branch: true`, o con `restrictions` que excluya al usuario que hace el
despliegue, pasa en verde con el push de despliegue bloqueado. Ampliar la cobertura a los 11
campos queda en el backlog, no en este commit.

**No se tocó la configuración real de GitHub.** Los tres códigos de salida se ejercitaron contra
ramas que ya existían: `stable/3.22` para el 0, la rama `3.22` (existente y sin protección, como
las otras 67) para el 1, y una rama inexistente para el 2.

**Conflicto potencial al actualizar upstream:** **ninguno.** Ninguno de los dos archivos existe
en upstream y ninguno toca un archivo de upstream —el test es un archivo nuevo con nombre propio
(`test_fork_*`) dentro de un directorio que ya existía—, así que no hay nada del otro lado con
qué chocar. En un re-fork limpio se copian con el resto de `scripts/`.

---

### 2026-09-26 — Guion de los cuatro ajustes de GitHub que no se clonan (base: 3.22.71)

**Archivos añadidos:**

- `scripts/check-github-settings.sh` — **nuevo, sin equivalente en upstream.** Cuarto hermano de
  `check-migrations.sh`, `check-schema-fidelity.sh` y `check-branch-protection.sh`: misma pregunta
  de fondo (¿el estado externo sigue diciendo lo que el fork afirma?), mismo contrato de tres
  códigos, mismo compromiso de **no mutar nada** —solo `GET`, **ninguna llamada suya usa `-X`**—.
  Cubre los cuatro ajustes que la REGLA DEL FORK del 2026-09-03 enumera como «no se clonan» y que
  `check-branch-protection.sh` dejó fuera: workflows deshabilitados, *Workflow permissions*,
  aprobación de workflows en PR de fork y secrets. Parametrizable igual que su hermano
  —`REPO="${REPO:-aclicona/licona-saleor}"`—, para que la réplica de un cliente se verifique sin
  editar el guion: `REPO=cliente/su-saleor sh scripts/check-github-settings.sh`. `sh` POSIX puro,
  sin `set -e`, con el `--jq` **embebido de `gh`** (no añade dependencia de un `jq` externo).
  Contrato de salida: **0** = los dos ajustes con gate coinciden · **1** = deriva real en alguno de
  esos dos · **2** = **no se pudo responder** (no hay `gh`, no hay sesión autenticada, el repo no
  existe, el token no tiene permiso, o la respuesta de la API es ilegible o incompleta).

  **Aquí NO hay 404 ambiguo, y es exactamente lo contrario de su hermano — leer esto antes de
  copiar el mecanismo de `.protected`.** `check-branch-protection.sh` necesitó un desempate
  —consultar `/branches/<rama>` y usar `.protected`— porque
  `GET /branches/{rama}/protection` devuelve **404, no 403**, cuando falta el permiso de admin, y
  ese 404 se confunde con «la rama no está protegida». **En este guion ese problema no existe, y se
  midió para saberlo:** con un token sin `admin`, los tres endpoints con permiso restringido
  responden **403 limpio** —comprobado contra `saleor/saleor`, `cli/cli` y `microsoft/vscode`—,
  nunca un 404 confundible con «no está configurado». **Consecuencia de diseño: la única vía a
  exit 1 es un `200` con un valor distinto del esperado, y todo fallo de llamada —403, 404, 5xx,
  salida ilegible— es exit 2, sin desempate y sin heurística.** No replicar aquí el mecanismo de
  `.protected` por analogía con B-548: sería complejidad sin causa, y una heurística de más es una
  vía de más a un veredicto equivocado.

  **Asimetría de permisos, medida:** `GET /actions/workflows` **no exige admin** —funciona en la
  réplica de un cliente aunque el operador no lo sea—; los otros tres sí. Es el único de los cuatro
  que una réplica puede verificar sin privilegios, y por eso su afirmación es la que de verdad
  viaja.

  **GOTCHA con dientes — `/actions/workflows` devuelve 24 entradas para 23 archivos.** La extra es
  `dynamic/dependabot/update-graph` (`Dependency Graph`): un pseudo-workflow **sin archivo en el
  árbol**, que GitHub registra por su cuenta. Sin filtrar por `path` que empiece por
  `.github/workflows/`, el guion fabrica una deriva falsa **el día uno**. Con el filtro puesto, el
  cruce contra el árbol da **cero delta** en este fork.

  **Y al revés: `state: active` NO implica que el archivo exista.** En `saleor/saleor` hay **cuatro
  workflows en `active` cuyo archivo está borrado**, uno desde **2024-09-13**: GitHub **nunca** los
  transiciona a `deleted`. Por eso el cruce se hace en **las dos direcciones** —registro sin archivo
  y archivo sin registro—, no solo en la que parece obvia. Este fork ya conocía la cara opuesta:
  `tests-and-linters.yml` está en `deleted` con el archivo presente en el árbol.

  **El enum de `state` tiene CINCO valores, no dos**, verificado contra
  `github/rest-api-description`: `active`, `deleted`, `disabled_fork`, `disabled_inactivity` y
  `disabled_manually`. En vivo solo se han observado `active` y `disabled_manually`. Los otros tres
  se tratan igual —cualquier cosa que no sea `active` en uno de los tres propios es deriva— para no
  quedarse corto el día que aparezca `disabled_inactivity`, que GitHub aplica **solo**, sin que
  nadie toque nada.

  **El manejo de errores no se puede derivar de la especificación.** El OpenAPI declara **solo
  `200`** para `actions/permissions/workflow`, `actions/secrets` y `actions/workflows`, y los tres
  devuelven **403 real** cuando falta permiso. `fork-pr-contributor-approval` es el **único** con un
  `404` documentado en el OpenAPI, y **no se pudo provocar** en ninguna medición; se mapea a 2, que
  es la respuesta conservadora. Dicho de otro modo: los códigos que este guion trata son los
  **medidos**, no los publicados.

- `saleor/tests/test_fork_github_settings_drift.py` — **nuevo, sin equivalente en upstream.** Mismo
  patrón que `test_celery_queues_drift` y `test_fork_branch_protection_drift`: compara dos fuentes
  que **tienen que** decir lo mismo y se pone rojo el día que se separan. Sostiene la parte del
  contrato que **el árbol sí puede afirmar** y la API no debería. Cinco tests sobre las dos
  constantes del guion, `WORKFLOWS_PROPIOS` y `SECRETS_ESPERADOS`:

  1. Cada ruta de `WORKFLOWS_PROPIOS` **existe** como archivo. Es el isomorfo exacto del fallo que
     B-548 vigila con el `name:` del job `puerta`: si alguien borra un workflow del árbol y no toca
     la constante, el guion exigiría para siempre el `active` de un archivo inexistente — un exit 1
     inarreglable.
  2. Cada uno de esos workflows **declara su bloque `permissions:`** (a nivel raíz o en todos sus
     jobs). **Es el test más valioso de los cinco**, porque nada más en la CI protege ese bloque:
     borrarlo devuelve el workflow al ajuste no versionado **en silencio**, que es el fallo entero
     que el comentario de `ci-fork.yml` fue escrito para prevenir — y ese comentario sobreviviría
     intacto al cambio que lo invalida.
  3. Todo `${{ secrets.X }}` con `X` distinto de `GITHUB_TOKEN` en un workflow propio está en
     `SECRETS_ESPERADOS` (hoy: conjunto vacío). Esta es la afirmación verificable que está **detrás**
     del `total_count == 0` de secrets, y la razón de que ese endpoint se quede en informativo: lo
     que importa no es cuántos secrets haya puestos, sino que el árbol no necesite ninguno. Recorre
     el **YAML cargado, no un regex sobre el texto crudo** — `ci-fork.yml` nombra
     `secrets.GITHUB_TOKEN` dentro de un **comentario**, y un regex lo leería como uso real. El
     falso positivo está demostrado en las dos direcciones en la verificación del turno.
  4. Ninguna entrada esperada cae fuera de `.github/workflows/`, que blinda el gotcha de la entrada
     sintética `dynamic/dependabot/update-graph`.
  5. Guarda mínima, espejo de `test_guion_y_job_existen`: el guion existe y sus dos constantes se
     leen y no están vacías. Distingue «falta la pieza» de «las dos fuentes se separaron».

  **Lo que este test deliberadamente NO afirma, y conviene saberlo:** la dirección inversa —que todo
  workflow del árbol esté en `WORKFLOWS_PROPIOS`—. No hay en el árbol un discriminador fiable entre
  «propio del fork» y «heredado de upstream», y el de `git log` no sirve porque los tres jobs de
  `ci-fork.yml` usan `actions/checkout@v5` **sin `fetch-depth`**, o sea profundidad 1. Queda escrito
  en el docstring en vez de inventar un marcador nuevo. Vive en `saleor/tests/` porque `setup.cfg` fija
  `testpaths = saleor` —un archivo fuera de `saleor/` no lo recogería ni un `pytest` sin argumentos
  ni el job `suite` de `ci-fork.yml`—. **No usa base de datos**: solo lee archivos de texto, así que
  no pide la fixture `db` ni `@pytest.mark.django_db`.

**Motivo (por qué, no solo qué):** el 2026-09-25 `check-branch-protection.sh` convirtió **uno** de
los cinco ajustes no versionables que enumera la REGLA DEL FORK —la protección de rama— de supuesto
en afirmación verificable. Los otros cuatro seguían exactamente igual que antes: rompen lejos,
mienten cerca, y no había nada en el árbol que avisara. El modo de fallo de *Workflow permissions*
ya estaba **documentado y medido** en este repo desde agosto: `ci-fork.yml` lleva un bloque
`permissions:` explícito **precisamente porque** el ajuste de repo no viaja, y en una réplica sin él
`actions/upload-artifact` fallaría con 403 y tumbaría el job `suite` **entero** — un run donde los
17k tests pasaron se vería como suite fallida. Lo que faltaba no era saber cómo se rompe: era que
alguien lo preguntara. Este guion es además la **lista de verificación ejecutable al replicar el
fork para un cliente**, que hasta hoy no existía en ninguna parte, ni siquiera en prosa.

**Contrato del guion** (valores medidos el 2026-09-26 por dos frentes independientes, que
coincidieron):

| Ajuste | Endpoint (`GET`) | ¿Exit 1? | Qué afirma · consecuencia medida |
|---|---|---|---|
| Workflows deshabilitados | `/actions/workflows` | **SÍ** | Los tres propios (`ci-fork.yml`, `sync-upstream.yml`, `security-scan.yml`) en `active`, y ninguno de los 23 del árbol deshabilitado. Uno de los tres en `disabled_*`: la verificación del sync o la suite dejan de correr **sin ningún error**, igual que ya pasa con el `deleted` de `tests-and-linters.yml` |
| *Workflow permissions* | `/actions/permissions/workflow` | **SÍ** | `default_workflow_permissions == "read"`. En `write`, el repo concede a todo workflow sin bloque `permissions:` mucho más de lo que necesita — incluidas las maquinarias de upstream que el fork no usa |
| Aprobación de PR de fork | `/actions/permissions/fork-pr-contributor-approval` | NO | Solo imprime `approval_policy`. Sin consecuencia medible en este fork: cero secrets, despliegue por push directo, y el único autor automático de PRs es `GITHUB_TOKEN`, al que la política **no gatea en ninguno de sus tres valores** |
| Secrets | `/actions/secrets` | NO | Solo lista nombres y `total_count`. Un `total_count` mayor que cero es **información** («hay secrets de más»), no avería: afirmarlo degradaría el significado del verde |

**El guion nace en exit 1 sobre este repo, y es A PROPÓSITO. No lo "arregles" cambiando el esperado
a `write`.** El valor medido hoy en `aclicona/licona-saleor` es `default_workflow_permissions=write`,
así que la primera corrida sale en **1**. Eso no es un bug del guion ni un falso positivo: es la
deriva que el guion existe para delatar, y se cierra con **un toggle en la UI de GitHub**, no
editando la constante. Ruling de Fable del 2026-09-26, literal:

> El contrato tiene que decir lo que el fork **necesita**, no lo que **tiene**: los tres workflows
> propios llevan `permissions:` explícito y son inmunes, así que el fork no necesita `write`, y una
> réplica de cliente que nazca en el default de GitHub (`read`) **debe salir verde**, que es
> justamente el caso de uso del guion. El rojo de hoy en este repo es deriva real y accionable (un
> toggle), no un falso positivo; las dos maquinarias de upstream que dejarían de funcionar en `read`
> (`bump-dependencies.yml`, `create-tag-with-release-pr.yml`) no las usa el fork, y que dejen de
> disparar con permisos que nadie les concedió es consecuencia deseable, no avería.

> **B-946 (2026-10-16):** `smoke-imagen.yml` entra en `WORKFLOWS_PROPIOS` (ahora son cuatro). Antes no podía:
> GitHub no registra un workflow hasta que corre una vez, y 1.d habría exigido el `active` de algo ausente de la
> API. Ya corrió (run 37458309142, dispatch, verde) y GitHub lo registró `active`. Declara `permissions:
> contents: read` a nivel raíz (líneas 25-26), así que es inmune igual que los otros tres. El texto de arriba
> es el ruling de 2026-09-26, literal, cuando eran tres.

La inmunidad de los tres workflows propios está **medida**, no supuesta: `ci-fork.yml:26-28`,
`sync-upstream.yml:47-61` y `:557-559`, y `security-scan.yml:12-14` declaran su `permissions:` por
job, así que el ajuste de repo no los alcanza. En el mismo turno se corrigió la REGLA DEL FORK en
`memory/saleor-api/README.md` para que fije `read` en vez de limitarse a nombrar el ajuste: la regla
y el guion no pueden contradecirse. **No es el mismo commit** porque `memory/` vive en el repo raíz
de `ecommerce`, no en este; sí es el mismo turno.

**Los otros valores medidos**, que el guion imprime sin afirmar: `can_approve_pull_request_reviews`
= `true`, `approval_policy` = `first_time_contributors`, secrets `total_count` = `0`, y 24 workflows
en `active`. `can_approve_pull_request_reviews` merece un párrafo propio aunque no se afirme: en
`false` **rompe el `gh pr create` de `sync-upstream.yml` en el último paso**, con la rama ya empujada
y la suite ya disparada. El sync se queda sin PR, invisible para quien solo mira PRs abiertos, y se
repite igual **cada lunes**. Se imprime para que quien lea la salida lo vea; no se afirma porque su
valor por defecto no es el que el fork necesita en todas las réplicas.

**Desempate descartado por medición, para que nadie lo reintente.** Se consideró inferir la política
de PR de fork desde `/actions/runs?status=action_required` cruzado con `head_repository.fork`. **No
sirve:** `head_repository.fork` es `true` para **cualquier** rama de un repo que *sea* fork, y los 8
runs en `action_required` de este fork tienen `head_repository == repository` —son PRs del mismo
repo—. La causa real de esos runs es la salvaguarda antibucle del `GITHUB_TOKEN` que `ci-fork.yml`
ya documenta, no la política de aprobación. La señal no discrimina; por eso ese ajuste se queda en
informativo y no en afirmación.

**Límite de esa afirmación:** el guion pone en rojo **dos** ajustes y solo dos. Los otros dos se
imprimen, y un exit 0 **no afirma nada** sobre ellos: un repo con `approval_policy` restrictiva, con
secrets de sobra o con `can_approve_pull_request_reviews` en `false` pasa en verde. Tampoco afirma
nada sobre los ajustes de GitHub que ninguno de los cuatro endpoints cubre (Dependabot, entornos,
reglas de merge). El verde de este guion significa «los dos ajustes que rompen la CI en silencio
están bien», no «el repo está bien configurado».

**No se tocó la configuración real de GitHub.** Todas las mediciones son `GET`. El
`default_workflow_permissions=write` de hoy se deja **tal cual**: cambiarlo es una decisión de
consola que le corresponde a Andrés, y el guion ya la delata cada vez que corre.

**Conflicto potencial al actualizar upstream:** **ninguno.** Ninguno de los dos archivos existe en
upstream y ninguno toca un archivo de upstream —el test es un archivo nuevo con nombre propio
(`test_fork_*`) dentro de un directorio que ya existía—, así que no hay nada del otro lado con qué
chocar. En un re-fork limpio se copian con el resto de `scripts/`. Lo que **sí** puede cambiar con
un sync es el **conteo de 23 workflows** del árbol: un workflow nuevo de upstream lo mueve, y el
cruce en las dos direcciones lo delata como deriva. Es el comportamiento deseado —hay que mirarlo—,
no una avería del guion.

---

## Pendiente de upstream

| Tema | Estado a fecha 2026-09-26 (3.22.71 / 3.23.36) |
|---|---|
| Fix de `discount.0052` para PostgreSQL 15+ | **Corregido en upstream, pero solo en la línea 3.23.** Verificado el 2026-09-26: el commit `f47392d874` arregla el mismo bug con un enfoque más preciso (dropea solo constraints FK/UNIQUE, en lugar de tragarse cualquier excepción), y lo hace **modificando la migración 0052 in-place** — `git diff --name-status 3.22.71 3.23.36 -- saleor/discount/migrations/` → `M saleor/discount/migrations/0052_drop_sales_constraints.py` (y `M .../0045_promotions.py`) — pero ese commit **no es ancestro de `3.22.71`**: solo existe en 3.23. Dentro de 3.22 nuestro parche **sigue siendo necesario** — no volver a auditarlo desde cero, solo confirmar en el próximo sync que sigue sin backportearse. **Trampa para el salto a 3.23:** Django no reejecuta una migración ya aplicada, así que el fix de upstream **no correrá** sobre una base ya migrada, y nuestra versión del parche se tragaba *cualquier* excepción (`exception when others then null`), sin garantía de que los constraints se hubieran soltado de verdad. → Antes del salto, verificar en la base de datos real que los constraints objetivo ya no existen: es la única parte del salto que puede haber dejado la BD en un estado distinto del que el código supone. |

## Deuda del fork

| Tema | Detalle |
|---|---|
| — | Sin deuda abierta. (`python-dotenv` transitivo: **resuelto el 2026-08-22**.) |

---

## Historial de actualizaciones de upstream

| Fecha | De | A | PR | Notas |
|---|---|---|---|---|
| 2026-04-16 | — | 3.22.48 | — | Versión base inicial del fork |
| 2026-08-24 | 3.22.48 | 3.22.67 | [#3](https://github.com/aclicona/licona-saleor/pull/3) | 19 parches. **Dos CVE**: 2026-48744 (bypass de autorización) y 2026-44472 (secuestro de fusión de cuentas). Único conflicto `uv.lock`, regenerado. 3 migraciones, ninguna destructiva. Cero breaking changes de GraphQL. Ver [bitácora](../docs/hardening/sessions/2026-08-24-sync-upstream-3.22.67.md) |
| 2026-09-25 | 3.22.67 | 3.22.71 | — | 4 parches (3.22.68..3.22.71). **Un parche de seguridad**: mitigación de DoS por *decompression bomb* de imagen (CWE-409), nuevo `MAX_IMAGE_PIXELS` con valor por defecto 30 M px (admite 5000×5000 con margen; Pillow recibe la mitad del valor a propósito). Ningún CVE/GHSA anunciado para el rango. Único conflicto `uv.lock`, regenerado. Bumps `cryptography` 50.0.1, `pyjwt` 2.15.0, `sqlparse` 0.6.0. `product/0173` modificada (no nueva: no se re-ejecuta). Cero cambios en `schema.graphql`. |

---

## Cambios de comportamiento heredados de upstream (no son parches nuestros)

Un sync no solo trae fixes: trae **cambios de comportamiento que nadie pidió**. Estos son
los del rango `3.22.48 → 3.22.67`, auditados el 2026-08-24. Ninguno rompe hoy, pero los
tres cambian lo que la API hace.

| Cambio | Qué cambia | ¿Nos toca hoy? |
|---|---|---|
| **`accountConfirmMergeMode`** (fix de CVE-2026-44472, migración `site.0041`) | El campo nace en `merge_disabled`, así que `confirmAccount` **deja de asociar** a la cuenta los pedidos y gift cards hechos como invitado. Antes lo hacía siempre — que era justo el CVE. | **No.** El storefront no usa `confirmAccount` en ninguna parte: la auth de clientes es la Fase 4. **Pero cuando la Fase 4 llegue, el default habrá cambiado en silencio.** Ver el ítem del backlog y el ruling de Fable en la bitácora del 2026-08-24. |
| **Desempate de cursores** (`saleor/graphql/utils/sorting.py`) | Los cursores de paginación ganan un componente `pk`. Los cursores emitidos **antes** del deploy se rechazan con `Received cursor is invalid.` | **No.** Verificado: el storefront pasa `after: null` y solo usa `endCursor` dentro de la misma sesión (`app/pages/categoria/[slug].vue:69`, `all.vue:64`). No persiste cursores en URL ni en `localStorage`. |
| **Filtros de atributos** | `products`/`pages` dejan de matchear valores de atributos **desasignados** del product type. Un filtro que devolvía N productos puede devolver menos. | **No.** El storefront no filtra por atributos: sus dos queries (`products.graphql`, `categories.graphql`) no usan `attributes:`. |

⚠️ El default de `account_confirm_merge_mode` lo calcula la migración `0041` **en tiempo
de migración**, a partir de `settings.ACCOUNT_CONFIRM_ASSOCIATE_ANONYMOUS_OBJECTS`. Sobre
una instancia ya migrada, cambiar ese setting es un **no-op**: el único mecanismo que
funciona es la mutación `shopSettingsUpdate(accountConfirmMergeMode: ...)`.

---

## Cuánto divergimos de upstream — medido, no estimado

Esto es lo que hace manejable cada actualización, y conviene volver a medirlo antes de
cada upgrade (`git diff --numstat <tag-base> stable/3.22`):

**Remedición del 2026-08-24, contra `3.22.67` (tras el sync): la divergencia NO creció.
Siguen siendo ~20 líneas de código de Saleor, exactamente las mismas.**

| Archivo | Líneas | Qué es |
|---|---|---|
| `manage.py` | +3 | `load_dotenv()` |
| `saleor/asgi/__init__.py` | +4 | `load_dotenv()` |
| `saleor/celeryconf.py` | +3 | `load_dotenv()` |
| `pyproject.toml` | +1 | `python-dotenv` como dependencia directa |
| `saleor/discount/migrations/0052_drop_sales_constraints.py` | +7 −3 | fix PostgreSQL 15+ |
| `uv.lock` | +2 | consecuencia de la anterior |
| `Dockerfile` | +16 −2 | `netcat-openbsd` + `ENTRYPOINT` de Railway |

Que la divergencia **no crezca** tras absorber 19 parches es el dato que importa: es lo
que mantiene viva la estrategia A (re-fork limpio) para el salto a 3.23. Medido con
`git diff --stat 3.22.67 stable/3.22 -- . ':!.github' ':!AGENTS.md'` — todo lo demás son
archivos que upstream no tiene.

Todo lo demás son **archivos que upstream no tiene** —`railway.json`,
`scripts/railway-entrypoint.sh`, `scripts/wait-for-db.sh`, `scripts/check-migrations.sh`,
`scripts/check-schema-fidelity.sh`, `scripts/check-branch-protection.sh`,
`saleor/tests/test_fork_branch_protection_drift.py`,
este archivo, nuestros tres workflows, `docs/superpowers/`— y **no pueden conflictuar**:
no hay nada del otro lado con qué chocar.

**El producto no vive en este repo.** `storefront` y `saleor-apps` hablan con Saleor por
GraphQL, no por sus internals. Por eso el riesgo de un upgrade está en **el esquema
GraphQL**, no en este fork.

### Los tres conflictos previsibles

| Archivo | Por qué | Cómo se resuelve |
|---|---|---|
| `AGENTS.md` | Reemplazamos el de upstream entero | **Automático** vía `merge=ours` en `.gitattributes` — requiere `git config merge.ours.driver true` (ver abajo) |
| `uv.lock` | Upstream lo marca `-merge`: siempre conflictúa, a propósito | **Regenerar**, no resolver, y **partiendo del lock de upstream** (`git checkout <tag> -- uv.lock`) para heredar sus versiones: `uv tool run uv@<version-que-pinea-el-Dockerfile> lock` |
| `0052_drop_sales_constraints.py` | Único cambio nuestro con lógica propia | **Revisar a mano** si upstream tocó esa migración. Es el único que merece atención real |

> **Nota (2026-09-26):** la medición real contra `3.23.36` (ver "Medición del salto 3.22 → 3.23" más abajo) encontró conflictos distintos de los previstos aquí: los 3 atribuibles al fork fueron `.env.example`, `Dockerfile` y `.github/workflows/test-env-cleanup-cron.yml` — no `AGENTS.md` —que sí difiere mucho de upstream (+70/−418 líneas contra `3.23.36`), así que su ausencia se atribuye al `merge=ours` de `.gitattributes`, **sin haberlo confirmado**— ni `0052_drop_sales_constraints.py` (esa migración cambió en upstream, pero solo en 3.23 — ver "Pendiente de upstream"). Útil como intuición inicial; la medición manda.

## Medición del salto 3.22 → 3.23 (2026-09-26, reporte B-578)

Complementa la remedición del 2026-08-24 (arriba): aquella medía ~20 líneas de código de Saleor
contra `3.22.67` y excluía configuración; esta mide el **payload completo a reaplicar** contra
`3.22.71`, contrastado con `3.23.36` — por eso las cifras difieren entre ambas.

### El estado de soporte de upstream — el dato que fija el plazo

- `SECURITY.md` de upstream, tabla textual: `≥ 3.22` soportada, `< 3.22` no. → **3.22 es la línea
  más antigua todavía soportada.**
- Historial del archivo: *"Remove 3.20 from supported versions"* el 2026-04-17; **"Remove 3.21 from
  supported versions" el 2026-09-23** (diff verificado: `≥ 3.21` → `≥ 3.22`).
- **Matiz que importa:** la retirada de 3.21 **no coincidió con el lanzamiento de ninguna línea
  nueva** (3.24 no existe: rama 404, sin releases ni tags). Cuando salió 3.23.0 la tabla pasó a
  `≥3.21` = 3 líneas soportadas; el 2026-09-23 pasó a `≥3.22` = **2 líneas**. Upstream **recortó la
  ventana de soporte de 3 líneas a 2**, por decisión propia y sin aviso.
- Ritual de retirada observado: sale de `SECURITY.md` → una release final → **la rama se borra**
  (`3.19`, `3.20`, `3.21` → las tres dan 404 hoy).
- **3.22 está plenamente viva hoy:** `3.22.71` publicada 2026-09-24T09:06:08Z y `3.23.36`
  2026-09-24T09:06:43Z → **35 segundos de diferencia**. Cadencia de 3.22 en 90 días: 18 releases,
  una cada ~5 días, hueco máximo 13 días.
- **Cero CVEs sin parchear**: los 16 advisories del repo upstream revisados uno a uno; todos con
  parche en una `3.22.x` por debajo de 3.22.71. **Ningún fix de seguridad existe solo en 3.23+.**
- Eje 2 (rezago de línea menor) = **170 días exactos**: `3.23.0` se publicó el 2026-04-09.
- `upstream/main` está en `3.24.0-a.0` desde el 2026-03-25 (185 días de gestación). Cadencia
  histórica de minors: 313 / 142 / 181 días. **Dispersión demasiado ancha para predecir una
  fecha — no la inventes.**
- **Conclusión de plazo:** el plazo no es una fecha, es un **evento** — la publicación de Saleor
  3.24.0. Ese día 3.22 pasa a estar dos líneas por detrás y la garantía de backport de upstream
  (*"Saleor backports most of patches to at least one version behind"*, nota de release de 3.23.0)
  deja de cubrirla.

### El coste, medido

- Divergencia real a reaplicar: **+84 / −13 líneas** (`Dockerfile`, `manage.py`, `pyproject.toml`,
  `.env.example`, `.gitattributes`, `.gitignore`, `saleor/asgi/__init__.py` y
  `saleor/celeryconf.py`), más 18 archivos propios que upstream no tiene y **no pueden
  conflictuar**.
- **No hay personalizaciones de negocio en el fork**: Wompi, COP e impuestos viven en
  `saleor-apps/`, fuera de este repo.
- **Conflictos medidos en memoria** con `git merge-tree --write-tree` (no toca el árbol), usando un
  control que aísla nuestra contribución:
  - `3.23.36` × nuestro fork (`origin/stable/3.22`) → **210 conflictos**
  - `3.23.36` × upstream puro (`3.22.71`, sin fork) → **208 conflictos**
  - → **solo 3 son atribuibles al fork**: `.env.example`, `Dockerfile` y
    `.github/workflows/test-env-cleanup-cron.yml`
  - 124 de los 210 están en `saleor/graphql`, con base de fusión de 2025-10-01: son divergencia
    **entre dos líneas de release**, no entre upstream y nosotros.
  - **Esto confirma la estrategia A (re-fork) y descarta la B (merge) con números**: los 208
    conflictos inherentes tienen todos la misma resolución correcta ("tomar 3.23"), así que
    resolverlos a mano sería ruido puro con riesgo de error humano.
- **Migraciones:** 65 reales, en 12 apps. Las **3 destructivas usan `SeparateDatabaseAndState`** →
  en 3.23 no borran nada en BD, solo sueltan FKs; el borrado real está **diferido a 3.24**
  (comentario literal en `product/0204`: *"Will be dropped from the actual DB in Saleor v3.24.0"*).
  10 índices concurrentes con el patrón correcto. **Sin migraciones propias del fork** → cero
  colisión de numeración.
- **11 backfills se delegan a Celery** vía `post_migrate` → `.delay()`. **Riesgo principal del
  salto:** el `migrate` termina en segundos y *parece* completo, pero el trabajo real lo hace el
  worker después; si el worker no está arriba **con sus colas**, los datos quedan incompletos
  **sin un solo error**. → El criterio de aceptación **no puede ser "migrate terminó"**: tiene que
  ser una consulta por backfill (filas con el campo destino nulo = 0) después de que el worker
  drene.
- **Esquema GraphQL:** +5525 / −3820 líneas; 1428 → 1476 definiciones top-level. Lo eliminado son
  dos familias **ya deprecadas en 3.22**: `DigitalContent*` y `AppExtension*` legacy.
- **Los tres consumidores cruzados contra el delta por intersección de conjuntos: cero roturas.**
  `storefront` (14 operaciones), `saleor-apps` (7 webhooks con `subscriptionQuery` +
  `transactionEventReport`) y `scripts/seed/seed.py` (33 campos, el mayor del monorepo).
  Verificados idénticos en ambos tags los dos puntos de mayor riesgo:
  `ShippingListMethodsForCheckout` y la firma de `transactionEventReport`. Ambos manifiestos de
  app declaran `extensions: []`, así que la remoción de `AppExtension` no toca nada.
- **Runtime sin cambios:** `requires-python >=3.12,<3.13` y `django[bcrypt]~=5.2.17` idénticos en
  ambos tags. No hay que tocar el toolchain.

### Deuda del storefront: qué se puede adelantar y qué no

Verificado con `git show <tag>:saleor/graphql/schema.graphql` sobre el `type Checkout`:

- `shippingMethods` **ya existe en 3.22.71** (y `availableShippingMethods` ya está deprecado ahí).
  → **la migración `availableShippingMethods` → `shippingMethods` se puede hacer HOY sobre 3.22**,
  desacoplada del salto.
- `delivery` **NO existe en 3.22.71**; aparece solo en 3.23.36, que a su vez deprecia
  `deliveryMethod` en favor de `delivery`. → **`deliveryMethod` → `delivery` NO se puede adelantar:
  rompería producción.** Es trabajo post-salto.
- 3.23 no rompe ninguna de las dos. **Las rompe 3.24.**

### Lo que NO está medido (no estimarlo)

- Duración real de las migraciones: falta el conteo de filas de las tablas con backfill (Postgres
  local y Railway estaban apagados durante la medición).
- Variables de entorno reales de producción: no se pudo confirmar si algún plugin retirado en 3.23
  está activo.
- El cambio de "media por URL externa" a asíncrono (devuelve 503 mientras procesa): no probado
  contra `scripts/seed/seed.py`.
- **Estas tres son precondiciones del plan de ejecución, no notas al pie**: sin ellas no hay
  ventana de mantenimiento que proponer.

### Punto ciego de instrumentación

Hoy **nada alarma por el eje 2**: `scripts/distancia-upstream/distancia.py` reporta el eje 2 pero
**por diseño no afecta su código de salida**, y el único aviso es el issue automático
`upstream-minor` del fork, abierto desde 2026-08-23 y con el contenido ya rancio (dice "3.23.28"
cuando hoy es 3.23.36). El evento que de verdad importa — que **3.22 salga de `SECURITY.md`**, que
**aparezca la rama/tag `3.24`**, o que **se borre la rama `3.22`** — no lo vigila nadie.

---

## Decisión: el salto 3.22 → 3.23 está autorizado (2026-09-26, reporte B-584)

El dueño del repo autorizó el salto el **2026-09-26**, sobre la medición de la sección anterior.
Queda escrito aquí, y no solo en el backlog, porque quien mantenga el fork tiene que poder leer el
alcance de la autorización sin abrir otra herramienta.

**Qué se autorizó:**

- El salto **3.22 → 3.23**, por **estrategia A (re-fork limpio)** — la medición de conflictos de la
  sección anterior la confirma y descarta la B: de los 210 conflictos contra el fork **solo 3 son
  atribuibles a él** (el control contra upstream puro da 208). El resto es divergencia entre dos
  líneas de release, y toda ella tiene la misma resolución correcta: tomar 3.23.
- Ejecutado **por partes**, no en un solo paso.
- **Verificado en local antes de cualquier despliegue.**

**Qué NO autoriza:**

- **No autoriza tocar producción.** El despliegue es la parte 4/4 y **exige una ventana declarada en
  el reporte B-523**. Nada de lo autorizado aquí habilita un deploy.
- **El salto directo a 3.24 se evaluó y se descartó.** Habría significado estrenar una línea recién
  publicada acumulando dos saltos de minor y los borrados destructivos —los que 3.23 difiere vía
  `SeparateDatabaseAndState`— en un único despliegue.

### El plan, en cuatro partes

| Parte | Reporte | Qué cierra |
|---|---|---|
| 1/4 | **B-584** | Esta decisión: la autorización y su alcance, por escrito |
| 2/4 | **B-588** | Rama `stable/3.23` por estrategia A (re-fork), verificada en local |
| 3/4 | — | `storefront` contra el esquema nuevo (`codegen` + `deliveryMethod` → `delivery`) y smoke de `saleor-apps` (7 webhooks + `transactionEventReport`) |
| 4/4 | **B-523** | Re-apuntado de las 6 referencias, rama por defecto de GitHub, cierre del issue #1, y el despliegue con su ventana declarada |

Reportes independientes, que no bloquean el salto: **B-585** (deuda del storefront, adelantable
sobre 3.22), **B-586** (detector del eje 2), **B-587** (precondiciones medibles).

### La precondición que sigue sin cumplirse

Las cifras de **B-587** no existen todavía, y sin ellas **no hay ventana de mantenimiento que
proponer**:

- **Conteo de filas** de las tablas con backfill.
- **Duración real de las migraciones**, medida, no estimada.
- **Verificación en la base de datos** de que los constraints de `discount/0052` ya se soltaron.
  Upstream modificó esa migración **in-place**, y **Django no reejecuta una migración ya aplicada**:
  que el archivo nuevo haga lo correcto no dice nada sobre una instancia que ya la corrió. Hay que
  consultar el estado real de los constraints en la BD, no leer el archivo.

### El riesgo que se olvida: los backfills diferidos a Celery

Está medido arriba y se repite aquí porque es el que se pasa por alto al ejecutar: **11 de las 65
migraciones delegan su backfill a Celery** (`post_migrate` → `.delay()`). El `migrate` termina en
segundos y *parece* completo, pero el trabajo real lo hace el worker después. Si el worker no está
arriba **con sus colas**, los datos quedan incompletos **sin un solo error**.

→ El criterio de aceptación **no puede ser «migrate terminó»**: tiene que ser **una consulta por
backfill, después de drenar la cola**.

### El tag objetivo se elige en el momento de ejecutar

Hoy el candidato es **`3.23.36`**, que es contra el que se midió todo. Si al ejecutar la parte 2/4
el tag estable más reciente es otro, **hay que re-ejecutar el cruce de los tres consumidores contra
ese tag**: el resultado "cero roturas" está atado a `3.23.36`, no a la línea 3.23 en general.

El plazo sigue siendo **un evento, no una fecha**: la publicación de Saleor 3.24.0 (ver la sección
anterior).

---

## Cómo hacer una actualización

### Cómo se detecta que el fork va por detrás

La medida que responde "¿va el fork por detrás de upstream?" es
`scripts/distancia-upstream/distancia.py`, y **no vive en este fork**: está con sus tests y su README
en el repo raíz privado `aclicona/licona-ecommerce`. Dos razones: un solo dueño del guion (dos copias
derivan en silencio) y que **este repo es público**, así que ejecutarlo aquí exigiría guardar un PAT
del repo privado como secreto en un repo público. Corre desde el 2026-09-25 (B-517) vía
`.github/workflows/distancia-upstream.yml` **del repo raíz**: `cron: '0 9 * * 4'` (jueves 09:00 UTC)
más ejecución manual. Contrato de salida, el mismo de los guiones de `scripts/`: **0** = al día ·
**1** = retraso sobre el umbral (14 días por defecto) · **2** = **no se pudo medir**, que no es
"está atrasado".

⚠️ **Precondición: los tags de upstream.** `distancia.py` mide la versión del fork con `git describe`
sobre el clon que le pasen y **no hace fetch** — por eso el workflow del repo raíz trae
`refs/tags/3.22.*` de `upstream` a propósito. Contra un clon sin esos tags **miente**: en el checkout
local (14 commits por detrás de `origin/stable/3.22`) reporta 25 días de retraso cuando el real es 0.

Estado hoy: **0 días de retraso**, sincronizado a `3.22.71` el 2026-09-25 (B-516). **Ninguna corrida
programada ha ocurrido todavía**: los tres runs existentes son manuales y la primera por cron es el
jueves 2026-10-01. El sync semanal de abajo no sustituye esta medida: 5 corridas con éxito seguidas,
pero sus PR estuvieron 3-4 semanas sin atender y se cerraron sin mergear — detector sin actuador
(B-566).

### Requisito de una sola vez, en cada clone nuevo

```sh
git config merge.ours.driver true
```

Sin esto, el `merge=ours` que `.gitattributes` declara para `AGENTS.md` **no hace nada**
y el archivo conflictúa en cada sync. El driver `ours` no viene definido en git y la
config no se versiona. `sync-upstream.yml` lo ejecuta solo; los clones locales no.

### Parche dentro de la minor actual (3.22.x → 3.22.y)

1. `sync-upstream.yml` abre el PR cada lunes 9:00 UTC. Si viene con conflictos llega
   como **draft** y con el título `⚠️ CON CONFLICTOS`; los marcadores están commiteados
   a propósito, para que el PR sea revisable.
2. Resolver sobre la rama del PR: `uv.lock` regenerándolo, el resto a mano.
3. Revisar la sección "Cambios aplicados" de este archivo: es la lista de sitios donde
   nuestro código y el de upstream pueden pisarse.
4. Migraciones **contra una copia de la BD**, no solo la suite.
5. `npm run codegen` en el storefront: si el esquema GraphQL cambió, TypeScript lo dice.
6. Sacar el PR de draft y mergear a `stable/3.22`.
7. Anotar la versión nueva en el historial de abajo.

### Salto de minor (3.22 → 3.23)

> **Autorizado el 2026-09-26 (reporte B-584).** El alcance exacto de esa autorización —y lo que
> **no** cubre, en particular el despliegue— está en "Decisión: el salto 3.22 → 3.23 está
> autorizado" más arriba. Leerlo antes de empezar.

**Primero hay que estar al día dentro de la minor actual.** No se salta desde un punto
atrasado: se resuelve el sync de parches, se verifica, y recién ahí se sube de minor.

Dos estrategias, y la divergencia medida arriba decide cuál:

**A · Re-fork limpio (recomendada mientras la divergencia siga siendo de ~20 líneas)**

1. Rama `stable/3.23` desde el tag `3.23.x` estable más reciente.
2. Reaplicar los cambios de la sección "Cambios aplicados" — son pocos y están listados.
3. Copiar los archivos que upstream no tiene (`railway.json`, `scripts/`, workflows,
   este archivo).
4. Migraciones contra copia de la BD + `npm run codegen` en el storefront.

Ventaja: el árbol queda idéntico a upstream salvo lo nuestro, sin arrastrar historia de
merges. Desventaja: reaplicar a mano, y hay que acordarse de todo — por eso la sección
"Cambios aplicados" es obligatoria de mantener.

**B · Merge del tag de la minor nueva**

`git merge refs/tags/3.23.x` sobre `stable/3.22`. Preserva la historia y git hace el
grueso del trabajo, pero arrastra un merge grande. Preferible **si algún día la
divergencia crece** y reaplicar a mano deja de ser realista.

**Cierre del salto, con cualquiera de las dos:**

1. Actualizar `version` en `pyproject.toml`.
2. Apuntar `sync-upstream.yml` a `stable/3.23` (los `ref:` de los checkouts y el
   `--base` del PR). `ci-fork.yml` no hay que tocarlo: dispara sobre `stable/*`.
   (Aquí figuraba también `build-image.yml`; se retiró del árbol el 2026-09-03.)
3. ⚠️ **Cambiar la rama por defecto del repo a `stable/3.23`.**
   ```sh
   gh repo edit aclicona/licona-saleor --default-branch stable/3.23
   ```
   **No es cosmético.** `schedule` de GitHub Actions solo dispara desde la rama por
   defecto: si se olvida, el sync deja de correr **sin ningún aviso**. Es exactamente lo
   que pasó entre abril y agosto de 2026 — cuatro meses sin sincronizar, descubiertos
   por casualidad.
4. Cerrar el issue de `upstream-minor` correspondiente.
5. **Antes de dar la rama por verificada o desplegar un SHA de `stable/*`:** correr, desde la
   raíz del repo `ecommerce` (no desde este fork), el guard
   `scripts/railway-seguro/ci_desplegable.py` (B-792):
   ```sh
   python3 scripts/railway-seguro/ci_desplegable.py --rama stable/<LINEA>
   ```
   Pregunta a `gh` si algún run de `ci-fork.yml` sobre el HEAD **remoto** de la rama tiene el job
   `Suite completa (17k tests)` en `success`. Exit 0 = desplegable (stdout:
   `sha=<sha> run=<id> job=success`); 1 = rechazo (sin runs, runs en curso, suite sin success);
   2 = indeterminado (`gh` sin sesión, rama inexistente, ningún job con ese nombre). **1 y 2
   bloquean.** El push que crea la rama dispara la suite solo (B-666); para cualquier SHA
   posterior, el rechazo imprime el dispatch:
   ```sh
   GH_REPO=aclicona/licona-saleor gh workflow run ci-fork.yml --ref stable/<LINEA> -f alcance=completo
   ```
   y se repite el guard cuando el run termine. El guard es un paso previo procedimental: no
   intercepta el `redeploy` ni cubre el auto-deploy por push a `stable/*`. **Acoplamiento:** compara
   por igualdad con el `name:` del job `suite` de `ci-fork.yml`; no renombrar ese job sin cambiar
   `JOB_SUITE` en el guard (lo vigila `saleor/tests/test_fork_branch_protection_drift.py`).

### 2026-10-02 — `CELERY_BEAT_SCHEDULER` por defecto en settings (base: 3.23.37, B-700)

**Desviación del upstream.** `saleor/settings.py` define
`CELERY_BEAT_SCHEDULER = os.environ.get("CELERY_BEAT_SCHEDULER", "saleor.schedulers.schedulers.PersistentScheduler")`.

- **Por qué:** upstream exige arrancar beat con `--scheduler saleor.schedulers.schedulers.PersistentScheduler`
  (o `DatabaseScheduler`). Nuestro `startCommand` de Railway (`celery -A saleor beat`) nunca lo pasó, así que
  beat usaba el `PersistentScheduler` de Celery, cuyo `tick()` solo mira la cabeza del heap: la planificación
  condicional `promotion_webhook_schedule` (`is_due=False`, siguiente=60 s cuando no hay nada pendiente) se
  quedaba en la cabeza y bloqueaba `recalculate-promotion-rules`, `recalculate-discounted-price-for-products`, etc.
  Tras 1-2 envíos beat pasaba a `Waking up in 59.99 s` y callaba.
- **Por qué en settings y no en el comando:** no depende del `startCommand` de Railway; `celery beat` lo toma de
  `app.conf.beat_scheduler` cuando no se pasa `-S`/`--scheduler`.
- **Cómo revertir:** variable de entorno `CELERY_BEAT_SCHEDULER=celery.beat.PersistentScheduler` (o borrar la
  línea de settings). Un `--scheduler` explícito en el comando sigue mandando.
- **Test:** `saleor/schedulers/tests/test_beat_scheduler_setting.py`.
- **Al sincronizar con upstream:** si upstream ya fija el scheduler por defecto, retirar esta desviación.

### 2026-10-03 — `check-branch-protection.sh` amplía su contrato de 5 a 11 puntos (base: 3.23.37, B-553)

El guion afirmaba solo cinco campos y salía en verde con la protección real bloqueando el
despliegue (`lock_branch`, `restrictions`, `required_pull_request_reviews`...: falso verde).

- **Ahora verifica once puntos:** los cinco de antes más `lock_branch.enabled == false`,
  `block_creations.enabled == false`, `required_linear_history.enabled == false`,
  `required_signatures.enabled == false`, y la **ausencia** de `required_pull_request_reviews` y de
  `restrictions` (la API omite la clave cuando no están configuradas; su presencia es deriva, y de
  `restrictions` no se validan las listas de actores: se afirma «sin restricciones»).
- **Por qué linear_history y signatures:** medido sobre `origin/stable/3.23`, la historia tiene
  merge commits propios del fork (`chore(3.23): merge del tag upstream`) y ningún commit firmado.
  Con cualquiera de los dos en `true` el siguiente sync o push del worker se rechaza.
- **Fuera del contrato, por escrito en la cabecera del guion:** `allow_fork_syncing`,
  `required_conversation_resolution` (solo PRs) y `url`. ~~Tampoco se consultan los repository
  rulesets~~ — desde B-769 sí (ver abajo).
- **Rulesets (B-769):** el guion consulta además `GET /repos/<repo>/rules/branches/<rama>` y
  marca deriva (exit 1) si hay una regla `pull_request`, `non_fast_forward`,
  `required_linear_history`, `required_signatures` o `update` aplicable a la rama; si esa API no
  responde, exit 2 (y no tapa una deriva clásica, que sigue siendo 1). Medido el 2026-10-06:
  `gh api repos/aclicona/licona-saleor/rules/branches/stable/3.23` devuelve `[]` y `.../rulesets`
  devuelve `[]` (sin rulesets); el guion sale 0.
- **Se conserva el endurecimiento:** 404 sin admin con `.protected=true` sigue siendo exit 2;
  salida vacía, truncada o `{}` (ninguno de los campos obligatorios) es exit 2, no derivas
  fabricadas. La ausencia de `restrictions`/`required_pull_request_reviews` es estado legítimo;
  la de los obligatorios no.
- El `PUT` de remedio incluye ahora `required_linear_history`, `block_creations` y `lock_branch`;
  `required_signatures` no cabe en el PUT, y el guion indica el `DELETE .../required_signatures`.
- `saleor/tests/test_fork_branch_protection_drift.py` gana una matriz (`gh` falso + `jq`, se salta
  si no hay `jq`): conforme→0; cada campo del contrato roto→1; cuerpo vacío o `{}`→2; 404 con
  rama protegida→2, sin proteger→1.

## B-384 — `check-migrations.sh` detecta la base POR DELANTE del código

- `scripts/check-migrations.sh` gana el exit **3**: migraciones aplicadas en `django_migrations` que el código no
  conoce (rollback de deploy, worktree más viejo que la base). Solo se evalúa si `migrate --check` dio 0; los
  exit 0/1/2 existentes no cambian. Si la consulta de adelanto falla, exit 2 ("no sé").
- `wait-for-migrations.sh` trata cualquier código distinto de 0 como "reintentar", así que con 3 espera y vence
  con exit 1 al agotar `MIGRATIONS_WAIT_SECONDS`.
- Prueba: `sh scripts/tests/test_check_migrations.sh` (casos 7-9, intérprete falso).

## B-388 — hooks de pre-commit resuelven el venv solos

- Nuevo `scripts/with-venv.sh`: antepone `<raíz>/.venv/bin` (o el del clone principal, vía
  `git rev-parse --git-common-dir`, en un worktree) al PATH y falla cerrado (exit 1) si no hay venv o no tiene
  el comando. Lo usan los hooks `mypy`, `deptry`, `migrations-check` y `gql-schema-check` de
  `.pre-commit-config.yaml` (divergencia local del fork: `deptry` pasa a `language: system`).
- Prueba: `sh scripts/tests/test_with_venv.sh`.

## B-841 — drift del input `alcance=completo` de `ci-fork.yml`

- `saleor/tests/test_fork_branch_protection_drift.py` gana un test que lee el YAML y exige
  `on.workflow_dispatch.inputs.alcance` con `completo` en `options`: es el comando que imprime
  `scripts/railway-seguro/ci_desplegable.py` (repo raíz). El nombre del archivo `ci-fork.yml` queda cubierto
  porque el módulo lo lee por ruta.

## B-567 — el sync resuelve solo el conflicto mecánico de `uv.lock`

`uv.lock` conflictúa en todos los syncs (`*.lock -merge` de upstream), así que todos los PR salían
«⚠️ CON CONFLICTOS» y el aviso perdió su señal. `sync-upstream.yml` ahora ejecuta
`scripts/resolve-uv-lock.sh <tag>` tras el merge: parte del `uv.lock` del tag, corre
`uv tool run uv@<versión del Dockerfile> lock` (la versión se lee del `Dockerfile`, no es literal) y
lo agrega al índice. «CON CONFLICTOS» solo sale si queda algún conflicto en otro archivo, o si
`pyproject.toml` también conflictúa o `uv lock` falla (en ese caso `uv.lock` conserva su conflicto).
Test: `sh scripts/tests/test_resolve_uv_lock.sh`. Verificar en el primer sync real que el diff del lock
contra upstream sean solo las líneas de `python-dotenv`.

## B-540 — publicar los tags de upstream que el fork ya contiene

**Causa:** `sync-upstream.yml` hace `git fetch upstream --tags` solo dentro del runner y nunca los empuja; al
mergear el PR llega el código pero no la etiqueta. Medido: el fork tiene `3.22.48` como último tag 3.22.x (el
código está en 3.22.67) y `3.23.1` como último 3.23.x (`git describe` sobre `stable/3.23` ni siquiera encuentra tag).

**Mecanismo (implementado, apagado):** `scripts/publish-upstream-tags.sh <minor>` publica los tags `X.Y.N` que
(1) existen tras el fetch, (2) son ancestro de `stable/3.23` y (3) faltan en `origin`. El job `sync` lo invoca en
un paso `continue-on-error`. **Dry-run por defecto**: solo empuja con la variable de repo `SYNC_PUBLISH_TAGS=true`.
Test: `sh scripts/tests/test_publish_upstream_tags.sh`. Los tags se publican cuando el PR de sync ya está
mergeado (merge commit; con squash el commit del tag no sería ancestro y se omitiría).

**Decisiones para Andrés:** (a) activar `SYNC_PUBLISH_TAGS=true`; (b) backfill de los tags faltantes (3.22.49–67 y
3.23.x): `git fetch upstream --tags && PUSH_TAGS=true sh scripts/publish-upstream-tags.sh 3.22 3.23`, desde una
checkout con `TARGET_REF` apuntando a la rama que contenga el código; (c) confirmar que el `GITHUB_TOKEN` puede
empujar tags (si hay reglas de protección de tags, hará falta excepción).

**B-1280 — fallos visibles:** cuando un tag introduce commits que tocan `.github/workflows/`, `GITHUB_TOKEN` no puede
empujarlo (`refusing to allow a GitHub App to create or update workflow ... without workflows permission`) y, al ser el
paso `continue-on-error`, el job quedaba verde sin que nadie lo viera (run 38292565032, 3.23.5–3.23.10). Desde B-1280 el
script emite un `::warning title=Tag de upstream sin publicar::` por tag y un bloque en el resumen del run
(`$GITHUB_STEP_SUMMARY`) con el remedio (`gh api repos/<repo>/git/refs -f ref=refs/tags/<tag> -f sha=<sha>` con un token
con scope `workflow`). Semántica y exit code sin cambios. **Pendiente, no probado:** crear los refs por API con
`GITHUB_TOKEN` en vez de `git push` (podría esquivar la restricción); sigue sin verificarse.

**B-1482 — publicar tras el merge, no solo en el cron:** el paso del job `sync` corre ANTES de que exista el merge del
PR que ese mismo run abre, así que las tags recién absorbidas salían «omitido … (su commit aún no está en HEAD)» y
esperaban al lunes siguiente (run 38292565032: 3.23.38–41, publicadas a mano en B-1481). Nuevo
`.github/workflows/publish-upstream-tags.yml` (`push` a `stable/*` + `workflow_dispatch`) llama al mismo script con
`TARGET_REF=HEAD` y el mismo gate `SYNC_PUBLISH_TAGS`; sin `continue-on-error` (un fallo B-1280 sale en rojo). El push
a una tag no lo vuelve a disparar (filtro por ramas). Primer run: 39262302917 (verde, «tags pendientes: 0»; omitió
3.23.42/43, aún no absorbidas).

## B-418 — diagnóstico de `TransactionItem` huérfanos (solo lectura)

**Investigación:** Saleor no ofrece limpieza de `TransactionItem`. `clean_checkouts` (`saleor/checkout/tasks.py`)
borra checkouts viejos sin transacciones con valor, y `TransactionItem.checkout` es `on_delete=SET_NULL`:
el item de un intento fallido (creado por `transactionInitialize` antes de llamar a la App) sobrevive
al checkout, con `checkout` y `order` nulos, para siempre.

**Añadido (fork):** `python manage.py report_orphan_transactions --days N [--list K]` cuenta (y opcionalmente
lista) los `TransactionItem` sin orden, sin evento `*_success` y creados hace más de N días. No modifica nada.
Test: `saleor/payment/tests/test_report_orphan_transactions.py`.

**Propuesta para Andrés (NO implementada):** tarea Celery/comando de limpieza con `--apply` explícito, batches y
umbral ≥30 días, solo sobre lo que el diagnóstico liste. Primero correr el diagnóstico en producción y revisar muestra.

## B-378 — inventario de workflows heredados de upstream (SIN cambios: propuesta para Andrés)

`.github/workflows/` tiene 22 archivos: 3 del fork (`ci-fork.yml`, `security-scan.yml`, `sync-upstream.yml`) y
**19 heredados de upstream** (el backlog decía 20 de 23: ya no coincide). Análisis por lectura de triggers y
guardas `if:`; **no se revisó el historial de runs**. Regla vigente: borrar en el árbol, nunca `gh workflow
disable`; el sync ya restaura el directorio desde la base, así que el borrado persiste.

Rama por defecto del fork: `stable/3.23`; no existe rama `main` en `origin`.

| Workflow | Trigger | ¿Corre en el fork? | Propuesta |
|---|---|---|---|
| `publish-main.yml` | push a `main`, `ci/**` | No (no hay `main`) | Borrar |
| `publish-containers.yml` | `workflow_call` | Solo lo llaman `publish-main` y `create-tag-with-release-pr` | Borrar (con los dos) |
| `create-tag-with-release-pr.yml` | PR cerrado/merge | Posible, pero usa vault y `saleor-multitenant` de Saleor Inc. | Borrar |
| `publish-load-test.yml` | PR (reopened/synchronize/labeled), cualquier rama | Solo con label; usa infra de Saleor | Borrar |
| `test-env-deploy.yml` / `test-env-cleanup.yml` | PR (cualquier rama) | Corren en cada PR; infra AWS de Saleor | Borrar |
| `bump-dependencies.yml` | cron mensual + manual | Cron guardado por `saleor/saleor` → no; manual sí | Borrar |
| `e2e.yml` | cron (guardado), manual y **PR opened/synchronize** | La guarda solo cubre el cron: **corre en cada PR** | Borrar (prioridad: ruido/coste) |
| `tests-and-linters.yml` | PR (cualquier base) y push a `main` | **Corre en cada PR**; solapa con `ci-fork.yml` | Borrar si `ci-fork.yml` cubre linters+suite; confirmar |
| `check-licenses.yaml` | PR con cambios en lockfiles | Sí; llama a un workflow reusable de repo privado de Saleor | Borrar |
| `check-migration-tasks.yml` | PR (cualquier base) | Sí; chequea config de tareas de migración | Revisar: conservar si sirve |
| `graphql-inspector.yml` | PR que toca `*.graphql` | Sí | Revisar: útil para el contrato del schema |
| `test-semgrep-rules.yml` | push/PR que toca `.semgrep/**` | Casi nunca | Borrar o conservar (inocuo) |
| `changelog-check.yml` | PR a `main` | No (base `main`) | Borrar |
| `migrations-perf-test-check.yml` | PR a `main` | No | Borrar |
| `migrations-perf-test.yml` | PR con label, guardado por `saleor/saleor` | No | Borrar |
| `test-migrations-compatibility.yml` | PR a `3.*` o `main` | No (las bases son `stable/*`: el glob `3.*` no casa) | Borrar o re-apuntar a `stable/*` si se quiere esa prueba |
| `github-releases-to-discord.yml` | `release` | Solo si el fork publica releases; requiere webhook de Saleor | Borrar |
| `help-wanted-issues-to-discord.yml` | `issues` | Sí, en issues con label; requiere secreto ausente | Borrar |

Resumen: borrar 15 con seguridad razonable, decidir 4 (`tests-and-linters`, `check-migration-tasks`,
`graphql-inspector`, `test-semgrep-rules`). Pendiente de confirmar con historial de runs antes de borrar.

### B-378 — resolución (2026-10-06): 15 workflows heredados borrados

Andrés aprobó borrar los que el inventario de arriba marca «Borrar». Borrados del árbol (nunca
`gh workflow disable`): `publish-main.yml`, `publish-containers.yml`, `create-tag-with-release-pr.yml`,
`publish-load-test.yml`, `test-env-deploy.yml`, `test-env-cleanup.yml`, `bump-dependencies.yml`, `e2e.yml`,
`check-licenses.yaml`, `changelog-check.yml`, `migrations-perf-test-check.yml`, `migrations-perf-test.yml`,
`github-releases-to-discord.yml`, `help-wanted-issues-to-discord.yml`, `test-migrations-compatibility.yml`
(esta última era «Borrar o re-apuntar»: nunca disparaba, sus bases `3.*`/`main` no existen aquí).

**Se conservan** los 4 que el inventario deja «a decidir» (`tests-and-linters.yml`, `check-migration-tasks.yml`,
`graphql-inspector.yml`, `test-semgrep-rules.yml`) y los propios (`ci-fork.yml`, `security-scan.yml`,
`sync-upstream.yml`, más `smoke-imagen.yml`, B-911). `tests-and-linters.yml` sigue corriendo en cada PR y solapa con
`ci-fork.yml`: pendiente de la decisión de Andrés.

**Actualización 2026-10-06 (decisión de Andrés):** `tests-and-linters.yml` también se **borra**. `ci-fork.yml` cubre lo
mismo (puerta rápida, linters por pre-commit y suite completa) y es la CI que el fork mantiene; la de upstream solo
duplicaba minutos en cada PR. Las menciones en comentarios de `ci-fork.yml`, `sync-upstream.yml`,
`check-github-settings.sh` y en esta nota son historia (por qué existe `ci-fork.yml`) y se conservan. Quedan 3 «a
decidir»: `check-migration-tasks.yml`, `graphql-inspector.yml` y `test-semgrep-rules.yml`.

**Coste de sync cero, comprobado:** `sync-upstream.yml` hace `rm -rf .github/workflows` y
`git checkout "$BASE_SHA" -- .github/workflows/` tras el merge del tag, así que restaura el directorio desde el
árbol del fork (no desde upstream) y los borrados persisten (mismo mecanismo que `test-env-cleanup-cron.yml`).
Lo que sí hay que repetir a mano es el **re-fork a una minor nueva** (copia el árbol de upstream): volver a borrar
estos 15 (o partir de `stable/3.23`). Ningún workflow restante referencia uno borrado (`ci-fork.yml` solo llama al
nuevo `smoke-imagen.yml`).

### B-1412 — workflows registrados por refs heredados de upstream (2026-10-16)

`scripts/check-github-settings.sh` salía exit 1 por `workflows.cruce_api_vs_arbol`: `publish-release-tag.yml` figura
`active` en la API de `aclicona/licona-saleor` y no está en el árbol de `stable/3.23`. **Medido:** solo existe en la
rama `3.22` del fork y en los tags `3.22.*` de upstream que el sync replica (B-540); cada push de uno de esos tags lo
dispara (23 runs, todos `startup_failure`, 2026-10-13). Upstream lo borró en `05f9bea02a` («fix(build): delete unused
workflow (#18780)»), pero los tags son inmutables.

Es una **categoría nueva, «registrado por refs heredados»**: ni propio (vive en el árbol) ni borrado (GitHub lo sigue
registrando). Dictamen de arquitectura (Fable): constante `WORKFLOWS_HEREDADOS_OTROS_REFS` en el guion, formato
`ruta=ref`, ruta exacta. Solo exime la dirección API→árbol y solo esa ruta (sale como NOTA); `solo_arbol` no se toca.
Cada entrada se verifica con una llamada a `contents/<ruta>?ref=<ref>`: si el archivo no está en ese ref →
`workflows.heredados.declaracion_falsa`; si reaparece en el árbol o GitHub deja de registrarlo →
`workflows.heredados.entrada_obsoleta` (la lista muere con el hecho). Una ruta no puede estar a la vez en
`WORKFLOWS_PROPIOS` y aquí (exit 2). Test sin red: `saleor/tests/test_fork_github_settings_drift.py`.

**Qué NO es la solución:** `gh workflow disable` (prohibido por la regla: «Lo que no está en el árbol no existe para la
instancia N+1»; el estado `disabled` no se clona) ni borrar runs o la rama `3.22` (los tags `3.22.*` siguen disparándolo).
**La lista se vacía** cuando upstream deje de publicar parches 3.22 (o cuando se retire de la API); entonces la propia
entrada saltará como `entrada_obsoleta`.

## B-911 — smoke de la imagen Docker (2026-10-06)

`scripts/smoke-imagen.sh <imagen>` levanta un Postgres efímero y comprueba con la imagen real: el ENTRYPOINT no
migra; `wait-for-migrations.sh` sale 1 con la base vacía y 0 con la migrada; `migrate --noinput` sale 0 envuelto
por el ENTRYPOINT y con `--entrypoint`. Lo corre `.github/workflows/smoke-imagen.yml`: en PRs que tocan
`Dockerfile`/`scripts/**`/`railway.toml`/`pyproject.toml`/`uv.lock`, desde `ci-fork.yml` (job `imagen`) en el push
que crea la rama y en dispatch `alcance=completo`, y a mano. No corre en cada push (build ~5 min; Railway no
espera a la CI). Trivy (`security-scan.yml`) ya construía la imagen: se deja aparte a propósito.

**Bug hallado por el smoke y corregido en `check-migrations.sh`:** sobre una base NUEVA recién migrada daba
exit 3 («por delante del código») y `wait-for-migrations.sh` fallaba para siempre (worker/beat no arrancarían en
una réplica nueva), por (1) migraciones squasheadas `cart.*` registradas como aplicadas y (2) la línea
«N objects imported automatically» de `manage.py shell -c` contada como migración.

## B-1008 — la suite de CI se colgaba al 99 % (2026-10-07)

Síntoma: el job «Suite completa (17k tests)» de `ci-fork.yml` llegaba al 99 % en ~12 min con 0 fallos y se quedaba
colgado hasta el timeout (4 runs seguidos: 37616702066, 37626155687, 37642669252, 37651066346), sin resumen de
pytest. Postgres solo mostraba el `DROP DATABASE` del teardown: los tests terminaban, no salía el proceso xdist.
El último verde fue el 2026-09-30 sobre `70056796eb`; en local la suite sale limpia.

- **Causa raíz confirmada (run 37663329473, stacks de faulthandler):** no era el proceso al salir sino un test
  en curso, colgado al 99 %: `test_beat_scheduler_setting.py::test_tick_sends_due_entry_even_if_head_of_heap_is_not_due`
  (B-700, `fe9cb87cf4`). `BaseScheduler.tick` evalúa `self.producer` antes de llamar a `apply_entry`, y el test solo
  parcheaba `apply_entry`: `producer` abría una conexión real al broker de `app` y, sin broker alcanzable (CI),
  `kombu.ensure_connection` reintenta para siempre (`celery/beat.py:480` -> `kombu/connection.py:459`). Los 3 `-n`
  workers restantes esperaban en `execnet`. Fix: el test parchea también `producer`. En local lo escondía un
  broker alcanzable.
- **Sospechoso descartado como causa, endurecido igualmente:** `saleor/schedulers/tests/test_beat_dispatch_in_memory.py` (nuevo desde `95dc50b7`) creaba un
  `Celery(broker="memory://")` que nunca cerraba, y contaba mensajes en la cola `celery` por defecto, compartida por
  todo el proceso (el transporte `memory://` guarda su estado a nivel de clase): fallaba en local con `assert 83 == 1`.
  La fixture además quita `CELERY_BROKER_URL` del entorno (Celery lo prefiere al argumento `broker=`). Ahora la app es una fixture con `app.close()` en el teardown y la cola es única por test (`options.queue`). Sigue
  probando lo mismo: beat real, `apply_entry` real y broker en memoria, 1 mensaje publicado y `blocked` no.
- **Diagnóstico en CI** (por si no era la causa): `-rA` (resultado por test), `-o faulthandler_timeout=300` y, en
  `conftest.py`, un `pytest_sessionfinish` que con `B1008_EXIT_WATCHDOG=1` (solo lo pone `ci-fork.yml`) arma
  `faulthandler.dump_traceback_later(120, repeat=True)`: si el intérprete no sale tras la sesión, vuelca los stacks de
  todos los hilos cada 2 min (`faulthandler_timeout` solo cubre tests en curso, no la salida). `timeout-minutes` del job
  suite: 60 -> 30.
- **B-1016 (2026-10-17): `-rA` -> `-ra`.** Con la causa resuelta, `-rA` solo costaba: `summary_passes` tardaba >2 min
  en imprimir los ~17 900 PASSED, inflaba el log y una vez hizo saltar el watchdog de salida (falso cuelgue). `-ra`
  conserva el resumen de lo no-passed; `faulthandler_timeout=300`, el watchdog y `timeout-minutes: 30` siguen igual.
- Al re-forkear a una minor nueva: el `conftest.py` y el workflow se copian de upstream; reaplicar el hook si se quiere
  conservar el diagnóstico (es inocuo sin la variable).

## B-1246 — candado contra `on_commit(lambda)` con variable de bucle (2026-10-12)

El mismo bug de upstream (late binding) se arreglo cuatro veces en `saleor/warehouse/management.py`
(`3ba5f2bef4` B-1236, `2c2d39c7be` B-1238, `da06cea754` B-1243 x2): `transaction.on_commit(lambda: f(x))` con
`x` ligada por un `for` lee el valor al ejecutarse tras el commit, es decir el ultimo del bucle.

- **Por que no ruff B023:** esta en el `ignore` global (heredado de upstream) y, medido sobre `saleor/` con
  `ruff check saleor/ --select B023 --isolated` (ruff 0.12.12), hoy tiene 2 hallazgos ajenos
  (`saleor/graphql/plugins/dataloaders.py:36`, `saleor/plugins/avatax/plugin.py:237`), asi que activarlo obligaria a
  tocar codigo de upstream o a mantener excepciones.
- **Candado:** `saleor/core/tests/test_on_commit_late_binding.py` (test AST, sin base de datos, el recorrido es
  instantaneo; el tiempo de la corrida es el import del conftest). Falla listando `archivo:linea` si un
  `on_commit(lambda ...)` lee una variable ligada por un `for`/`async for`/comprehension envolvente (target o nombre
  asignado en el cuerpo del bucle). Excluye `migrations/` y tests. Un parametro por defecto (`lambda s=s: ...`) o
  `functools.partial` no se marcan.
- **Verificado:** verde sobre `da06cea754`; revertir cualquiera de los 4 `partial` a `lambda` lo pone en rojo.
- Solo cubre `on_commit`; otros callbacks diferidos (`apply_async` con lambda, etc.) no.

## B-1249 — late binding real en el dataloader de plugins y B023 activado (2026-10-12)

Seguimiento de B-1246: los 2 hallazgos de ruff B023 que impedian activarlo.

- **`saleor/graphql/plugins/dataloaders.py` (`PluginManagerByRequestorDataloader.batch_load`): bug real.**
  `lambda: user` dentro de la comprension se guardaba como `requestor_getter` y se evalua de forma perezosa al cargar
  plugins, asi que con un lote de >=2 requestors distintos todos los managers devolvian el ultimo. Arreglo:
  `lambda user=user: user`. Test: `saleor/graphql/plugins/tests/test_plugin_manager_by_requestor_dataloader.py`
  (sin cambio, rojo con `managers[0]` devolviendo el requestor B; con el arreglo, verde).
- **`saleor/plugins/avatax/plugin.py` (~L237): falso positivo.** El `SimpleLazyObject(lambda: ...(line))` se pasa como
  `base_value` y se consume dentro de la misma iteracion; solo se anota `# noqa: B023` con su motivo.
- **`pyproject.toml`:** `B023` sale del `ignore` global; `ruff check saleor/` queda en 0 con la regla activa.
- **En un rebase de upstream:** si `B023` reaparece en `ignore` o el `lambda: user` vuelve al dataloader (conflicto en
  `dataloaders.py`), reaplicar; `ruff check saleor/ --select B023` debe dar 0 y el test nuevo lo detecta. Los candados
  de B-1246 (`test_on_commit_late_binding.py`) siguen vigentes.
- Candidato a reportarse upstream (Saleor): el dataloader tiene el bug en `main`.

## B-1255 — test de benchmark del aviso de agotado esperaba el stock equivocado (2026-10-12)

El job «Suite completa» de `ci-fork.yml` estaba rojo desde `3ba5f2bef4` (B-1236) en
`saleor/graphql/checkout/tests/benchmark/test_checkout_mutations.py::test_complete_checkout_with_out_of_stock_webhook`
(`Expected: ...Stock object (554)` / `Actual: ...Stock object (552)`).

- **Diagnóstico: el código es correcto, el test codificaba el bug de upstream.** El pedido del test asigna 1, 10, 3 y 5
  unidades a cuatro stocks de 10; solo el de 10 queda en 0 y es el que ahora avisa. El `lambda` anterior leía `allocation`
  tras el commit y avisaba siempre de la última asignación del bucle, que coincidía con `Stock.objects.last()`.
- **Cambio (solo test):** el stock esperado se obtiene por datos (`allocated == quantity`, con `.get()` que falla si hubiera
  más de uno), sin ids ni `.last()`.
- **Verificado:** con el `lambda` original en `allocate_stocks` el test vuelve a fallar (esperado el agotado, recibido el último).
- **En un rebase de upstream:** si upstream no incorpora el `partial` de B-1236, este test fallará al revés; reaplicar ambos
  juntos (`saleor/warehouse/management.py` + este test). Tras tocar `allocate_stocks`, correr
  `saleor/graphql/checkout/tests/benchmark/`: los tests de `saleor/warehouse/tests/` no cubren este camino GraphQL.
