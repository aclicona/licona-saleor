"""Regresión B-2471: rotar el primer elemento del X-Forwarded-For no evade el freno."""

from unittest.mock import patch

import pytest
from django.core.exceptions import ValidationError
from freezegun import freeze_time

from ..error_codes import AccountErrorCode
from ..throttling import authenticate_with_throttling, get_cache_key_blocked_ip

EXISTING_EMAIL = "test@example.com"
INCORRECT_PASSWORD = "incorrect-password"
PROXY_IP = "198.51.100.7"


@freeze_time("2024-05-31 12:00:01")
@patch("saleor.account.throttling.cache")
def test_authenticate_spoofed_forwarded_for_prefix_is_still_throttled(
    mocked_cache, rf, customer_user, setup_mock_for_cache
):
    # given: el atacante inventa el primer elemento; el proxy añade su IP real al final
    dummy_cache = {}
    setup_mock_for_cache(dummy_cache, mocked_cache)

    def attempt(spoofed_ip):
        request = rf.request(HTTP_X_FORWARDED_FOR=f"{spoofed_ip}, {PROXY_IP}")
        return authenticate_with_throttling(
            request, customer_user.email, INCORRECT_PASSWORD
        )

    # when
    assert attempt("1.1.1.1") is None

    # then: el segundo intento inmediato, con otro prefijo, cae en el bloqueo
    with pytest.raises(ValidationError) as e:
        attempt("2.2.2.2")
    assert e.value.code == AccountErrorCode.LOGIN_ATTEMPT_DELAYED.value
    assert get_cache_key_blocked_ip(PROXY_IP) in dummy_cache
    assert get_cache_key_blocked_ip("1.1.1.1") not in dummy_cache
