"""RFC 8785 (JSON Canonicalization Scheme), constrained to this project's value
domain: str, int, bool, None, list, dict. No floats (spec § Behavioral equivalence).
Output has no trailing newline."""
from __future__ import annotations

_SHORT_ESCAPES = {
    0x08: "\\b",
    0x09: "\\t",
    0x0A: "\\n",
    0x0C: "\\f",
    0x0D: "\\r",
    0x22: '\\"',
    0x5C: "\\\\",
}


def _escape_string(s: str) -> str:
    out = []
    for ch in s:
        cp = ord(ch)
        short = _SHORT_ESCAPES.get(cp)
        if short is not None:
            out.append(short)
        elif cp < 0x20:
            out.append("\\u%04x" % cp)
        else:
            out.append(ch)
    return '"' + "".join(out) + '"'


def _utf16_key(key: str) -> bytes:
    # RFC 8785 orders object members by the UTF-16 code units of their keys.
    return key.encode("utf-16-be")


def _serialize(value) -> str:
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, str):
        return _escape_string(value)
    if isinstance(value, int):
        # bool is handled above; guard the exact-integer domain (RFC 8785 numbers are IEEE-754,
        # exact only within +/-(2^53 - 1)). This stack only ever emits small non-negative ints.
        if not (-(2 ** 53 - 1) <= value <= 2 ** 53 - 1):
            raise ValueError(f"JCS: integer {value} outside the exact-representable range")
        return str(value)
    if isinstance(value, list):
        return "[" + ",".join(_serialize(v) for v in value) + "]"
    if isinstance(value, dict):
        items = sorted(value.items(), key=lambda kv: _utf16_key(kv[0]))
        return "{" + ",".join(_escape_string(k) + ":" + _serialize(v) for k, v in items) + "}"
    raise TypeError(f"JCS: unsupported type {type(value).__name__}")


def canonical(value) -> str:
    """RFC 8785 canonical JSON string, no trailing newline."""
    return _serialize(value)


def canonical_bytes(value) -> bytes:
    return canonical(value).encode("utf-8")
