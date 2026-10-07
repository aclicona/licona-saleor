import datetime
import uuid

import celery.schedules
import pytest
from celery import Celery
from celery.schedules import schedule as interval_schedule

from ..schedulers import PersistentScheduler


class NeverDueSchedule:
    """Mimics ``promotion_webhook_schedule`` when nothing is pending."""

    def is_due(self, last_run_at):
        return celery.schedules.schedstate(False, 60.0)

    def remaining_estimate(self, last_run_at):
        return datetime.timedelta(seconds=60)

    def now(self):
        return datetime.datetime.now(datetime.UTC)

    def maybe_make_aware(self, dt):
        return dt


def _count_messages(app, queue):
    # `queue_declare` reports the depth without consuming; unlike `SimpleQueue.get`
    # it never blocks, so a silent beat fails the assertion instead of hanging.
    with app.connection_for_read() as conn:
        return conn.default_channel.queue_declare(queue).message_count


@pytest.fixture
def queue_name():
    # B-1008: the `memory://` transport keeps its state at class level, shared by every
    # app in the process. A queue name unique per test keeps the count independent of
    # whatever other tests (or other runs of this one) left in the default queue.
    return f"beat-canary-{uuid.uuid4().hex}"


@pytest.fixture
def beat_app(tmp_path):
    app = Celery("beat_canary", broker="memory://", set_as_current=False)
    app.conf.beat_schedule_filename = str(tmp_path / "beat-schedule")
    yield app
    # B-1008: release pool, connections and the app itself so nothing outlives the test
    # (a leftover non-daemon thread or open resource can keep an xdist worker from exiting).
    app.close()


def test_beat_really_publishes_due_tasks_to_the_broker(tmp_path, beat_app, queue_name):
    # B-744: end-to-end counterpart of the B-700 unit test. Real scheduler, real
    # `apply_entry` and a real (in-memory) broker: a silent beat shows up here as
    # zero messages, instead of only as a mock that was never called. It is a canary for
    # "beat dispatches at all" (wrong scheduler path, broken apply_entry/broker wiring),
    # not a reproducer of the B-700 heap starvation (that one is the unit test next door).
    # given
    app = beat_app
    now = datetime.datetime.now(datetime.UTC)
    app.conf.beat_schedule = {
        "blocked": {
            "task": "t.blocked",
            "schedule": NeverDueSchedule(),
            "options": {"queue": queue_name},
        },
        "due": {
            "task": "t.due",
            "schedule": interval_schedule(30),
            "options": {"queue": queue_name},
        },
    }
    scheduler = PersistentScheduler(app=app, schedule_filename=str(tmp_path / "s"))
    try:
        # `due` ran 45s ago, so it is due now; `blocked` sits at the head of the heap.
        scheduler.schedule["due"].last_run_at = now - datetime.timedelta(seconds=45)
        scheduler.schedule["blocked"].last_run_at = now - datetime.timedelta(
            seconds=120
        )
        scheduler._heap = None  # force heap rebuild with the adjusted entries

        # when
        scheduler.tick()
    finally:
        scheduler.close()

    # then
    assert _count_messages(app, queue_name) == 1
