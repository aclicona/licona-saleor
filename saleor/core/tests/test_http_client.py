import socket

import pytest
import requests_hardened
from requests import Request
from requests_hardened.ip_filter import InvalidIPAddress

from ... import user_agent_version
from ..http_client import HTTPClient, HTTPConfig

# IPv4 address of example.com as recorded in the VCR cassettes.
CASSETTE_EXAMPLE_COM_IP = "23.215.0.136"


def test_user_agent_override():
    # given
    request = Request("GET", "http://www.example.com")
    session = requests_hardened.HTTPSession(HTTPConfig)

    assert request.headers.get("User-Agent") is None

    # when
    session.prepare_request(request)

    # then
    assert request.headers.get("User-Agent") == user_agent_version


@pytest.mark.vcr(match_on=["method", "scheme", "port", "path", "query"])
@pytest.mark.parametrize("protocol", ["https", "http"])
def test_http_client_disallows_private_ip_ranges(protocol, monkeypatch):
    """Ensure requests made to private IP address ranges leads to an error to be raised.

    This test ensures that the requests-hardened library works correctly,
    especially when using untested 'requests' and 'urllib3' versions
    that may potentially be unsupported by this library.
    """

    # Pin the DNS resolution of example.com to the IPv4 address stored in the
    # cassette. Otherwise the real resolver may return an IPv6 address on dual-stack
    # hosts, which VCR cannot parse as a `host:port` pair (port matcher fails with
    # "Port could not be cast to integer").
    real_getaddrinfo = socket.getaddrinfo

    def getaddrinfo(host, *args, **kwargs):
        if host == "example.com":
            host = CASSETTE_EXAMPLE_COM_IP
        return real_getaddrinfo(host, *args, **kwargs)

    monkeypatch.setattr("requests_hardened.ip_filter.socket.getaddrinfo", getaddrinfo)

    # Enable IP filtering (disabled by default in tests)
    http_manager = HTTPClient.clone()
    http_manager.config.ip_filter_enable = True  # Block private ranges.

    # Should reject the IP address (expect error to be raised)
    with pytest.raises(InvalidIPAddress, match="10.0.0.1"):
        http_manager.send_request("GET", f"{protocol}://10.0.0.1", timeout=0.1)

    # Should not reject public IP ranges (sanity check).
    response = http_manager.send_request("GET", f"{protocol}://example.com")
    assert response.status_code == 200


@pytest.mark.parametrize("address", ["[::1]", "[fd00::1]", "[fe80::1]"])
def test_http_client_disallows_private_ipv6_ranges(address):
    # given
    http_manager = HTTPClient.clone()
    http_manager.config.ip_filter_enable = True
    http_manager.config.ip_filter_allow_loopback_ips = False

    # when / then
    with pytest.raises(InvalidIPAddress):
        http_manager.send_request("GET", f"http://{address}", timeout=0.1)
