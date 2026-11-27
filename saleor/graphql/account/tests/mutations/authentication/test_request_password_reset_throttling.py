"""B-2607: caps on `requestPasswordReset`."""

from unittest.mock import patch

import pytest
from django.core.cache import cache
from freezegun import freeze_time

from ......account.error_codes import AccountErrorCode
from .....tests.utils import get_graphql_content

RESET_MUTATION = """
    mutation RequestPasswordReset($email: String!, $redirectUrl: String!) {
        requestPasswordReset(email: $email, redirectUrl: $redirectUrl) {
            errors {
                field
                message
                code
            }
        }
    }
"""

RESET_ALIASES_MUTATION = """
    mutation {
        first: requestPasswordReset(
            email: "a@example.com", redirectUrl: "https://www.example.com"
        ) {
            errors { code }
        }
        second: requestPasswordReset(
            email: "b@example.com", redirectUrl: "https://www.example.com"
        ) {
            errors { code }
        }
    }
"""

DELAYED = AccountErrorCode.LOGIN_ATTEMPT_DELAYED.name
IP = "123.123.123.123"
TASK_DELAY = (
    "saleor.graphql.account.mutations.authentication.request_password_reset."
    "trigger_send_password_reset_notification.delay"
)


@pytest.fixture
def locmem_cache(settings):
    # In-process cache: its expiry follows `freeze_time`, a Redis server's would not.
    settings.CACHES = {
        "default": {"BACKEND": "django.core.cache.backends.locmem.LocMemCache"}
    }


@pytest.fixture
def throttling_cache(locmem_cache, cache_clear):
    return cache


def _request_reset(client, email, redirect_url="https://www.example.com"):
    variables = {"email": email, "redirectUrl": redirect_url}
    response = client.post_graphql(RESET_MUTATION, variables, HTTP_X_FORWARDED_FOR=IP)
    return get_graphql_content(response)["data"]["requestPasswordReset"]


@freeze_time("2026-11-27 12:00:00")
@patch(TASK_DELAY)
def test_reset_over_network_limit(
    mocked_delay,
    api_client,
    customer_user,
    channel_PLN,
    settings,
    throttling_cache,
):
    # given
    settings.PASSWORD_RESET_NETWORK_LIMIT = 1
    assert not _request_reset(api_client, "unknown@example.com")["errors"]
    mocked_delay.reset_mock()

    # when
    existing = _request_reset(api_client, customer_user.email)
    unknown = _request_reset(api_client, "unknown@example.com")

    # then
    assert existing["errors"] == unknown["errors"]
    assert existing["errors"][0]["code"] == DELAYED
    assert existing["errors"][0]["field"] is None
    mocked_delay.assert_not_called()


@patch(TASK_DELAY)
def test_reset_failed_validation_counts(
    mocked_delay, api_client, customer_user, settings, throttling_cache
):
    settings.PASSWORD_RESET_NETWORK_LIMIT = 1
    data = _request_reset(api_client, customer_user.email, redirect_url="not-url")
    assert data["errors"][0]["field"] == "redirectUrl"

    data = _request_reset(api_client, customer_user.email)

    assert data["errors"][0]["code"] == DELAYED
    mocked_delay.assert_not_called()


@patch(TASK_DELAY)
def test_reset_counts_every_alias(
    mocked_delay, api_client, channel_PLN, settings, throttling_cache
):
    settings.PASSWORD_RESET_NETWORK_LIMIT = 1

    response = api_client.post_graphql(RESET_ALIASES_MUTATION, HTTP_X_FORWARDED_FOR=IP)

    data = get_graphql_content(response)["data"]
    assert not data["first"]["errors"]
    assert data["second"]["errors"][0]["code"] == DELAYED
    assert mocked_delay.call_count == 1


@patch("saleor.plugins.manager.PluginsManager.notify")
def test_reset_over_global_limit_responds_without_errors(
    mocked_notify,
    api_client,
    customer_user,
    customer_user2,
    channel_PLN,
    settings,
    throttling_cache,
):
    settings.PASSWORD_RESET_GLOBAL_LIMIT = 1
    # an unknown account does not consume the global quota
    assert not _request_reset(api_client, "unknown@example.com")["errors"]
    assert not _request_reset(api_client, customer_user.email)["errors"]
    assert mocked_notify.call_count == 1

    data = _request_reset(api_client, customer_user2.email)

    assert not data["errors"]
    assert mocked_notify.call_count == 1
