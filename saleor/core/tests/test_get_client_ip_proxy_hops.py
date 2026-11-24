"""Tests propios del fork (B-2471): `get_client_ip` confía en la IP que añade el proxy.

El cliente controla la parte izquierda del X-Forwarded-For; solo la derecha la añade
el proxy de confianza (`TRUSTED_PROXY_HOPS` saltos desde la derecha).
"""

import pytest
from django.test import RequestFactory

from ..utils import get_client_ip


def _request(xff=None):
    headers = {"HTTP_X_FORWARDED_FOR": xff} if xff is not None else {}
    return RequestFactory(**headers).get("/")


@pytest.mark.parametrize(
    ("xff", "expected_ip"),
    [
        ("203.0.113.9, 198.51.100.7", "198.51.100.7"),
        ("203.0.113.9,198.51.100.7", "198.51.100.7"),
        ("  198.51.100.7  ", "198.51.100.7"),
        ("8.8.8.8,invalid", "127.0.0.1"),
        ("203.0.113.9, fd12::1", "fd12::1"),
        ("::1", "::1"),
        ("198.51.100.7, ", "127.0.0.1"),
    ],
)
def test_get_client_ip_takes_rightmost_trusted_hop(xff, expected_ip):
    assert get_client_ip(_request(xff)) == expected_ip


def test_get_client_ip_two_hops_takes_second_from_right(settings):
    settings.TRUSTED_PROXY_HOPS = 2
    request = _request("1.1.1.1, 203.0.113.9, 198.51.100.7")
    assert get_client_ip(request) == "203.0.113.9"


def test_get_client_ip_two_hops_with_single_ip_falls_back_to_remote_addr(settings):
    settings.TRUSTED_PROXY_HOPS = 2
    assert get_client_ip(_request("203.0.113.9")) == "127.0.0.1"


def test_get_client_ip_zero_hops_ignores_forwarded_for(settings):
    settings.TRUSTED_PROXY_HOPS = 0
    assert get_client_ip(_request("203.0.113.9, 198.51.100.7")) == "127.0.0.1"


def test_get_client_ip_without_forwarded_for_uses_remote_addr():
    assert get_client_ip(_request()) == "127.0.0.1"
