"""Regresión B-2471: `customer_ip_address` sale de la derecha del X-Forwarded-For."""

from decimal import Decimal
from unittest import mock

from .....payment import TransactionEventType
from .....payment.interface import TransactionSessionResult
from ....core.utils import to_global_id_or_none
from ....tests.utils import get_graphql_content
from .test_transaction_initialize import TRANSACTION_INITIALIZE


@mock.patch("saleor.plugins.manager.PluginsManager.transaction_initialize_session")
def test_customer_ip_address_is_the_trusted_rightmost_forwarded_for(
    mocked_initialize,
    app_api_client,
    order_with_lines,
    webhook_app,
    transaction_session_response,
    permission_manage_payments,
):
    # given
    order = order_with_lines
    webhook_app.identifier = "webhook.app.identifier"
    webhook_app.save()
    expected_response = transaction_session_response.copy()
    expected_response["result"] = TransactionEventType.CHARGE_REQUEST.upper()
    expected_response["pspReference"] = "ppp-123"
    mocked_initialize.return_value = TransactionSessionResult(
        app_identifier=webhook_app.identifier, response=expected_response
    )
    app_api_client.app.permissions.set([permission_manage_payments])
    variables = {
        "action": None,
        "amount": Decimal("10.00"),
        "id": to_global_id_or_none(order),
        "paymentGateway": {"id": webhook_app.identifier, "data": None},
    }

    # when: el cliente inventa la IP de la izquierda; el proxy añade la real
    response = app_api_client.post_graphql(
        TRANSACTION_INITIALIZE,
        variables,
        HTTP_X_FORWARDED_FOR="203.0.113.9, 198.51.100.7",
    )

    # then
    get_graphql_content(response)
    session_data = mocked_initialize.call_args.args[0]
    assert session_data.customer_ip_address == "198.51.100.7"
