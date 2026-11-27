"""Caps on the mutations that create accounts or send emails.

Divergence from upstream (B-2607 and B-2611, see UPGRADE_NOTES.md): upstream lets
anyone call `accountRegister` and `requestPasswordReset`, and any logged in user call
`requestEmailChange` (which emails whatever address is given), without limit. Calls
are counted in fixed windows per network (see `get_throttling_network`), per user or
per recipient, and globally, under keys of their own, so they never interact with the
login throttling. A limit of 0 disables that cap. A cache failure propagates, so
nothing is created or sent without the throttling.
"""

import hashlib
import logging
from email.utils import parseaddr

from django.conf import settings
from django.core.cache import cache
from django.core.exceptions import ValidationError

from ..core.utils import get_client_ip
from . import models
from .error_codes import AccountErrorCode
from .throttling import get_throttling_network

ACCOUNT_REGISTER_SCOPE = "account_register"
PASSWORD_RESET_SCOPE = "password_reset"
EMAIL_CHANGE_SCOPE = "email_change"

logger = logging.getLogger(__name__)


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


def check_email_change_throttling(user: models.User, new_email: str) -> None:
    """Count a `requestEmailChange` email about to be sent; raise if over a cap.

    The caps are checked per user, per recipient and globally, in that order, so a
    rejected call does not consume the following ones.
    """
    window = settings.EMAIL_CHANGE_THROTTLE_WINDOW
    if _is_over_limit(
        get_cache_key_user(EMAIL_CHANGE_SCOPE, user.pk),
        settings.EMAIL_CHANGE_USER_LIMIT,
        window,
    ):
        raise _too_many_requests_error()
    if _is_over_limit(
        get_cache_key_recipient(EMAIL_CHANGE_SCOPE, new_email),
        settings.EMAIL_CHANGE_RECIPIENT_LIMIT,
        window,
    ):
        raise _too_many_requests_error()
    if _is_over_limit(
        get_cache_key_global(EMAIL_CHANGE_SCOPE),
        settings.EMAIL_CHANGE_GLOBAL_LIMIT,
        window,
    ):
        logger.error("Email change global limit exceeded, the email is not sent.")
        raise _too_many_requests_error()


def get_cache_key_network(scope: str, network: str) -> str:
    return f"{scope}:count:net:{network}"


def get_cache_key_global(scope: str) -> str:
    return f"{scope}:count:global"


def get_cache_key_user(scope: str, user_id) -> str:
    return f"{scope}:count:user:{user_id}"


def get_cache_key_recipient(scope: str, email: str) -> str:
    """Return the key of a recipient, which never holds the address in clear text.

    A display name, angle brackets or a comment do not make it another recipient.
    """
    email = email.strip()
    address = parseaddr(email)[1] or email
    digest = hashlib.sha256(address.lower().encode()).hexdigest()
    return f"{scope}:count:recipient:{digest}"


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


def _is_over_limit(key: str, limit: int, window: int | None = None) -> bool:
    """Count a call and check the limit; the window defaults to the B-2607 one."""
    if limit == 0:
        return False
    if window is None:
        window = settings.ACCOUNT_EMAIL_THROTTLE_WINDOW
    return _increment_in_window(key, window) > limit


def _increment_in_window(key: str, window: int) -> int:
    """Increment the counter of a fixed window, which starts with the first call."""
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
