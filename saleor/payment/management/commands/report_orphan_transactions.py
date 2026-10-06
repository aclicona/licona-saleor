from datetime import timedelta

from django.core.management.base import BaseCommand, CommandError
from django.db.models import Exists, OuterRef
from django.utils import timezone

from ... import TransactionEventType
from ...models import TransactionEvent, TransactionItem

SUCCESS_EVENT_TYPES = [
    TransactionEventType.AUTHORIZATION_SUCCESS,
    TransactionEventType.CHARGE_SUCCESS,
    TransactionEventType.REFUND_SUCCESS,
    TransactionEventType.CANCEL_SUCCESS,
]


def get_stale_transactions(days: int):
    """Return transactions with no order, no success event and older than `days`.

    These are the leftovers of failed payment attempts: `transactionInitialize`
    creates the TransactionItem before calling the payment app. Read-only query.
    """
    cutoff = timezone.now() - timedelta(days=days)
    has_success = TransactionEvent.objects.filter(
        transaction_id=OuterRef("pk"), type__in=SUCCESS_EVENT_TYPES
    )
    return TransactionItem.objects.filter(
        order_id__isnull=True, created_at__lt=cutoff
    ).exclude(Exists(has_success))


class Command(BaseCommand):
    help = (
        "READ-ONLY diagnostic: count (and optionally list) TransactionItems that "
        "have no order, no success event and are older than --days. "
        "It never deletes or modifies anything."
    )

    def add_arguments(self, parser):
        parser.add_argument("--days", type=int, default=7)
        parser.add_argument(
            "--list",
            type=int,
            default=0,
            metavar="N",
            help="Also print the N oldest matching transactions.",
        )

    def handle(self, *args, **options):
        days = options["days"]
        if days < 0:
            raise CommandError("--days must be >= 0")
        qs = get_stale_transactions(days)
        self.stdout.write(f"Stale TransactionItems (>{days} days): {qs.count()}")
        no_checkout = qs.filter(checkout_id__isnull=True).count()
        self.stdout.write(f"  of which without checkout: {no_checkout}")
        limit = options["list"]
        if limit > 0:
            for pk, token, created_at, psp in qs.order_by("created_at").values_list(
                "pk", "token", "created_at", "psp_reference"
            )[:limit]:
                self.stdout.write(f"  {pk}\t{token}\t{created_at.isoformat()}\t{psp}")
