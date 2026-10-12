import dataclasses
import json
import math
from decimal import Decimal
from typing import Any, Literal, overload

import pytest
from django.conf import settings
from django.db import connections
from opentelemetry.sdk.metrics.export import DataPointT, Metric, MetricsData
from opentelemetry.sdk.trace import ReadableSpan

from ..core.db.connection import allow_writer
from ..core.editorjs.models import EditorJSDocumentModel
from ..core.telemetry import Scope


class FakeDbReplicaConnection:
    """A class used to create a fake replica DB connection for use in tests.

    This class serves as a wrapper around the writer DB connection (alias "default")
    that simulates a replica DB connection by identifying itself with a replica alias
    and overriding cursor creation methods. It effectively results in one DB connection
    identified by two separate aliases, but with shared transactions.
    """

    def __init__(self, replica_conn):
        self.replica_conn = replica_conn
        self.writer_conn = connections[settings.DATABASE_CONNECTION_DEFAULT_NAME]

    def cursor(self, *args, **kwargs):
        with allow_writer():
            # Cursor creation is wrapped in allow_writer as it is effectively created
            # using the writer DB connection
            cursor = self.writer_conn.cursor(*args, **kwargs)
            cursor.db = self
        return cursor

    def chunked_cursor(self, *args, **kwargs):
        with allow_writer():
            # Cursor creation is wrapped in allow_writer as it is effectively created
            # using the writer DB connection
            cursor = self.writer_conn.chunked_cursor(*args, **kwargs)
            cursor.db = self
        return cursor

    def __getattr__(self, attr):
        if attr == "alias":
            return getattr(self.replica_conn, attr)
        return getattr(self.writer_conn, attr)


def prepare_test_db_connections():
    """Override the replica DB connection with a fake one for testing purposes.

    This function allows simulation of replica DB usage in tests while using Django's
    TestCase, avoiding the need for the slower TransactionTestCase. For more details,
    refer to the Django documentation:
    https://docs.djangoproject.com/en/4.2/topics/testing/advanced/#testing-primary-replica-configurations
    """
    replica = settings.DATABASE_CONNECTION_REPLICA_NAME
    connections[replica] = FakeDbReplicaConnection(connections[replica])  # type: ignore[assignment]


@overload
def dummy_editorjs(text: str, json_format: Literal[True]) -> str: ...
@overload
def dummy_editorjs(
    text: str, json_format: Literal[False] = False
) -> dict[str, Any]: ...


def dummy_editorjs(text: str, json_format: bool = False) -> dict[str, Any] | str:
    data = EditorJSDocumentModel.model_validate(
        {"blocks": [{"data": {"text": text}, "type": "paragraph"}]}
    ).model_dump(exclude_unset=True)

    if json_format:
        return json.dumps(data, sort_keys=True)

    return data


def round_down(price: Decimal) -> Decimal:
    return Decimal(math.floor(price * 100)) / 100


def round_up(price: Decimal) -> Decimal:
    return Decimal(math.ceil(price * 100)) / 100


def get_metric_data(
    metrics_data: MetricsData, metric_name: str, *, scope=Scope.SERVICE
) -> Metric | None:
    __tracebackhide__ = True  # make failures point to the test, not here
    if len(metrics_data.resource_metrics) != 1:
        pytest.fail("Metrics recorded as multiple resources")
    for scope_metrics in metrics_data.resource_metrics[0].scope_metrics:
        if scope_metrics.scope.name == scope.value:
            for metric in scope_metrics.metrics:
                if metric.name == metric_name:
                    return metric
    return None


def get_metric_and_data_point(
    metrics_data: MetricsData, metric_name: str, *, scope=Scope.SERVICE
) -> tuple[Metric, DataPointT]:
    __tracebackhide__ = True  # make failures point to the test, not here
    metric_data = get_metric_data(metrics_data, metric_name, scope=scope)
    if metric_data is None:
        pytest.fail(f"Metric {metric_name} not found in metrics data")
    if len(metric_data.data.data_points) == 0:
        pytest.fail(f"No data points found for metric: {metric_name}")
    elif len(metric_data.data.data_points) > 1:
        pytest.fail(
            f"Multiple data points ({len(metric_data.data.data_points)}) found for metric: {metric_name}"
        )
    return metric_data, metric_data.data.data_points[0]


def get_metric_data_point(
    metrics_data: MetricsData, metric_name: str, *, scope=Scope.SERVICE
) -> DataPointT:
    __tracebackhide__ = True  # make failures point to the test, not here
    _, data_point = get_metric_and_data_point(metrics_data, metric_name, scope=scope)
    return data_point


def filter_spans_by_name(
    spans: tuple[ReadableSpan, ...], name
) -> tuple[ReadableSpan, ...]:
    return tuple(span for span in spans if span.name == name)


def get_span_by_name(spans: tuple[ReadableSpan, ...], name: str) -> ReadableSpan:
    __tracebackhide__ = True
    spans = filter_spans_by_name(spans, name)
    if not spans:
        pytest.fail(f"No span with name '{name}' found")
    if len(spans) > 1:
        pytest.fail(f"Multiple '{name}' spans")
    return spans[0]


class SameLineInfos:
    """Comparador para `mock.assert_called_with`: infos de línea iguales por contenido.

    B-1232: `LineInfo` y subclases comparan por identidad (`@dataclass(eq=False)`), así
    que un test que vuelve a hacer `fetch_checkout_lines()` y espera esas líneas en una
    llamada a un mock ya no puede usar `==` directo. Este comparador exige el mismo
    número de infos, la misma clase y la misma línea (pk) y el resto de campos iguales
    uno a uno, es decir, lo que comprobaba el `==` por contenido de antes.
    """

    def __init__(self, line_infos):
        self.line_infos = list(line_infos)

    def __eq__(self, other):
        if not isinstance(other, list | tuple) or len(other) != len(self.line_infos):
            return False
        return all(
            type(expected) is type(actual)
            and expected.line.pk == actual.line.pk
            and all(
                getattr(expected, field.name) == getattr(actual, field.name)
                for field in dataclasses.fields(expected)
            )
            for expected, actual in zip(self.line_infos, other, strict=True)
        )

    def __repr__(self):
        return f"SameLineInfos({self.line_infos!r})"


class SameCheckoutInfo:
    """Comparador para `mock.assert_called_with`: `CheckoutInfo` igual por contenido.

    B-1232: `CheckoutInfo.lines` es una lista de `CheckoutLineInfo`, que ya no comparan
    por contenido; sus campos se comparan uno a uno y `lines` con `SameLineInfos`.
    """

    def __init__(self, checkout_info):
        self.checkout_info = checkout_info

    def __eq__(self, other):
        expected = self.checkout_info
        if type(expected) is not type(other):
            return False
        for field in dataclasses.fields(expected):
            if not field.compare:
                continue
            want, got = getattr(expected, field.name), getattr(other, field.name)
            if field.name == "lines":
                want = SameLineInfos(want)
            if want != got:
                return False
        return True

    def __repr__(self):
        return f"SameCheckoutInfo({self.checkout_info!r})"
