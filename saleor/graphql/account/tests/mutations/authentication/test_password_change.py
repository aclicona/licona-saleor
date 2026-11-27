from unittest.mock import patch

import pytest
from django.core.cache import cache
from freezegun import freeze_time

from ......account import events as account_events
from ......account.error_codes import AccountErrorCode
from ......account.throttling_password_change import (
    get_cache_key_blocked_password_change,
    get_cache_key_failed_password_change,
)
from ......site import PasswordLoginMode
from .....tests.utils import get_graphql_content, get_graphql_content_from_response

CHANGE_PASSWORD_MUTATION = """
    mutation PasswordChange($oldPassword: String, $newPassword: String!) {
        passwordChange(oldPassword: $oldPassword, newPassword: $newPassword) {
            errors {
                field
                message
                code
            }
            user {
                email
            }
        }
    }
"""


def test_password_change(user_api_client):
    customer_user = user_api_client.user
    new_password = "spanish-inquisition"

    variables = {"oldPassword": "password", "newPassword": new_password}
    response = user_api_client.post_graphql(CHANGE_PASSWORD_MUTATION, variables)
    content = get_graphql_content(response)
    data = content["data"]["passwordChange"]
    assert not data["errors"]
    assert data["user"]["email"] == customer_user.email

    customer_user.refresh_from_db()
    assert customer_user.check_password(new_password)

    password_change_event = account_events.CustomerEvent.objects.get()
    assert password_change_event.type == account_events.CustomerEvents.PASSWORD_CHANGED
    assert password_change_event.user == customer_user


def test_password_change_incorrect_old_password(user_api_client):
    customer_user = user_api_client.user
    variables = {"oldPassword": "incorrect", "newPassword": ""}
    response = user_api_client.post_graphql(CHANGE_PASSWORD_MUTATION, variables)
    content = get_graphql_content(response)
    data = content["data"]["passwordChange"]
    customer_user.refresh_from_db()
    assert customer_user.check_password("password")
    assert data["errors"]
    assert data["errors"][0]["field"] == "oldPassword"


def test_password_change_invalid_new_password(user_api_client, settings):
    settings.AUTH_PASSWORD_VALIDATORS = [
        {
            "NAME": "django.contrib.auth.password_validation.MinimumLengthValidator",
            "OPTIONS": {"min_length": 5},
        },
        {"NAME": "django.contrib.auth.password_validation.NumericPasswordValidator"},
    ]

    customer_user = user_api_client.user
    variables = {"oldPassword": "password", "newPassword": "1234"}
    response = user_api_client.post_graphql(CHANGE_PASSWORD_MUTATION, variables)
    content = get_graphql_content(response)
    errors = content["data"]["passwordChange"]["errors"]
    customer_user.refresh_from_db()
    assert customer_user.check_password("password")
    assert len(errors) == 2
    assert errors[1]["field"] == "newPassword"
    assert (
        errors[0]["message"]
        == "This password is too short. It must contain at least 5 characters."
    )
    assert errors[1]["field"] == "newPassword"
    assert errors[1]["message"] == "This password is entirely numeric."


def test_password_change_user_unusable_password_fails_if_old_password_is_set(
    user_api_client,
):
    customer_user = user_api_client.user
    customer_user.set_unusable_password()
    customer_user.save()

    new_password = "spanish-inquisition"

    variables = {"oldPassword": "password", "newPassword": new_password}
    response = user_api_client.post_graphql(CHANGE_PASSWORD_MUTATION, variables)
    content = get_graphql_content(response)
    data = content["data"]["passwordChange"]
    assert data["errors"]
    assert data["errors"][0]["field"] == "oldPassword"

    customer_user.refresh_from_db()
    assert not customer_user.has_usable_password()


def test_password_change_user_unusable_password_if_old_password_is_omitted(
    user_api_client,
):
    customer_user = user_api_client.user
    customer_user.set_unusable_password()
    customer_user.save()

    new_password = "spanish-inquisition"

    variables = {"oldPassword": None, "newPassword": new_password}
    response = user_api_client.post_graphql(CHANGE_PASSWORD_MUTATION, variables)
    content = get_graphql_content(response)
    data = content["data"]["passwordChange"]
    assert not data["errors"]
    assert data["user"]["email"] == customer_user.email

    customer_user.refresh_from_db()
    assert customer_user.check_password(new_password)

    password_change_event = account_events.CustomerEvent.objects.get()
    assert password_change_event.type == account_events.CustomerEvents.PASSWORD_CHANGED
    assert password_change_event.user == customer_user


def test_password_change_user_usable_password_fails_if_old_password_is_omitted(
    user_api_client,
):
    customer_user = user_api_client.user

    new_password = "spanish-inquisition"

    variables = {"newPassword": new_password}
    response = user_api_client.post_graphql(CHANGE_PASSWORD_MUTATION, variables)
    content = get_graphql_content(response)
    data = content["data"]["passwordChange"]
    assert data["errors"]
    assert data["errors"][0]["field"] == "oldPassword"

    customer_user.refresh_from_db()
    assert customer_user.has_usable_password()
    assert not customer_user.check_password(new_password)


def test_password_change_disabled_password_login(user_api_client, site_settings):
    # given
    site_settings.password_login_mode = PasswordLoginMode.DISABLED
    site_settings.save(update_fields=["password_login_mode"])
    variables = {"oldPassword": "password", "newPassword": "new-password"}

    # when
    response = user_api_client.post_graphql(CHANGE_PASSWORD_MUTATION, variables)

    # then
    content = get_graphql_content_from_response(response)
    assert "errors" in content, content
    assert content["errors"][0]["message"] == "The authentication method is disabled."

    user_api_client.user.refresh_from_db()
    assert user_api_client.user.check_password("password")


# B-2606: throttling of the current password check


@pytest.fixture
def locmem_cache(settings):
    # In-process cache: its expiry follows `freeze_time`, a Redis server's would not.
    settings.CACHES = {
        "default": {"BACKEND": "django.core.cache.backends.locmem.LocMemCache"}
    }


@pytest.fixture
def throttling_cache(locmem_cache, cache_clear):
    return cache


def _change_password(client, old_password, new_password="spanish-inquisition", **extra):
    variables = {"oldPassword": old_password, "newPassword": new_password}
    response = client.post_graphql(CHANGE_PASSWORD_MUTATION, variables, **extra)
    return get_graphql_content(response)["data"]["passwordChange"]


@freeze_time("2026-11-27 12:00:00")
def test_password_change_is_delayed_after_failure(user_api_client, throttling_cache):
    # given
    user = user_api_client.user
    data = _change_password(user_api_client, "incorrect")
    assert data["errors"][0]["code"] == AccountErrorCode.INVALID_CREDENTIALS.name

    # when
    data = _change_password(user_api_client, "password")

    # then
    assert len(data["errors"]) == 1
    error = data["errors"][0]
    assert error["code"] == AccountErrorCode.LOGIN_ATTEMPT_DELAYED.name
    assert error["field"] is None
    assert "2026-11-27 12:00:01" in error["message"]
    assert data["user"] is None
    user.refresh_from_db()
    assert user.check_password("password")


@freeze_time("2026-11-27 12:00:00")
def test_password_change_invalid_new_password_is_not_penalized(
    user_api_client, throttling_cache, settings
):
    # given
    settings.AUTH_PASSWORD_VALIDATORS = [
        {"NAME": "django.contrib.auth.password_validation.NumericPasswordValidator"}
    ]
    user = user_api_client.user

    # when
    data = _change_password(user_api_client, "password", "1234")

    # then
    assert data["errors"][0]["field"] == "newPassword"
    assert throttling_cache.get(get_cache_key_failed_password_change(user.pk)) is None
    assert throttling_cache.get(get_cache_key_blocked_password_change(user.pk)) is None
    assert not _change_password(user_api_client, "password")["errors"]


@freeze_time("2026-11-27 12:00:00")
@pytest.mark.parametrize(
    "second_request_meta",
    [
        {"HTTP_X_FORWARDED_FOR": "203.0.113.2"},
        {"REMOTE_ADDR": ""},
    ],
)
def test_password_change_throttling_ignores_ip(
    user_api_client, throttling_cache, second_request_meta
):
    _change_password(user_api_client, "incorrect", HTTP_X_FORWARDED_FOR="203.0.113.1")

    data = _change_password(user_api_client, "password", **second_request_meta)

    assert data["errors"][0]["code"] == AccountErrorCode.LOGIN_ATTEMPT_DELAYED.name


@freeze_time("2026-11-27 12:00:00")
def test_password_change_without_ip_succeeds(user_api_client, throttling_cache):
    data = _change_password(user_api_client, "password", REMOTE_ADDR="")

    assert not data["errors"]


@freeze_time("2026-11-27 12:00:00")
def test_password_change_omitted_old_password_does_not_count(
    user_api_client, throttling_cache
):
    user = user_api_client.user

    for _ in range(2):
        data = _change_password(user_api_client, None)
        assert data["errors"][0]["code"] == AccountErrorCode.INVALID_CREDENTIALS.name

    assert throttling_cache.get(get_cache_key_failed_password_change(user.pk)) is None
    assert throttling_cache.get(get_cache_key_blocked_password_change(user.pk)) is None


@freeze_time("2026-11-27 12:00:00")
def test_password_change_unusable_password_is_not_blocked(
    user_api_client, throttling_cache
):
    # given: a failed attempt left the user blocked
    user = user_api_client.user
    user.set_unusable_password()
    user.save()
    _change_password(user_api_client, "incorrect")
    assert throttling_cache.get(get_cache_key_blocked_password_change(user.pk))

    # when
    data = _change_password(user_api_client, None)

    # then
    assert not data["errors"]


@freeze_time("2026-11-27 12:00:00")
def test_password_change_staff_user_is_throttled(staff_api_client, throttling_cache):
    _change_password(staff_api_client, "incorrect")

    data = _change_password(staff_api_client, "password")

    assert data["errors"][0]["code"] == AccountErrorCode.LOGIN_ATTEMPT_DELAYED.name
    staff_api_client.user.refresh_from_db()
    assert staff_api_client.user.check_password("password")


@patch("saleor.account.throttling.cache")
def test_password_change_fails_closed_when_cache_fails(mocked_cache, user_api_client):
    mocked_cache.add.side_effect = ConnectionError
    variables = {"oldPassword": "password", "newPassword": "spanish-inquisition"}

    response = user_api_client.post_graphql(CHANGE_PASSWORD_MUTATION, variables)

    content = get_graphql_content_from_response(response)
    assert content["errors"]
    assert content["data"]["passwordChange"] is None
    user_api_client.user.refresh_from_db()
    assert user_api_client.user.check_password("password")
