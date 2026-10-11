"""B-1223: las pruebas de pertenencia sobre líneas se hacen por identidad (pk).

`CheckoutLine.__eq__` compara variante y cantidad, no identidad. Dos líneas del mismo
checkout con la misma variante y cantidad (p. ej. con `forceNewLine`) son "iguales", así
que `in` / `list.remove` sobre ellas confunden una línea con la otra.
"""

from decimal import Decimal

from ...discount import DiscountValueType, VoucherType
from ...graphql.checkout.mutations.utils import CheckoutLineData
from ..fetch import fetch_checkout_lines
from ..models import CheckoutLine
from ..utils import add_variants_to_checkout


def _duplicate_line(line, **kwargs):
    return CheckoutLine.objects.create(
        checkout=line.checkout,
        variant=line.variant,
        quantity=line.quantity,
        currency=line.currency,
        **kwargs,
    )


def test_add_variants_to_checkout_custom_price_not_skipped_by_equal_deleted_line(
    checkout_with_single_item, channel_USD
):
    # given: dos líneas distintas, misma variante y cantidad
    checkout = checkout_with_single_item
    line_a = checkout.lines.get()
    line_b = _duplicate_line(line_a)
    assert line_a == line_b
    assert line_a.pk != line_b.pk

    # when: se borra la línea A y se fija un precio personalizado en la línea B
    add_variants_to_checkout(
        checkout,
        [line_a.variant],
        [
            CheckoutLineData(
                line_id=str(line_a.pk), quantity=0, quantity_to_update=True
            ),
            CheckoutLineData(
                line_id=str(line_b.pk),
                custom_price=Decimal("3.00"),
                custom_price_to_update=True,
            ),
        ],
        channel_USD,
        calculate_stocks_with_shipping_zones=True,
    )

    # then: A se borró y B recibió el precio (antes se omitía porque B == A)
    assert not CheckoutLine.objects.filter(pk=line_a.pk).exists()
    line_b.refresh_from_db()
    assert line_b.price_override == Decimal("3.00")


def test_add_variants_to_checkout_price_reason_saved_for_equal_line(
    checkout_with_single_item, channel_USD
):
    # given: A con precio personalizado ya puesto en esta petición, B igual a A
    checkout = checkout_with_single_item
    line_a = checkout.lines.get()
    line_b = _duplicate_line(line_a)

    # when
    add_variants_to_checkout(
        checkout,
        [line_a.variant],
        [
            CheckoutLineData(
                line_id=str(line_a.pk),
                custom_price=Decimal("2.00"),
                custom_price_to_update=True,
            ),
            CheckoutLineData(
                line_id=str(line_b.pk),
                custom_price_reason="motivo",
                custom_price_reason_to_update=True,
            ),
        ],
        channel_USD,
        calculate_stocks_with_shipping_zones=True,
    )

    # then: el motivo de B se guarda (antes `line not in to_update` lo omitía)
    line_b.refresh_from_db()
    assert line_b.price_override_reason == "motivo"


def test_apply_once_per_order_voucher_attached_to_a_single_equal_line(
    checkout_with_single_item, voucher, channel_USD
):
    # given: dos líneas con la misma variante y cantidad; la segunda es más barata
    checkout = checkout_with_single_item
    line_a = checkout.lines.get()
    variant_price = line_a.variant.channel_listings.get(channel=channel_USD).price
    line_b = _duplicate_line(
        line_a, price_override=variant_price.amount - Decimal("1.00")
    )
    assert line_a == line_b

    voucher.products.add(line_a.variant.product)
    voucher.type = VoucherType.SPECIFIC_PRODUCT
    voucher.apply_once_per_order = True
    voucher.discount_value_type = DiscountValueType.PERCENTAGE
    voucher.save()
    checkout.voucher_code = voucher.code

    # when
    lines_info, _ = fetch_checkout_lines(checkout)

    # then: el descuento "una vez por pedido" cae solo sobre la línea más barata
    with_voucher = [info.line.pk for info in lines_info if info.voucher]
    assert with_voucher == [line_b.pk]


def test_remove_line_infos_by_identity_keeps_equal_line_info(
    checkout_with_single_item,
):
    # given: dos líneas distintas "iguales" (misma variante y cantidad)
    from ...discount.utils.promotion import _remove_line_infos_by_identity

    checkout = checkout_with_single_item
    line_a = checkout.lines.get()
    line_b = _duplicate_line(line_a)
    lines_info, _ = fetch_checkout_lines(checkout)
    assert len(lines_info) == 2
    info_a = next(info for info in lines_info if info.line.pk == line_a.pk)
    info_b = next(info for info in lines_info if info.line.pk == line_b.pk)
    assert info_a == info_b

    # when
    _remove_line_infos_by_identity(lines_info, [info_b])

    # then: se quita B, no la primera línea "igual"
    assert [info.line.pk for info in lines_info] == [line_a.pk]
