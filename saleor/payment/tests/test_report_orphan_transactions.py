from datetime import timedelta
from io import StringIO

import pytest
from django.core.management import call_command
from django.utils import timezone

from .. import TransactionEventType
from ..management.commands.report_orphan_transactions import get_stale_transactions
from ..models import TransactionEvent, TransactionItem


def _transaction(days_old, **kwargs):
    t = TransactionItem.objects.create(currency="USD", **kwargs)
    TransactionItem.objects.filter(pk=t.pk).update(
        created_at=timezone.now() - timedelta(days=days_old)
    )
    return t


@pytest.mark.django_db
def test_get_stale_transactions_filters_by_age_order_and_success(order):
    old = _transaction(10)
    _transaction(1)
    _transaction(10, order=order)
    paid = _transaction(10)
    TransactionEvent.objects.create(
        transaction=paid, currency="USD", type=TransactionEventType.CHARGE_SUCCESS
    )
    failed = _transaction(10)
    TransactionEvent.objects.create(
        transaction=failed, currency="USD", type=TransactionEventType.CHARGE_FAILURE
    )

    assert set(get_stale_transactions(7)) == {old, failed}


@pytest.mark.django_db
def test_command_is_read_only_and_reports_count():
    _transaction(10)
    _transaction(20)
    out = StringIO()

    call_command("report_orphan_transactions", "--days=7", "--list=1", stdout=out)

    assert "Stale TransactionItems (>7 days): 2" in out.getvalue()
    assert TransactionItem.objects.count() == 2
