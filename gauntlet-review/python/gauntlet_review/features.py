"""Default-deny feature policy. Behavioral port of Get-DisableSet (lib.ps1)."""
from __future__ import annotations

FEATURE_ALLOWLIST: frozenset[str] = frozenset(
    {
        "enable_request_compression",
        "remote_compaction_v2",
        "fast_mode",
        "personality",
        "guardian_approval",
    }
)


def disable_set(feature_names: list[str]) -> list[str]:
    """Every enumerated feature not on the allowlist, sorted and de-duplicated.
    Reported state is ignored (reviews run --ignore-user-config)."""
    for f in feature_names:
        if f is None or f == "":
            raise ValueError("disable_set: feature_names must not contain None or empty strings")
    return sorted({f for f in feature_names if f not in FEATURE_ALLOWLIST})
