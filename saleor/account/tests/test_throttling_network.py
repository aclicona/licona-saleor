"""Regresión B-2587: el freno de login cuenta por red (/64 en IPv6), no por dirección."""

from unittest.mock import patch

import pytest
from django.core.exceptions import ValidationError
from freezegun import freeze_time

from ..error_codes import AccountErrorCode
from ..throttling import (
    authenticate_with_throttling,
    get_cache_key_blocked_ip,
    get_cache_key_failed_ip,
    get_cache_key_failed_ip_with_user,
)

INCORRECT_PASSWORD = "incorrect-password"


@pytest.fixture
def dummy_cache(setup_mock_for_cache):
    storage: dict = {}
    with patch("saleor.account.throttling.cache") as mocked_cache:
        setup_mock_for_cache(storage, mocked_cache)
        yield storage


def _fail_login(rf, ip, email, password=INCORRECT_PASSWORD):
    with patch("saleor.account.throttling.get_client_ip", return_value=ip):
        return authenticate_with_throttling(rf.request(), email, password)


@pytest.mark.parametrize(
    ("first_ip", "second_ip", "network"),
    [
        # dos direcciones del mismo /64
        ("2001:db8:1:2::1", "2001:db8:1:2:ffff:ffff:ffff:fffe", "2001:db8:1:2::/64"),
        # grafías distintas de la misma dirección (ceros y mayúsculas)
        ("2001:0DB8:0000:0000:0000:0000:0000:00AB", "2001:db8::ab", "2001:db8::/64"),
        # zona
        ("fe80::1%eth0", "fe80::2", "fe80::/64"),
        # loopback: el entero cabe en 32 bits y no debe acabar como red IPv4
        ("::1", "0:0:0:0:0:0:0:2", "::/64"),
        # IPv4 mapeada == IPv4
        ("::ffff:203.0.113.9", "203.0.113.9", "203.0.113.9"),
        ("::FFFF:cb00:7109", "203.0.113.9", "203.0.113.9"),
        # IPv4 sin cambios
        ("203.0.113.9", "203.0.113.9", "203.0.113.9"),
        # valor no parseable: se usa tal cual y el freno sigue cerrado
        ("not-an-ip", "not-an-ip", "not-an-ip"),
    ],
)
@freeze_time("2024-05-31 12:00:01")
def test_addresses_of_same_network_share_block_and_counters(
    rf, customer_user, dummy_cache, first_ip, second_ip, network
):
    # given
    block_key = get_cache_key_blocked_ip(network)
    ip_key = get_cache_key_failed_ip(network)
    ip_user_key = get_cache_key_failed_ip_with_user(network, customer_user.pk)
    assert _fail_login(rf, first_ip, customer_user.email) is None

    # when: segundo intento inmediato desde la otra dirección
    with pytest.raises(ValidationError) as e:
        _fail_login(rf, second_ip, customer_user.email)

    # then
    assert e.value.code == AccountErrorCode.LOGIN_ATTEMPT_DELAYED.value
    assert set(dummy_cache) == {block_key, ip_key, ip_user_key}

    # when: vencido el bloqueo, los contadores continúan
    del dummy_cache[block_key]
    assert _fail_login(rf, second_ip, customer_user.email) is None

    # then
    assert dummy_cache[ip_key]["value"] == 2
    assert dummy_cache[ip_user_key]["value"] == 2


@pytest.mark.parametrize(
    ("first_ip", "second_ip"),
    [
        ("2001:db8:1:2::1", "2001:db8:1:3::1"),
        ("203.0.113.9", "203.0.113.10"),
        ("::ffff:203.0.113.9", "::ffff:203.0.113.10"),
        ("not-an-ip", "other-not-an-ip"),
    ],
)
@freeze_time("2024-05-31 12:00:01")
def test_addresses_of_different_networks_are_throttled_apart(
    rf, customer_user, dummy_cache, first_ip, second_ip
):
    # given
    assert _fail_login(rf, first_ip, customer_user.email) is None

    # when
    user = _fail_login(rf, second_ip, customer_user.email)

    # then: no hay bloqueo y cada red tiene sus propios contadores
    assert user is None
    counters = [v["value"] for k, v in dummy_cache.items() if ":fail:" in k]
    assert counters == [1, 1, 1, 1]


@freeze_time("2024-05-31 12:00:01")
def test_successful_login_clears_counters_of_the_network(
    rf, customer_user, dummy_cache
):
    # given
    assert _fail_login(rf, "2001:db8:1:2::1", customer_user.email) is None
    del dummy_cache[get_cache_key_blocked_ip("2001:db8:1:2::/64")]

    # when
    user = _fail_login(rf, "2001:db8:1:2::2", customer_user.email, "password")

    # then
    assert user == customer_user
    assert dummy_cache == {}
