import datetime
from unittest import mock

import celery.beat
from celery.schedules import schedule as interval_schedule
from django.conf import settings

from ...celeryconf import app
from ..schedulers import BaseScheduler, PersistentScheduler

SALEOR_SCHEDULER = "saleor.schedulers.schedulers.PersistentScheduler"


def test_beat_scheduler_defaults_to_saleor_scheduler():
    # B-700: with Celery's stock scheduler, a conditional schedule at the head of
    # the heap (is_due=False) blocks every other periodic task.
    assert settings.CELERY_BEAT_SCHEDULER == SALEOR_SCHEDULER
    assert app.conf.beat_scheduler == SALEOR_SCHEDULER
    assert issubclass(PersistentScheduler, BaseScheduler)


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


class _Scheduler(BaseScheduler):
    old_schedulers = None


def test_tick_sends_due_entry_even_if_head_of_heap_is_not_due():
    # given
    now = datetime.datetime.now(datetime.UTC)
    blocked = celery.beat.ScheduleEntry(
        name="blocked",
        task="t.blocked",
        schedule=NeverDueSchedule(),
        last_run_at=now - datetime.timedelta(seconds=120),
        app=app,
    )
    due = celery.beat.ScheduleEntry(
        name="due",
        task="t.due",
        schedule=interval_schedule(30),
        last_run_at=now - datetime.timedelta(seconds=45),
        app=app,
    )
    scheduler = _Scheduler(app=app, lazy=True)
    scheduler.data = {"blocked": blocked, "due": due}

    # when
    # B-1008: `tick` evaluates `self.producer` *before* calling `apply_entry`. Unpatched,
    # that opens a real connection to the broker configured for `app`; with no reachable
    # broker (CI) kombu retries forever and the suite hung at 99 %.
    with (
        mock.patch.object(_Scheduler, "producer", new=mock.Mock()),
        mock.patch.object(_Scheduler, "apply_entry") as apply_entry,
    ):
        scheduler.tick()

    # then
    sent = [call.args[0].name for call in apply_entry.call_args_list]
    assert sent == ["due"]
