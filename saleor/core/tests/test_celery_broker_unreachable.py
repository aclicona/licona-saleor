import time

import celery.beat
import pytest
from kombu.exceptions import OperationalError

from ...celeryconf import app

# B-1015: a test that reaches the real Celery broker must fail fast. Without a broker
# (CI) kombu retries the connection practically forever, which is how the suite hung
# for 60 minutes at 99 % (B-1008).
MAX_SECONDS_TO_FAIL = 10


def _assert_fails_fast(action):
    start = time.monotonic()
    with pytest.raises((OperationalError, OSError)):
        action()
    assert time.monotonic() - start < MAX_SECONDS_TO_FAIL


def test_beat_producer_fails_fast_without_broker():
    # `Scheduler.producer` (what `tick()` evaluates) calls `ensure_connection` with
    # `broker_connection_max_retries`: the default of 100 retries is ~45 min.
    scheduler = celery.beat.Scheduler(app=app, lazy=True)

    _assert_fails_fast(lambda: scheduler.producer)


def test_real_producer_fails_fast_without_broker():
    def use_producer():
        with app.producer_or_acquire() as producer:
            producer.publish({"x": 1}, routing_key="b-1015-unreachable")

    _assert_fails_fast(use_producer)


def test_delay_without_eager_fails_fast_without_broker(settings):
    # given
    settings.CELERY_TASK_ALWAYS_EAGER = False
    app.conf.task_always_eager = False

    @app.task(name="saleor.core.tests.b_1015_noop")
    def noop():
        return None

    # when / then
    try:
        _assert_fails_fast(noop.delay)
    finally:
        app.conf.task_always_eager = True
