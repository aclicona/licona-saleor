"""B-2606: throttling of the current password check of `passwordChange`."""

import datetime
from unittest.mock import patch

import pytest
from django.core.cache import cache
from django.core.exceptions import ValidationError
from django.utils import timezone
from freezegun import freeze_time

from ..error_codes import AccountErrorCode
from ..models import User
from ..throttling import (
    MAX_DELAY,
    MIN_DELAY,
    authenticate_with_throttling,
    get_cache_key_blocked_ip,
)
from ..throttling_password_change import (
    check_old_password_with_throttling,
    get_cache_key_blocked_password_change,
    get_cache_key_failed_password_change,
)

CORRECT_PASSWORD = "password"
INCORRECT_PASSWORD = "incorrect-password"
NOW = "2026-11-27 12:00:00"
IP = "123.123.123.123"


@pytest.fixture
def locmem_cache(settings):
    # In-process cache: its expiry follows `freeze_time`, a Redis server's would not.
    settings.CACHES = {
        "default": {"BACKEND": "django.core.cache.backends.locmem.LocMemCache"}
    }


@pytest.fixture
def throttling_cache(locmem_cache, cache_clear):
    return cache


def _tick(frozen_time, seconds):
    frozen_time.tick(datetime.timedelta(seconds=seconds + 1))


def test_cache_keys_depend_only_on_user():
    assert get_cache_key_failed_password_change(7) == "password_change:fail:user:7"
    assert get_cache_key_blocked_password_change(7) == "password_change:block:user:7"


@freeze_time(NOW)
def test_immediate_attempt_after_failure_is_delayed(customer_user, throttling_cache):
    # given
    assert not check_old_password_with_throttling(customer_user, INCORRECT_PASSWORD)
    next_attempt = timezone.now() + datetime.timedelta(seconds=MIN_DELAY)

    # when
    with pytest.raises(ValidationError) as e:
        check_old_password_with_throttling(customer_user, CORRECT_PASSWORD)

    # then
    assert e.value.code == AccountErrorCode.LOGIN_ATTEMPT_DELAYED.value
    assert str(next_attempt) in e.value.message


def test_delay_grows_up_to_max_delay(customer_user, throttling_cache):
    block_key = get_cache_key_blocked_password_change(customer_user.pk)
    expected_delays = [1, 2, 4, 8, 16, 32, 64, 128, 256, MAX_DELAY, MAX_DELAY]

    with freeze_time(NOW) as frozen_time:
        for delay in expected_delays:
            assert not check_old_password_with_throttling(
                customer_user, INCORRECT_PASSWORD
            )
            assert throttling_cache.get(block_key) == timezone.now() + (
                datetime.timedelta(seconds=delay)
            )
            _tick(frozen_time, delay)


def test_counter_outlives_first_failure_while_attempts_continue(
    customer_user, throttling_cache
):
    fail_key = get_cache_key_failed_password_change(customer_user.pk)

    with freeze_time(NOW) as frozen_time:
        # given: failures at 0 h and 1.5 h
        check_old_password_with_throttling(customer_user, INCORRECT_PASSWORD)
        _tick(frozen_time, 5400)
        check_old_password_with_throttling(customer_user, INCORRECT_PASSWORD)

        # when: a third one 3 h after the first
        _tick(frozen_time, 5400)
        check_old_password_with_throttling(customer_user, INCORRECT_PASSWORD)

        # then
        assert throttling_cache.get(fail_key) == 3


def test_correct_password_clears_counter_and_block(customer_user, throttling_cache):
    fail_key = get_cache_key_failed_password_change(customer_user.pk)
    block_key = get_cache_key_blocked_password_change(customer_user.pk)

    with freeze_time(NOW) as frozen_time:
        check_old_password_with_throttling(customer_user, INCORRECT_PASSWORD)
        _tick(frozen_time, MIN_DELAY)

        assert check_old_password_with_throttling(customer_user, CORRECT_PASSWORD)

        assert throttling_cache.get(fail_key) is None
        assert throttling_cache.get(block_key) is None


@freeze_time(NOW)
def test_block_of_one_user_does_not_affect_another(
    customer_user, customer_user2, throttling_cache
):
    check_old_password_with_throttling(customer_user, INCORRECT_PASSWORD)

    assert check_old_password_with_throttling(customer_user2, CORRECT_PASSWORD)
    assert throttling_cache.get(get_cache_key_blocked_password_change(customer_user.pk))


@freeze_time(NOW)
def test_password_change_failures_do_not_affect_login(
    rf, customer_user, throttling_cache
):
    check_old_password_with_throttling(customer_user, INCORRECT_PASSWORD)

    assert not [key for key in throttling_cache._cache if "login:" in key]
    request = rf.request(HTTP_X_FORWARDED_FOR=IP)
    assert authenticate_with_throttling(request, customer_user.email, CORRECT_PASSWORD)
    # a successful login does not lift the password change block either
    with pytest.raises(ValidationError):
        check_old_password_with_throttling(customer_user, CORRECT_PASSWORD)


@freeze_time(NOW)
def test_login_ip_block_does_not_affect_password_change(
    rf, customer_user, throttling_cache
):
    request = rf.request(HTTP_X_FORWARDED_FOR=IP)
    authenticate_with_throttling(request, customer_user.email, INCORRECT_PASSWORD)
    assert throttling_cache.get(get_cache_key_blocked_ip(IP))

    assert check_old_password_with_throttling(customer_user, CORRECT_PASSWORD)


@freeze_time(NOW)
def test_password_is_not_hashed_while_blocked(customer_user, throttling_cache):
    block_key = get_cache_key_blocked_password_change(customer_user.pk)
    throttling_cache.set(block_key, timezone.now(), timeout=60)

    with patch.object(User, "check_password") as mocked_check_password:
        with pytest.raises(ValidationError):
            check_old_password_with_throttling(customer_user, CORRECT_PASSWORD)

    mocked_check_password.assert_not_called()


@patch("saleor.account.throttling.cache")
def test_cache_failure_fails_closed(mocked_cache, customer_user):
    mocked_cache.add.side_effect = ConnectionError

    with patch.object(User, "check_password") as mocked_check_password:
        with pytest.raises(ConnectionError):
            check_old_password_with_throttling(customer_user, CORRECT_PASSWORD)

    mocked_check_password.assert_not_called()
