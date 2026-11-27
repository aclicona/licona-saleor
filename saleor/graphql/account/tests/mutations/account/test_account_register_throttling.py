"""B-2607: caps on `accountRegister`."""

from unittest.mock import patch

import pytest
from django.core.cache import cache
from freezegun import freeze_time

from ......account.error_codes import AccountErrorCode
from ......account.models import User
from .....tests.utils import get_graphql_content, get_graphql_content_from_response

REGISTER_MUTATION = """
    mutation RegisterAccount($input: AccountRegisterInput!) {
        accountRegister(input: $input) {
            errors {
                field
                message
                code
            }
        }
    }
"""

REGISTER_ALIASES_MUTATION = """
    mutation {
        first: accountRegister(
            input: {email: "first@example.com", password: "Password"}
        ) {
            errors { code }
        }
        second: accountRegister(
            input: {email: "second@example.com", password: "Password"}
        ) {
            errors { code }
        }
    }
"""

DELAYED = AccountErrorCode.LOGIN_ATTEMPT_DELAYED.name
IP = "123.123.123.123"
OTHER_IP = "124.124.124.124"
FINISH_CREATING_USER = (
    "saleor.graphql.account.mutations.account.account_register."
    "finish_creating_user.delay"
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


@pytest.fixture
def no_confirmation(site_settings):
    site_settings.enable_account_confirmation_by_email = False
    site_settings.save(update_fields=["enable_account_confirmation_by_email"])


def _register(client, email, ip=IP):
    variables = {"input": {"email": email, "password": "Password"}}
    response = client.post_graphql(
        REGISTER_MUTATION, variables, HTTP_X_FORWARDED_FOR=ip
    )
    return get_graphql_content(response)["data"]["accountRegister"]


@freeze_time("2026-11-27 12:00:00")
@patch(FINISH_CREATING_USER)
def test_register_over_network_limit(
    mocked_delay,
    api_client,
    customer_user,
    no_confirmation,
    settings,
    throttling_cache,
):
    # given
    settings.ACCOUNT_REGISTER_NETWORK_LIMIT = 1
    assert not _register(api_client, "first@example.com")["errors"]
    mocked_delay.reset_mock()

    # when
    new = _register(api_client, "new@example.com")
    existing = _register(api_client, customer_user.email)

    # then
    assert new["errors"] == existing["errors"]
    assert new["errors"][0]["code"] == DELAYED
    assert new["errors"][0]["field"] is None
    assert not User.objects.filter(email="new@example.com").exists()
    mocked_delay.assert_not_called()


@patch(FINISH_CREATING_USER)
def test_register_over_global_limit_from_other_network(
    mocked_delay, api_client, no_confirmation, settings, throttling_cache
):
    settings.ACCOUNT_REGISTER_GLOBAL_LIMIT = 1
    assert not _register(api_client, "first@example.com")["errors"]

    data = _register(api_client, "second@example.com", ip=OTHER_IP)

    assert data["errors"][0]["code"] == DELAYED
    assert not User.objects.filter(email="second@example.com").exists()
    assert mocked_delay.call_count == 1


@patch(FINISH_CREATING_USER)
def test_register_counts_every_alias(
    mocked_delay, api_client, no_confirmation, settings, throttling_cache
):
    settings.ACCOUNT_REGISTER_NETWORK_LIMIT = 1

    response = api_client.post_graphql(
        REGISTER_ALIASES_MUTATION, HTTP_X_FORWARDED_FOR=IP
    )

    data = get_graphql_content(response)["data"]
    assert not data["first"]["errors"]
    assert data["second"]["errors"][0]["code"] == DELAYED
    assert not User.objects.filter(email="second@example.com").exists()
    assert mocked_delay.call_count == 1


@patch(FINISH_CREATING_USER)
def test_register_failed_validation_counts(
    mocked_delay, api_client, site_settings, settings, throttling_cache
):
    # given: confirmation requires `redirectUrl`, which is not sent
    site_settings.enable_account_confirmation_by_email = True
    site_settings.save(update_fields=["enable_account_confirmation_by_email"])
    settings.ACCOUNT_REGISTER_NETWORK_LIMIT = 1
    data = _register(api_client, "new@example.com")
    assert data["errors"][0]["code"] == AccountErrorCode.REQUIRED.name

    # when
    data = _register(api_client, "new@example.com")

    # then
    assert data["errors"][0]["code"] == DELAYED


@patch(FINISH_CREATING_USER)
@patch("saleor.account.throttling_email_requests.cache")
def test_register_fails_closed_without_cache(
    mocked_cache, mocked_delay, api_client, no_confirmation, settings
):
    settings.ACCOUNT_REGISTER_NETWORK_LIMIT = 1
    mocked_cache.add.side_effect = ConnectionError
    variables = {"input": {"email": "new@example.com", "password": "Password"}}

    response = api_client.post_graphql(
        REGISTER_MUTATION, variables, HTTP_X_FORWARDED_FOR=IP
    )

    assert get_graphql_content_from_response(response)["errors"]
    assert mocked_cache.add.called
    assert not User.objects.filter(email="new@example.com").exists()
    mocked_delay.assert_not_called()
