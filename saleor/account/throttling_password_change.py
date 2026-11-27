"""Throttling of the current password check of `passwordChange`.

Divergence from upstream (B-2606, see UPGRADE_NOTES.md): upstream lets the holder of an
access token guess the current password without limit. Attempts are counted per user
only (no IP) under keys of their own, so they never interact with the login throttling.
A cache failure propagates, so the password is never checked without the throttling.
"""

import datetime

from django.core.cache import cache
from django.core.exceptions import ValidationError
from django.utils import timezone

from . import models
from .error_codes import AccountErrorCode
from .throttling import (
    ATTEMPT_COUNTER_EXPIRE_TIME,
    MIN_DELAY,
    add_block,
    clear_cache,
    get_delay_time,
    increment_attempt,
    override_block,
)


def check_old_password_with_throttling(user: models.User, old_password: str) -> bool:
    """Check the current password of the user, delaying the attempts after failures.

    Raise `ValidationError` without checking the password if the user is blocked.
    """
    fail_key = get_cache_key_failed_password_change(user.pk)
    block_key = get_cache_key_blocked_password_change(user.pk)

    # block the user before the next attempt to prevent concurrent requests
    if add_block(block_key, MIN_DELAY) is False:
        next_attempt_time = cache.get(block_key) or timezone.now() + datetime.timedelta(
            seconds=MIN_DELAY
        )
        raise ValidationError(
            f"Password change has been suspended till {next_attempt_time} due to too "
            f"many attempts.",
            code=AccountErrorCode.LOGIN_ATTEMPT_DELAYED.value,
        )

    if user.check_password(old_password):
        clear_cache([fail_key, block_key])
        return True

    attempts_count = increment_attempt(fail_key)
    # the counter lives while the attempts continue, not only since the first one
    cache.touch(fail_key, ATTEMPT_COUNTER_EXPIRE_TIME)
    override_block(block_key, get_delay_time(0, attempts_count))
    return False


def get_cache_key_failed_password_change(user_id) -> str:
    return f"password_change:fail:user:{user_id}"


def get_cache_key_blocked_password_change(user_id) -> str:
    return f"password_change:block:user:{user_id}"
