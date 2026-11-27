"""Caps on the anonymous mutations that create accounts or send emails.

Divergence from upstream (B-2607, see UPGRADE_NOTES.md): upstream lets anyone call
`accountRegister` and `requestPasswordReset` without limit. Calls are counted in fixed
windows per network (see `get_throttling_network`) and globally, under keys of their
own, so they never interact with the login throttling. A limit of 0 disables that cap.
A cache failure propagates, so nothing is created or sent without the throttling.
"""

from django.conf import settings
from django.core.cache import cache
from django.core.exceptions import ValidationError

from ..core.utils import get_client_ip
from .error_codes import AccountErrorCode
from .throttling import get_throttling_network

ACCOUNT_REGISTER_SCOPE = "account_register"
PASSWORD_RESET_SCOPE = "password_reset"


def check_account_register_throttling(request) -> None:
    """Count an `accountRegister` call; raise `ValidationError` if over a cap."""
    _check_network_limit(
        request, ACCOUNT_REGISTER_SCOPE, settings.ACCOUNT_REGISTER_NETWORK_LIMIT
    )
    # checked after the network one, so rejected networks do not consume it
    if _is_over_limit(
        get_cache_key_global(ACCOUNT_REGISTER_SCOPE),
        settings.ACCOUNT_REGISTER_GLOBAL_LIMIT,
    ):
        raise _too_many_requests_error()


def check_password_reset_throttling(request) -> None:
    """Count a `requestPasswordReset` call; raise `ValidationError` if over the cap.

    Only per network: the global cap counts the emails really sent, in the task.
    """
    _check_network_limit(
        request, PASSWORD_RESET_SCOPE, settings.PASSWORD_RESET_NETWORK_LIMIT
    )


def is_password_reset_global_limit_exceeded() -> bool:
    """Count a password reset email about to be sent and check the global cap."""
    return _is_over_limit(
        get_cache_key_global(PASSWORD_RESET_SCOPE),
        settings.PASSWORD_RESET_GLOBAL_LIMIT,
    )


def get_cache_key_network(scope: str, network: str) -> str:
    return f"{scope}:count:net:{network}"


def get_cache_key_global(scope: str) -> str:
    return f"{scope}:count:global"


def _check_network_limit(request, scope: str, limit: int) -> None:
    if limit == 0:
        return
    ip = get_client_ip(request)
    if not ip:
        raise ValidationError(
            "Can't identify requester IP address.",
            code=AccountErrorCode.UNKNOWN_IP_ADDRESS.value,
        )
    key = get_cache_key_network(scope, get_throttling_network(ip))
    if _is_over_limit(key, limit):
        raise _too_many_requests_error()


def _is_over_limit(key: str, limit: int) -> bool:
    if limit == 0:
        return False
    return _increment_in_window(key) > limit


def _increment_in_window(key: str) -> int:
    """Increment the counter of a fixed window, which starts with the first call."""
    window = settings.ACCOUNT_EMAIL_THROTTLE_WINDOW
    cache.add(key, 0, timeout=window)
    try:
        count = cache.incr(key)
    except ValueError:
        # the window expired between both calls: start the next one
        cache.add(key, 0, timeout=window)
        count = cache.incr(key)
    if count == 1:
        # Redis `incr` is not atomic in Django: a key expiring inside it is recreated
        # without expiry, which would never reset the counter
        cache.touch(key, window)
    return count


def _too_many_requests_error() -> ValidationError:
    return ValidationError(
        "Too many requests. Try again later.",
        code=AccountErrorCode.LOGIN_ATTEMPT_DELAYED.value,
    )
