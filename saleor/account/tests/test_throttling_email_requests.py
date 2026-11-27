"""B-2607: caps on `accountRegister` and `requestPasswordReset`."""

import datetime
import os
import subprocess
import sys
from unittest.mock import patch

import pytest
from django.core.cache import cache
from django.core.exceptions import ImproperlyConfigured, ValidationError
from django.utils import timezone
from freezegun import freeze_time

from ... import settings as saleor_settings
from ..error_codes import AccountErrorCode
from ..models import User
from ..tasks import trigger_send_password_reset_notification
from ..throttling_email_requests import (
    check_account_register_throttling,
    check_password_reset_throttling,
    is_password_reset_global_limit_exceeded,
)

NOW = "2026-11-27 12:00:00"
IP = "123.123.123.123"
OTHER_IP = "124.124.124.124"
REDIRECT_URL = "https://www.example.com"
WINDOW = 600
CONTEXT_DATA = {"user_pk": None, "app_pk": None}

NETWORK_CHECKS = [
    (check_account_register_throttling, "ACCOUNT_REGISTER_NETWORK_LIMIT"),
    (check_password_reset_throttling, "PASSWORD_RESET_NETWORK_LIMIT"),
]


@pytest.fixture
def locmem_cache(settings):
    # In-process cache: its expiry follows `freeze_time`, a Redis server's would not.
    settings.CACHES = {
        "default": {"BACKEND": "django.core.cache.backends.locmem.LocMemCache"}
    }


@pytest.fixture
def throttling_cache(locmem_cache, cache_clear, settings):
    settings.ACCOUNT_EMAIL_THROTTLE_WINDOW = WINDOW
    return cache


def _request(rf, forwarded_for):
    return rf.request(HTTP_X_FORWARDED_FOR=forwarded_for)


def _assert_delayed(check, request):
    with pytest.raises(ValidationError) as e:
        check(request)
    assert e.value.code == AccountErrorCode.LOGIN_ATTEMPT_DELAYED.value
    return e.value


def _send_reset(user_pk):
    trigger_send_password_reset_notification(
        REDIRECT_URL, user_pk, {**CONTEXT_DATA}, None
    )


@pytest.mark.parametrize(("check", "limit_setting"), NETWORK_CHECKS)
def test_network_limit_and_window_expiry(
    check, limit_setting, rf, settings, throttling_cache
):
    setattr(settings, limit_setting, 2)
    request = _request(rf, IP)

    with freeze_time(NOW) as frozen_time:
        check(request)
        frozen_time.tick(datetime.timedelta(seconds=WINDOW - 1))
        check(request)
        _assert_delayed(check, request)

        # fixed window: rejected calls do not extend it
        frozen_time.tick(datetime.timedelta(seconds=2))
        check(request)


@pytest.mark.parametrize(("check", "limit_setting"), NETWORK_CHECKS)
@pytest.mark.parametrize(
    ("first", "same_network", "other_network"),
    [
        ("2001:db8:1:2::1", "2001:db8:1:2:ffff::9", "2001:db8:1:3::1"),
        (IP, f"::ffff:{IP}", OTHER_IP),
    ],
)
def test_counted_by_network(
    check,
    limit_setting,
    first,
    same_network,
    other_network,
    rf,
    settings,
    throttling_cache,
):
    setattr(settings, limit_setting, 1)
    check(_request(rf, first))

    _assert_delayed(check, _request(rf, same_network))
    check(_request(rf, other_network))


@pytest.mark.parametrize(("check", "limit_setting"), NETWORK_CHECKS)
def test_rotating_left_forwarded_for_gives_no_new_quota(
    check, limit_setting, rf, settings, throttling_cache
):
    setattr(settings, limit_setting, 1)
    check(_request(rf, f"1.1.1.1, {IP}"))

    _assert_delayed(check, _request(rf, f"2.2.2.2, {IP}"))


@pytest.mark.parametrize(("check", "limit_setting"), NETWORK_CHECKS)
def test_unknown_ip_is_rejected(check, limit_setting, rf, settings, throttling_cache):
    setattr(settings, limit_setting, 1)
    request = rf.request()
    request.META.pop("REMOTE_ADDR", None)

    with pytest.raises(ValidationError) as e:
        check(request)

    assert e.value.code == AccountErrorCode.UNKNOWN_IP_ADDRESS.value


def test_register_global_limit_across_networks_has_the_same_error(
    rf, settings, throttling_cache
):
    settings.ACCOUNT_REGISTER_NETWORK_LIMIT = 1
    settings.ACCOUNT_REGISTER_GLOBAL_LIMIT = 1
    check_account_register_throttling(_request(rf, IP))

    network_error = _assert_delayed(check_account_register_throttling, _request(rf, IP))
    global_error = _assert_delayed(
        check_account_register_throttling, _request(rf, OTHER_IP)
    )

    assert global_error.message == network_error.message


def test_network_rejection_does_not_consume_global(rf, settings, throttling_cache):
    settings.ACCOUNT_REGISTER_NETWORK_LIMIT = 1
    settings.ACCOUNT_REGISTER_GLOBAL_LIMIT = 10
    check_account_register_throttling(_request(rf, IP))

    for _ in range(3):
        _assert_delayed(check_account_register_throttling, _request(rf, IP))

    assert throttling_cache.get("account_register:count:global") == 1


@patch("saleor.account.throttling_email_requests.cache")
def test_zero_limits_disable_the_throttling(mocked_cache, rf, settings):
    settings.ACCOUNT_REGISTER_NETWORK_LIMIT = 0
    settings.ACCOUNT_REGISTER_GLOBAL_LIMIT = 0
    settings.PASSWORD_RESET_NETWORK_LIMIT = 0
    settings.PASSWORD_RESET_GLOBAL_LIMIT = 0
    request = rf.request()
    request.META.pop("REMOTE_ADDR", None)

    check_account_register_throttling(request)
    check_password_reset_throttling(request)
    assert is_password_reset_global_limit_exceeded() is False

    assert not mocked_cache.mock_calls


def test_zero_network_limit_keeps_the_global_one(rf, settings, throttling_cache):
    settings.ACCOUNT_REGISTER_NETWORK_LIMIT = 0
    settings.ACCOUNT_REGISTER_GLOBAL_LIMIT = 1
    check_account_register_throttling(_request(rf, IP))

    _assert_delayed(check_account_register_throttling, _request(rf, OTHER_IP))


def test_keys_do_not_mix_with_login_ones(rf, settings, throttling_cache):
    settings.ACCOUNT_REGISTER_NETWORK_LIMIT = 5
    settings.ACCOUNT_REGISTER_GLOBAL_LIMIT = 5
    settings.PASSWORD_RESET_NETWORK_LIMIT = 5
    settings.PASSWORD_RESET_GLOBAL_LIMIT = 5

    check_account_register_throttling(_request(rf, IP))
    check_password_reset_throttling(_request(rf, IP))
    is_password_reset_global_limit_exceeded()

    for key in [
        f"account_register:count:net:{IP}",
        "account_register:count:global",
        f"password_reset:count:net:{IP}",
        "password_reset:count:global",
    ]:
        assert throttling_cache.get(key) == 1
    assert not [key for key in throttling_cache._cache if "login:" in key]


@patch("saleor.account.throttling_email_requests.cache")
def test_counter_expiring_between_add_and_incr_is_retried_once(
    mocked_cache, rf, settings
):
    settings.PASSWORD_RESET_NETWORK_LIMIT = 1
    mocked_cache.incr.side_effect = [ValueError, 1]

    check_password_reset_throttling(_request(rf, IP))

    assert mocked_cache.add.call_count == 2


def test_counter_recreated_without_expiry_still_expires(rf, settings, throttling_cache):
    # Django's Redis `incr` is not atomic: a key expiring inside it is recreated
    # without expiry, and 1 is returned.
    settings.PASSWORD_RESET_NETWORK_LIMIT = 1
    request = _request(rf, IP)

    def recreate_without_expiry(key):
        throttling_cache.set(key, 1, timeout=None)
        return 1

    with freeze_time(NOW) as frozen_time:
        with patch.object(
            throttling_cache, "incr", side_effect=recreate_without_expiry
        ):
            check_password_reset_throttling(request)
        _assert_delayed(check_password_reset_throttling, request)

        frozen_time.tick(datetime.timedelta(seconds=WINDOW + 1))
        check_password_reset_throttling(request)


@patch("saleor.account.throttling_email_requests.cache")
def test_window_is_not_extended_after_the_first_call(mocked_cache, rf, settings):
    settings.PASSWORD_RESET_NETWORK_LIMIT = 5
    mocked_cache.incr.return_value = 2

    check_password_reset_throttling(_request(rf, IP))

    assert not mocked_cache.touch.called


@pytest.mark.parametrize("value", ["0", "0 minutes", "1.5 seconds", "soon", ""])
def test_invalid_throttle_window_is_rejected(value, monkeypatch):
    monkeypatch.setenv("ACCOUNT_EMAIL_THROTTLE_WINDOW", value)

    with pytest.raises(ImproperlyConfigured, match="ACCOUNT_EMAIL_THROTTLE_WINDOW"):
        saleor_settings.get_throttle_window_from_env(
            "ACCOUNT_EMAIL_THROTTLE_WINDOW", "10 minutes"
        )


def test_throttle_window_is_read_in_seconds(monkeypatch):
    monkeypatch.setenv("ACCOUNT_EMAIL_THROTTLE_WINDOW", "2 minutes")

    window = saleor_settings.get_throttle_window_from_env(
        "ACCOUNT_EMAIL_THROTTLE_WINDOW", "10 minutes"
    )

    assert window == 120


LIMIT_SETTINGS = [
    "ACCOUNT_REGISTER_NETWORK_LIMIT",
    "ACCOUNT_REGISTER_GLOBAL_LIMIT",
    "PASSWORD_RESET_NETWORK_LIMIT",
    "PASSWORD_RESET_GLOBAL_LIMIT",
]


@pytest.mark.parametrize("name", LIMIT_SETTINGS)
def test_negative_throttle_limit_is_rejected(name, monkeypatch):
    monkeypatch.setenv(name, "-1")

    with pytest.raises(ImproperlyConfigured, match=name):
        saleor_settings.get_throttle_limit_from_env(name, 10)


@pytest.mark.parametrize("value", [0, 7])
def test_throttle_limit_accepts_zero_and_positive(value, monkeypatch):
    monkeypatch.setenv("PASSWORD_RESET_NETWORK_LIMIT", str(value))

    limit = saleor_settings.get_throttle_limit_from_env(
        "PASSWORD_RESET_NETWORK_LIMIT", 10
    )

    assert limit == value


@pytest.mark.parametrize("name", LIMIT_SETTINGS)
def test_settings_fail_to_load_with_a_negative_limit(name):
    result = subprocess.run(
        [sys.executable, "-c", "import saleor.settings"],
        env={**os.environ, name: "-1"},
        capture_output=True,
        text=True,
        check=False,
        timeout=120,
    )

    assert result.returncode != 0
    assert f"ImproperlyConfigured: {name}" in result.stderr


@pytest.mark.parametrize(("check", "limit_setting"), NETWORK_CHECKS)
@patch("saleor.account.throttling_email_requests.cache")
def test_cache_failure_propagates(mocked_cache, check, limit_setting, rf, settings, db):
    setattr(settings, limit_setting, 1)
    mocked_cache.add.side_effect = ConnectionError

    with pytest.raises(ConnectionError):
        check(_request(rf, IP))


@freeze_time(NOW)
@patch("saleor.plugins.manager.PluginsManager.notify")
def test_reset_task_run_twice_sends_one_email(mocked_notify, customer_user):
    def assert_marker_already_set(*args, **kwargs):
        marker = User.objects.get(pk=customer_user.pk).last_password_reset_request
        assert marker == timezone.now()

    mocked_notify.side_effect = assert_marker_already_set

    _send_reset(customer_user.pk)
    _send_reset(customer_user.pk)

    assert mocked_notify.call_count == 1


@patch("saleor.plugins.manager.PluginsManager.notify")
def test_reset_task_sends_again_after_lock_time(mocked_notify, customer_user, settings):
    with freeze_time(NOW) as frozen_time:
        _send_reset(customer_user.pk)
        frozen_time.tick(
            datetime.timedelta(seconds=settings.RESET_PASSWORD_LOCK_TIME - 1)
        )
        _send_reset(customer_user.pk)
        assert mocked_notify.call_count == 1

        frozen_time.tick(datetime.timedelta(seconds=1))
        _send_reset(customer_user.pk)

    assert mocked_notify.call_count == 2


@patch("saleor.account.tasks.logger.error")
@patch("saleor.plugins.manager.PluginsManager.notify")
def test_reset_task_over_global_limit_does_not_send(
    mocked_notify,
    mocked_logger_error,
    customer_user,
    customer_user2,
    settings,
    throttling_cache,
):
    settings.PASSWORD_RESET_GLOBAL_LIMIT = 1
    _send_reset(customer_user.pk)

    _send_reset(customer_user2.pk)

    assert mocked_notify.call_count == 1
    mocked_logger_error.assert_called_once()
    logged = str(mocked_logger_error.call_args)
    assert customer_user2.email not in logged


@patch("saleor.plugins.manager.PluginsManager.notify")
def test_reset_task_without_real_send_does_not_consume_global(
    mocked_notify, customer_user, settings, throttling_cache
):
    settings.PASSWORD_RESET_GLOBAL_LIMIT = 10
    _send_reset(None)
    _send_reset(customer_user.pk)
    # locked: nothing is sent
    _send_reset(customer_user.pk)

    assert throttling_cache.get("password_reset:count:global") == 1
    assert mocked_notify.call_count == 1
