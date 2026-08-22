# Cross-Platform Gauntlet — Phase 1: Offline Core — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the OS-agnostic, offline core of the Python `gauntlet-review` stack — canonical serialization, verdict normalization + recommendation-id derivation, the acceptance-time usage gate, the default-deny feature policy, and the state/carry-over-ledger logic — each verified by pytest with **zero** Docker, network, or model calls.

**Architecture:** A Python package `gauntlet_review` under `gauntlet-review/python/`, ported *behaviorally* from the Windows PowerShell reference (`gauntlet-review/scripts/lib.ps1`). This phase is the foundation the container sandbox, broker, publisher, premises/evidence, battery, and installer (Phases 2–5) build on. The Windows PowerShell stack is untouched.

**Tech Stack:** Python 3.11+, `jsonschema` (Draft 7), `pytest`. Standard library only otherwise (`hashlib`, `json`, `pathlib`).

## Why this is Phase 1 of 5

The spec (`docs/superpowers/specs/2026-08-18-cross-platform-unix-mac-design.md`) is a full security-critical port; it is too large for one plan. It decomposes into five sequentially-buildable, independently-testable plans:

| Phase | Scope | Needs |
|---|---|---|
| **1 (this doc)** | Offline core: `jcs.py`, `verdict.py`, `usage.py`, `features.py`, `state.py` + pytest | nothing external |
| 2 | Container image + `sandbox.py` (lifecycle/watchdog/bounded streams/mount allowlist) + `broker.py` (staging, token exchange, locking) | Docker/Podman |
| 3 | `premises.py` (manifest, `host_impl_digest`, `python_runtime_fingerprint`, semantic invocation profile, non-self-calibrating policy validator) + `invoke_codex.py` entry point | Docker + model |
| 4 | `publish.py` (PR-mode publication, provenance binding, drift, dismissal) + `state.py` pr-mode paths | `gh` |
| 5 | Live security battery + `install.py`/`install.sh` + `SKILL.md` platform dispatch | Docker + model |

Phase 1 produces working, unit-tested library code on its own and de-risks the spec's hardest **behavioral-equivalence** requirements (identical id derivation; a fully-specified canonical serializer) before any container work begins.

## Global Constraints

Every task's requirements implicitly include this section. Values are copied verbatim from the spec.

- **Python 3.11+.** (3.11 floor so later phases can use `tomllib` for Codex `config.toml`.)
- **The Windows PowerShell stack is never modified.** Cross-stack *byte-identical* file output is **not** a requirement; identical *recommendation-id derivation* and *normalization semantics* **are**.
- **Canonical serialization is RFC 8785 (JCS).** Value domains are limited to `str`, `int`, `bool`, `None`, `list`, `dict` — **no floats**. Files this stack writes **end without a trailing newline**.
- **The verdict schema is the shared file** `gauntlet-review/schemas/verdict.schema.json` (Draft 7). Both stacks use it.
- **Severity invariant:** `approve` is valid only when every recommendation has severity `nit`; an `approve` carrying any non-`nit` recommendation is downgraded to `request_changes`.
- **Size bounds:** `summary` ≤ 800; per recommendation `location` ≤ 150, `issue` ≤ 500, `suggestion` ≤ 500; `recommendations` ≤ 20 items. (Enforced by the schema.)
- **Recommendation id:** `"r{Round}-" + sha256("{Round}|{Index}|{severity}|{location}|{issue}|{suggestion}").digest()[:16].hex()`.
- **Feature allowlist (default-deny):** exactly `enable_request_compression`, `remote_compaction_v2`, `fast_mode`, `personality`, `guardian_approval`. Every enumerated feature **not** on it is disabled.
- **Usage gate:** the event stream must contain **exactly one** `turn.completed`; its `usage.input_tokens` must be a positive integer; and (checked in Phase 3) `input_tokens + 128000 <= 787500`, i.e. `input_tokens <= 659500`.
- **Exit-code contract (shared with Windows, enforced in later phases):** `0` ok; `10` budget; `11` failed attempt (one retry); `12` environment; `13` pin changed; `14` cap/attempts exhausted; `16` carry-over ledger invalid; publication `2`–`6`.

## File Structure (Phase 1)

- Create `gauntlet-review/python/pyproject.toml` — package + pytest config, `jsonschema` dependency.
- Create `gauntlet-review/python/gauntlet_review/__init__.py` — empty package marker.
- Create `gauntlet-review/python/gauntlet_review/jcs.py` — RFC 8785 canonical serialization (Task 1).
- Create `gauntlet-review/python/gauntlet_review/verdict.py` — `recommendation_id` (Task 2) + `normalize_verdict` (Task 3).
- Create `gauntlet-review/python/gauntlet_review/usage.py` — `parse_run_usage` acceptance-time gate (Task 4).
- Create `gauntlet-review/python/gauntlet_review/features.py` — allowlist + `disable_set` (Task 5).
- Create `gauntlet-review/python/gauntlet_review/state.py` — `state_dir`, `prior_recommendations`, `validate_carryover_ledger`, `render_carryover_text` (Task 6).
- Create `gauntlet-review/python/tests/…` — one test module per source module.

Run all commands from `gauntlet-review/python/` unless stated otherwise.

---

### Task 1: Package scaffold + RFC 8785 canonical serializer (`jcs.py`)

**Files:**
- Create: `gauntlet-review/python/pyproject.toml`
- Create: `gauntlet-review/python/gauntlet_review/__init__.py`
- Create: `gauntlet-review/python/gauntlet_review/jcs.py`
- Test: `gauntlet-review/python/tests/test_jcs.py`

**Interfaces:**
- Produces: `gauntlet_review.jcs.canonical(value) -> str` and `canonical_bytes(value) -> bytes`. `value` is any of `str | int | bool | None | list | dict` (dicts keyed by `str`). Output is RFC 8785 canonical JSON, **no trailing newline**. Raises `TypeError` on `float` or any other type.

- [ ] **Step 1: Write the failing test**

Create `gauntlet-review/python/tests/test_jcs.py`:

```python
import pytest
from gauntlet_review.jcs import canonical, canonical_bytes


def test_object_keys_sorted_and_no_whitespace():
    assert canonical({"b": 1, "a": "x"}) == '{"a":"x","b":1}'


def test_string_escaping_quote_backslash_and_short_controls():
    # " and \ escape; the five short control escapes are used; other controls are \u00xx.
    assert canonical('he said "hi"\n\t\\ end\x01') == r'"he said \"hi\"\n\t\\ end\u0001"'


def test_non_ascii_is_emitted_as_utf8_not_escaped():
    assert canonical_bytes({"x": "café"}) == '{"x":"café"}'.encode("utf-8")


def test_bool_null_int_and_nested():
    assert canonical({"k": [True, False, None, 0, -3]}) == '{"k":[true,false,null,0,-3]}'


def test_keys_sorted_by_utf16_code_units():
    # "Z" (0x5A) sorts before "a" (0x61) by code unit.
    assert canonical({"a": 1, "Z": 2}) == '{"Z":2,"a":1}'


def test_no_trailing_newline():
    assert not canonical({"a": 1}).endswith("\n")


def test_float_is_rejected():
    with pytest.raises(TypeError):
        canonical({"x": 1.5})


def test_int_at_exact_boundary_ok_and_beyond_rejected():
    assert canonical(2 ** 53 - 1) == str(2 ** 53 - 1)
    with pytest.raises(ValueError):
        canonical(2 ** 53)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest tests/test_jcs.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'gauntlet_review'`.

- [ ] **Step 3: Write the scaffold and the serializer**

Create `gauntlet-review/python/pyproject.toml`:

```toml
[build-system]
requires = ["setuptools>=61"]
build-backend = "setuptools.build_meta"

[project]
name = "gauntlet-review"
version = "0.1.0"
requires-python = ">=3.11"
dependencies = ["jsonschema>=4.0"]

[project.optional-dependencies]
dev = ["pytest>=7.0"]

[tool.setuptools.packages.find]
where = ["."]
include = ["gauntlet_review*"]

[tool.pytest.ini_options]
testpaths = ["tests"]
addopts = "-q"
```

Create `gauntlet-review/python/gauntlet_review/__init__.py` (empty file).

Create `gauntlet-review/python/gauntlet_review/jcs.py`:

```python
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python -m pip install -e ".[dev]" && python -m pytest tests/test_jcs.py -v`
Expected: PASS (8 tests).

- [ ] **Step 5: Commit**

```bash
git add gauntlet-review/python/pyproject.toml gauntlet-review/python/gauntlet_review/__init__.py gauntlet-review/python/gauntlet_review/jcs.py gauntlet-review/python/tests/test_jcs.py
git commit -m "feat(py): package scaffold + RFC 8785 canonical serializer"
```

---

### Task 2: Recommendation-id derivation (`verdict.py`)

**Files:**
- Create: `gauntlet-review/python/gauntlet_review/verdict.py`
- Test: `gauntlet-review/python/tests/test_recommendation_id.py`

**Interfaces:**
- Produces: `gauntlet_review.verdict.recommendation_id(round_num: int, index: int, rec: dict) -> str`. `rec` has keys `severity`, `location`, `issue`, `suggestion`. Returns `"r{round}-{hex32}"` — **byte-for-byte identical to the PowerShell `Get-RecommendationId`** (verified against captured authoritative vectors below).

- [ ] **Step 1: Write the failing test**

The three expected ids were captured by running the PowerShell reference `Get-RecommendationId` on these exact inputs (authoritative, not self-derived).

Create `gauntlet-review/python/tests/test_recommendation_id.py`:

```python
from gauntlet_review.verdict import recommendation_id


def test_matches_powershell_reference_ascii():
    rec = {"severity": "blocking", "location": "file.py:10", "issue": "bug", "suggestion": "fix it"}
    assert recommendation_id(1, 0, rec) == "r1-e29bad181f048478478bb8447e9182fc"


def test_matches_powershell_reference_round_and_index_affect_id():
    rec = {"severity": "nit", "location": "section 2", "issue": "typo: cafe accent e", "suggestion": "correct it"}
    assert recommendation_id(3, 2, rec) == "r3-0740d612b704851d0f3ba7477d976a27"


def test_matches_powershell_reference_pipe_and_newline_in_fields():
    rec = {"severity": "important", "location": "L", "issue": "multi\nline", "suggestion": "a|b|c"}
    assert recommendation_id(2, 0, rec) == "r2-c579b558a6f78cbbbaeee5fd2baa29af"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest tests/test_recommendation_id.py -v`
Expected: FAIL — `ImportError: cannot import name 'recommendation_id'`.

- [ ] **Step 3: Write the implementation**

Create `gauntlet-review/python/gauntlet_review/verdict.py`:

```python
"""Verdict normalization + recommendation-id derivation.
Behavioral port of Test-Verdict and Get-RecommendationId (lib.ps1)."""
from __future__ import annotations

import hashlib


def recommendation_id(round_num: int, index: int, rec: dict) -> str:
    """Stable, content-derived id over ALL FOUR fields plus round and index.
    Matches PowerShell Get-RecommendationId byte-for-byte."""
    material = "{}|{}|{}|{}|{}|{}".format(
        round_num,
        index,
        rec["severity"],
        rec["location"],
        rec["issue"],
        rec["suggestion"],
    )
    digest = hashlib.sha256(material.encode("utf-8")).digest()
    return "r{}-".format(round_num) + digest[:16].hex()
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python -m pytest tests/test_recommendation_id.py -v`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add gauntlet-review/python/gauntlet_review/verdict.py gauntlet-review/python/tests/test_recommendation_id.py
git commit -m "feat(py): recommendation-id derivation matching PowerShell reference"
```

---

### Task 3: Verdict normalization (`verdict.py::normalize_verdict`)

**Files:**
- Modify: `gauntlet-review/python/gauntlet_review/verdict.py`
- Test: `gauntlet-review/python/tests/test_normalize_verdict.py`

**Interfaces:**
- Consumes: `gauntlet_review.jcs.canonical` (Task 1).
- Produces: `gauntlet_review.verdict.normalize_verdict(json_text: str, schema_path: str | os.PathLike) -> NormalizeResult`, a dataclass with fields `valid: bool`, `reason: str | None`, `downgraded: bool`, `normalized: dict | None`, `canonical_json: str | None`. Behavioral port of `Test-Verdict`: structural validation against the Draft-7 schema, then the severity-invariant downgrade (mutating `verdict` to `request_changes` when an `approve` carries a non-`nit` recommendation), then the canonical JSON of the normalized object.

- [ ] **Step 1: Write the failing test**

Create `gauntlet-review/python/tests/test_normalize_verdict.py`:

```python
import json
from pathlib import Path

from gauntlet_review.verdict import normalize_verdict

SCHEMA = Path(__file__).resolve().parents[2] / "schemas" / "verdict.schema.json"
assert SCHEMA.is_file(), f"schema fixture not found: {SCHEMA}"


def _verdict(verdict, recs):
    return json.dumps({"verdict": verdict, "summary": "s", "recommendations": recs})


def test_valid_request_changes_passes_unchanged():
    r = normalize_verdict(_verdict("request_changes", []), SCHEMA)
    assert r.valid and not r.downgraded
    assert r.normalized["verdict"] == "request_changes"
    assert r.canonical_json == '{"recommendations":[],"summary":"s","verdict":"request_changes"}'


def test_approve_with_only_nits_stays_approve():
    recs = [{"severity": "nit", "location": "L", "issue": "i", "suggestion": "s"}]
    r = normalize_verdict(_verdict("approve", recs), SCHEMA)
    assert r.valid and not r.downgraded
    assert r.normalized["verdict"] == "approve"


def test_approve_with_blocking_is_downgraded():
    recs = [{"severity": "blocking", "location": "L", "issue": "i", "suggestion": "s"}]
    r = normalize_verdict(_verdict("approve", recs), SCHEMA)
    assert r.valid and r.downgraded
    assert r.normalized["verdict"] == "request_changes"
    assert "downgraded" in r.reason


def test_structurally_invalid_extra_property_fails():
    bad = json.dumps({"verdict": "approve", "summary": "s", "recommendations": [], "extra": 1})
    r = normalize_verdict(bad, SCHEMA)
    assert not r.valid and r.reason == "structural validation failed"


def test_summary_over_800_fails():
    r = normalize_verdict(json.dumps({"verdict": "request_changes", "summary": "x" * 801, "recommendations": []}), SCHEMA)
    assert not r.valid


def test_non_json_fails_cleanly():
    r = normalize_verdict("{not json", SCHEMA)
    assert not r.valid
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest tests/test_normalize_verdict.py -v`
Expected: FAIL — `ImportError: cannot import name 'normalize_verdict'`.

- [ ] **Step 3: Write the implementation**

Append to `gauntlet-review/python/gauntlet_review/verdict.py`:

```python
import json
import os
from dataclasses import dataclass

import jsonschema

from gauntlet_review import jcs


@dataclass
class NormalizeResult:
    valid: bool
    reason: str | None
    downgraded: bool
    normalized: dict | None
    canonical_json: str | None


def normalize_verdict(json_text: str, schema_path: str | os.PathLike) -> NormalizeResult:
    """Structural validation + severity-invariant downgrade + canonical JSON.
    Behavioral port of Test-Verdict (lib.ps1)."""
    try:
        obj = json.loads(json_text)
    except json.JSONDecodeError:
        return NormalizeResult(False, "structural validation failed", False, None, None)

    with open(schema_path, "r", encoding="utf-8") as fh:
        schema = json.load(fh)
    try:
        jsonschema.validate(instance=obj, schema=schema, cls=jsonschema.Draft7Validator)
    except jsonschema.ValidationError:
        return NormalizeResult(False, "structural validation failed", False, None, None)

    downgraded = False
    reason = None
    if obj["verdict"] == "approve":
        non_nit = [r for r in obj["recommendations"] if r["severity"] != "nit"]
        if non_nit:
            obj["verdict"] = "request_changes"
            downgraded = True
            reason = f"approve carried {len(non_nit)} non-nit recommendation(s); downgraded"

    return NormalizeResult(True, reason, downgraded, obj, jcs.canonical(obj))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python -m pytest tests/test_normalize_verdict.py -v`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add gauntlet-review/python/gauntlet_review/verdict.py gauntlet-review/python/tests/test_normalize_verdict.py
git commit -m "feat(py): verdict normalization + severity-invariant downgrade"
```

---

### Task 4: Acceptance-time usage gate (`usage.py`)

**Files:**
- Create: `gauntlet-review/python/gauntlet_review/usage.py`
- Test: `gauntlet-review/python/tests/test_usage.py`

**Interfaces:**
- Produces: `gauntlet_review.usage.parse_run_usage(event_lines: list[str]) -> UsageResult`, a dataclass with `ok: bool`, `reason: str | None`, `input_tokens: int | None`, `raw_line: str | None`. Behavioral port of `Get-RunUsage`: fails closed on any non-blank line that is not a JSON object carrying `type`; rejects a top-level `error` or `turn.failed`; requires **exactly one** `turn.completed` whose `usage.input_tokens` is a positive integer.

- [ ] **Step 1: Write the failing test**

Create `gauntlet-review/python/tests/test_usage.py`:

```python
import json

from gauntlet_review.usage import parse_run_usage


def _stream(*events):
    # A real process's stdout ends with a trailing newline -> a trailing "" element after split.
    return [json.dumps(e) for e in events] + [""]


def test_happy_path_single_turn_completed():
    r = parse_run_usage(_stream(
        {"type": "thread.started"},
        {"type": "turn.completed", "usage": {"input_tokens": 9456}},
    ))
    assert r.ok and r.input_tokens == 9456
    assert json.loads(r.raw_line)["type"] == "turn.completed"


def test_blank_lines_are_skipped():
    r = parse_run_usage(["", "  ", json.dumps({"type": "turn.completed", "usage": {"input_tokens": 5}}), ""])
    assert r.ok and r.input_tokens == 5


def test_non_json_line_fails_closed():
    r = parse_run_usage(["not json", json.dumps({"type": "turn.completed", "usage": {"input_tokens": 5}})])
    assert not r.ok and "not valid JSON" in r.reason


def test_bare_non_object_line_fails_closed():
    r = parse_run_usage(["5"])
    assert not r.ok and "did not parse to a JSON object" in r.reason


def test_object_without_type_fails_closed():
    r = parse_run_usage([json.dumps({"usage": {"input_tokens": 5}})])
    assert not r.ok and "no 'type' field" in r.reason


def test_top_level_error_event_fails():
    r = parse_run_usage(_stream({"type": "error"}, {"type": "turn.completed", "usage": {"input_tokens": 5}}))
    assert not r.ok and "top-level error" in r.reason


def test_turn_failed_event_fails():
    r = parse_run_usage(_stream({"type": "turn.failed"}))
    assert not r.ok and "turn.failed" in r.reason


def test_zero_turn_completed_fails():
    r = parse_run_usage(_stream({"type": "thread.started"}))
    assert not r.ok and "no turn.completed" in r.reason


def test_two_turn_completed_fails():
    r = parse_run_usage(_stream(
        {"type": "turn.completed", "usage": {"input_tokens": 5}},
        {"type": "turn.completed", "usage": {"input_tokens": 6}},
    ))
    assert not r.ok and "expected exactly one" in r.reason


def test_missing_usage_fails():
    r = parse_run_usage(_stream({"type": "turn.completed"}))
    assert not r.ok and "no usage" in r.reason


def test_non_integer_input_tokens_fails():
    r = parse_run_usage(_stream({"type": "turn.completed", "usage": {"input_tokens": "9456"}}))
    assert not r.ok and "not an integer" in r.reason


def test_boolean_input_tokens_rejected():
    r = parse_run_usage(_stream({"type": "turn.completed", "usage": {"input_tokens": True}}))
    assert not r.ok and "not an integer" in r.reason


def test_non_positive_input_tokens_fails():
    r = parse_run_usage(_stream({"type": "turn.completed", "usage": {"input_tokens": 0}}))
    assert not r.ok and "positive integer" in r.reason
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest tests/test_usage.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'gauntlet_review.usage'`.

- [ ] **Step 3: Write the implementation**

Create `gauntlet-review/python/gauntlet_review/usage.py`:

```python
"""Acceptance-time usage gate. Behavioral port of Get-RunUsage (lib.ps1).
Fails closed on any malformed stream line."""
from __future__ import annotations

import json
from dataclasses import dataclass


@dataclass
class UsageResult:
    ok: bool
    reason: str | None
    input_tokens: int | None
    raw_line: str | None


def _bad(reason: str) -> UsageResult:
    return UsageResult(False, reason, None, None)


def parse_run_usage(event_lines: list[str]) -> UsageResult:
    events = []  # list[(raw_line, parsed_dict)]
    for line in event_lines:
        if not line or not line.strip():
            continue
        try:
            parsed = json.loads(line)
        except json.JSONDecodeError as exc:
            return _bad(f"event stream line is not valid JSON: {exc}")
        if not isinstance(parsed, dict):
            shape = "null" if parsed is None else type(parsed).__name__
            return _bad(f"event stream line did not parse to a JSON object (got {shape})")
        if "type" not in parsed:
            return _bad("event stream line is a JSON object with no 'type' field")
        events.append((line, parsed))

    if any(p.get("type") == "error" for _, p in events):
        return _bad("the event stream reported a top-level error event")
    if any(p.get("type") == "turn.failed" for _, p in events):
        return _bad("the event stream reported a turn.failed event")

    completed = [(raw, p) for raw, p in events if p.get("type") == "turn.completed"]
    if len(completed) == 0:
        return _bad("no turn.completed event in the event stream")
    if len(completed) > 1:
        return _bad(f"{len(completed)} turn.completed events in the event stream (expected exactly one)")

    raw, ev = completed[0]
    usage = ev.get("usage")
    if not isinstance(usage, dict):
        return _bad("turn.completed carries no usage object")
    if "input_tokens" not in usage:
        return _bad("usage carries no input_tokens")
    it = usage["input_tokens"]
    if isinstance(it, bool) or not isinstance(it, int):
        return _bad(f"usage.input_tokens is not an integer (got '{it}')")
    if it <= 0:
        return _bad(f"usage.input_tokens must be a positive integer (got {it})")
    return UsageResult(True, None, it, raw)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python -m pytest tests/test_usage.py -v`
Expected: PASS (13 tests).

- [ ] **Step 5: Commit**

```bash
git add gauntlet-review/python/gauntlet_review/usage.py gauntlet-review/python/tests/test_usage.py
git commit -m "feat(py): acceptance-time usage gate (fails closed on malformed streams)"
```

---

### Task 5: Default-deny feature policy (`features.py`)

**Files:**
- Create: `gauntlet-review/python/gauntlet_review/features.py`
- Test: `gauntlet-review/python/tests/test_features.py`

**Interfaces:**
- Produces: `gauntlet_review.features.FEATURE_ALLOWLIST: frozenset[str]` and `disable_set(feature_names: list[str]) -> list[str]`. Behavioral port of `Get-DisableSet`: returns the sorted, de-duplicated set of enumerated feature names **not** on the allowlist. Reported enabled/disabled state is irrelevant — presence in the enumeration is what drives the policy. Raises `ValueError` if any element is `None` or empty (port of `Assert-NoEmptyStringElements`).

- [ ] **Step 1: Write the failing test**

Create `gauntlet-review/python/tests/test_features.py`:

```python
import pytest

from gauntlet_review.features import FEATURE_ALLOWLIST, disable_set


def test_allowlist_is_exactly_the_five():
    assert FEATURE_ALLOWLIST == frozenset(
        {"enable_request_compression", "remote_compaction_v2", "fast_mode", "personality", "guardian_approval"}
    )


def test_disables_everything_not_allowlisted_sorted_unique():
    enumerated = ["shell_tool", "apps", "fast_mode", "apps", "personality", "browser_use"]
    assert disable_set(enumerated) == ["apps", "browser_use", "shell_tool"]


def test_allowlisted_only_yields_empty():
    assert disable_set(list(FEATURE_ALLOWLIST)) == []


def test_empty_enumeration_yields_empty():
    assert disable_set([]) == []


def test_empty_string_element_raises():
    with pytest.raises(ValueError):
        disable_set(["apps", ""])


def test_none_element_raises():
    with pytest.raises(ValueError):
        disable_set(["apps", None])  # type: ignore[list-item]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest tests/test_features.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'gauntlet_review.features'`.

- [ ] **Step 3: Write the implementation**

Create `gauntlet-review/python/gauntlet_review/features.py`:

```python
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python -m pytest tests/test_features.py -v`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add gauntlet-review/python/gauntlet_review/features.py gauntlet-review/python/tests/test_features.py
git commit -m "feat(py): default-deny feature policy"
```

---

### Task 6: State dir + prior recommendations + carry-over ledger (`state.py`)

**Files:**
- Create: `gauntlet-review/python/gauntlet_review/state.py`
- Test: `gauntlet-review/python/tests/test_state.py`

**Interfaces:**
- Consumes: `gauntlet_review.verdict.recommendation_id` (Task 2).
- Produces:
  - `gauntlet_review.state.doc_state_dir(repo_root, topic, phase, date) -> pathlib.Path` — validated `docs/superpowers/reviews/{date}-{topic}/{phase}` path (created). Port of `Get-StateDir` doc mode. (`pr` mode is added in Phase 4.)
  - `prior_recommendations(state_dir, up_to_round: int) -> list[dict]` — reads `round-{r}-verdict.json` for `r` in `1..up_to_round-1`; each item is `{"id","round","severity","location","issue","suggestion"}`. Port of `Get-PriorRecommendations`.
  - `validate_carryover_ledger(state_dir, round_num: int, ledger_path) -> LedgerResult` — port of `Test-CarryOverLedger`.
  - `render_carryover_text(entries: list[dict]) -> str` — port of `ConvertTo-CarryOverText`.

- [ ] **Step 1: Write the failing test**

Create `gauntlet-review/python/tests/test_state.py`:

```python
import json
from pathlib import Path

import pytest

from gauntlet_review.state import (
    doc_state_dir,
    prior_recommendations,
    validate_carryover_ledger,
    render_carryover_text,
)
from gauntlet_review.verdict import recommendation_id


def _write_verdict(state_dir: Path, round_num: int, recs: list[dict]):
    (state_dir / f"round-{round_num}-verdict.json").write_text(
        json.dumps({"verdict": "request_changes", "summary": "s", "recommendations": recs}),
        encoding="utf-8",
    )


REC = {"severity": "blocking", "location": "L", "issue": "i", "suggestion": "s"}


def test_doc_state_dir_builds_and_creates_expected_path(tmp_path):
    d = doc_state_dir(tmp_path, topic="my-topic", phase="spec", date="2026-08-18")
    expected = (Path(tmp_path) / "docs" / "superpowers" / "reviews" / "2026-08-18-my-topic" / "spec").resolve()
    assert d == expected
    assert d.is_dir()


def test_doc_state_dir_rejects_bad_topic(tmp_path):
    with pytest.raises(ValueError):
        doc_state_dir(tmp_path, topic="Bad_Topic", phase="spec", date="2026-08-18")


def test_doc_state_dir_rejects_bad_date(tmp_path):
    with pytest.raises(ValueError):
        doc_state_dir(tmp_path, topic="t", phase="spec", date="2026/08/18")


def test_prior_recommendations_ids_match_reference(tmp_path):
    _write_verdict(tmp_path, 1, [REC])
    prior = prior_recommendations(tmp_path, up_to_round=2)
    assert len(prior) == 1
    assert prior[0]["id"] == recommendation_id(1, 0, REC)
    assert prior[0]["round"] == 1 and prior[0]["issue"] == "i"


def test_prior_recommendations_excludes_current_round(tmp_path):
    _write_verdict(tmp_path, 1, [REC])
    _write_verdict(tmp_path, 2, [REC])
    assert len(prior_recommendations(tmp_path, up_to_round=2)) == 1  # only round 1


def _ledger(state_dir, round_num, entries):
    p = state_dir / f"ledger-{round_num}.json"
    p.write_text(json.dumps({"version": 1, "round": round_num, "entries": entries}), encoding="utf-8")
    return p


def _entry(rec_id, status="addressed", reason=None, **overrides):
    e = {"id": rec_id, "severity": REC["severity"], "location": REC["location"],
         "issue": REC["issue"], "suggestion": REC["suggestion"], "status": status}
    if reason is not None:
        e["reason"] = reason
    e.update(overrides)
    return e


def test_valid_ledger_passes(tmp_path):
    _write_verdict(tmp_path, 1, [REC])
    rid = recommendation_id(1, 0, REC)
    p = _ledger(tmp_path, 2, [_entry(rid)])
    r = validate_carryover_ledger(tmp_path, 2, p)
    assert r.valid


def test_ledger_missing_when_prior_exists_fails(tmp_path):
    _write_verdict(tmp_path, 1, [REC])
    r = validate_carryover_ledger(tmp_path, 2, tmp_path / "nope.json")
    assert not r.valid and "not found" in r.reason


def test_ledger_omitted_prior_fails(tmp_path):
    _write_verdict(tmp_path, 1, [REC])
    p = _ledger(tmp_path, 2, [])
    r = validate_carryover_ledger(tmp_path, 2, p)
    assert not r.valid and "OMITTED" in r.reason


def test_ledger_invented_id_fails(tmp_path):
    _write_verdict(tmp_path, 1, [REC])
    rid = recommendation_id(1, 0, REC)
    p = _ledger(tmp_path, 2, [_entry(rid), _entry("r1-deadbeef")])
    r = validate_carryover_ledger(tmp_path, 2, p)
    assert not r.valid and "invents" in r.reason


def test_ledger_mutated_text_fails(tmp_path):
    _write_verdict(tmp_path, 1, [REC])
    rid = recommendation_id(1, 0, REC)
    p = _ledger(tmp_path, 2, [_entry(rid, issue="MUTATED")])
    r = validate_carryover_ledger(tmp_path, 2, p)
    assert not r.valid and "mutation" in r.reason


def test_ledger_disputed_without_reason_fails(tmp_path):
    _write_verdict(tmp_path, 1, [REC])
    rid = recommendation_id(1, 0, REC)
    p = _ledger(tmp_path, 2, [_entry(rid, status="disputed")])
    r = validate_carryover_ledger(tmp_path, 2, p)
    assert not r.valid and "no reason" in r.reason


def test_ledger_wrong_round_fails(tmp_path):
    _write_verdict(tmp_path, 1, [REC])
    rid = recommendation_id(1, 0, REC)
    p = _ledger(tmp_path, 3, [_entry(rid)])  # says round 3
    r = validate_carryover_ledger(tmp_path, 2, p)  # invoked for round 2
    assert not r.valid and "round" in r.reason


def test_ledger_version_true_rejected(tmp_path):
    _write_verdict(tmp_path, 1, [REC])
    rid = recommendation_id(1, 0, REC)
    p = tmp_path / "ledger-2.json"
    p.write_text(json.dumps({"version": True, "round": 2, "entries": [_entry(rid)]}), encoding="utf-8")
    r = validate_carryover_ledger(tmp_path, 2, p)
    assert not r.valid and "version" in r.reason


def test_ledger_entries_not_list_rejected(tmp_path):
    _write_verdict(tmp_path, 1, [REC])
    p = tmp_path / "ledger-2.json"
    p.write_text(json.dumps({"version": 1, "round": 2, "entries": "nope"}), encoding="utf-8")
    r = validate_carryover_ledger(tmp_path, 2, p)
    assert not r.valid and "entries" in r.reason


def test_ledger_non_string_id_rejected(tmp_path):
    _write_verdict(tmp_path, 1, [REC])
    p = tmp_path / "ledger-2.json"
    entry = {**_entry("placeholder"), "id": 123}
    p.write_text(json.dumps({"version": 1, "round": 2, "entries": [entry]}), encoding="utf-8")
    r = validate_carryover_ledger(tmp_path, 2, p)
    assert not r.valid and "id" in r.reason


def test_ledger_non_string_status_rejected(tmp_path):
    _write_verdict(tmp_path, 1, [REC])
    rid = recommendation_id(1, 0, REC)
    p = tmp_path / "ledger-2.json"
    entry = {**_entry(rid), "status": ["addressed"]}  # a list must not raise TypeError
    p.write_text(json.dumps({"version": 1, "round": 2, "entries": [entry]}), encoding="utf-8")
    r = validate_carryover_ledger(tmp_path, 2, p)
    assert not r.valid and "status" in r.reason


def test_render_carryover_text_sorted_and_labeled(tmp_path):
    entries = [
        {"id": "r1-bbb", "severity": "nit", "location": "L2", "issue": "i2", "suggestion": "s2", "status": "addressed", "reason": None},
        {"id": "r1-aaa", "severity": "blocking", "location": "L1", "issue": "i1", "suggestion": "s1", "status": "disputed", "reason": "why"},
    ]
    text = render_carryover_text(entries)
    assert text.startswith("== PRIOR ROUNDS (trusted) ==")
    assert text.index("r1-aaa") < text.index("r1-bbb")  # sorted by id
    assert "status: disputed — why" in text


def test_render_carryover_text_empty_is_blank():
    assert render_carryover_text([]) == ""
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest tests/test_state.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'gauntlet_review.state'`.

- [ ] **Step 3: Write the implementation**

Create `gauntlet-review/python/gauntlet_review/state.py`:

```python
"""State dirs, prior-recommendation derivation, and carry-over ledger validation.
Behavioral port of Get-StateDir (doc mode), Get-PriorRecommendations,
Test-CarryOverLedger, and ConvertTo-CarryOverText (lib.ps1)."""
from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass
from pathlib import Path

from gauntlet_review.verdict import recommendation_id

_TOPIC_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}$")
_DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
_VALID_STATUS = {"addressed", "disputed", "outstanding"}
_MATCH_FIELDS = ("severity", "location", "issue", "suggestion")


def doc_state_dir(repo_root, topic: str, phase: str, date: str) -> Path:
    """docs/superpowers/reviews/{date}-{topic}/{phase}, validated and created."""
    if not _TOPIC_RE.match(topic):
        raise ValueError(f"invalid topic '{topic}'")
    if not _DATE_RE.match(date):
        raise ValueError(f"invalid date '{date}'")
    if phase not in ("spec", "plan"):
        raise ValueError(f"invalid phase '{phase}'")
    root = Path(repo_root) / "docs" / "superpowers" / "reviews"
    d = (root / f"{date}-{topic}" / phase).resolve()
    if os.path.commonpath([str(d), str(root.resolve())]) != str(root.resolve()):
        raise ValueError("state path escapes its root")
    d.mkdir(parents=True, exist_ok=True)
    return d


def prior_recommendations(state_dir, up_to_round: int) -> list[dict]:
    """Every recommendation from every canonical verdict in rounds 1..up_to_round-1."""
    state_dir = Path(state_dir)
    out: list[dict] = []
    for r in range(1, up_to_round):
        f = state_dir / f"round-{r}-verdict.json"
        if not f.exists():
            continue
        verdict = json.loads(f.read_text(encoding="utf-8"))
        for i, rec in enumerate(verdict.get("recommendations", [])):
            out.append(
                {
                    "id": recommendation_id(r, i, rec),
                    "round": r,
                    "severity": rec["severity"],
                    "location": rec["location"],
                    "issue": rec["issue"],
                    "suggestion": rec["suggestion"],
                }
            )
    return out


@dataclass
class LedgerResult:
    valid: bool
    reason: str | None
    entries: list[dict] | None
    derived: list[dict] | None


def _bad(reason: str) -> LedgerResult:
    return LedgerResult(False, reason, None, None)


def validate_carryover_ledger(state_dir, round_num: int, ledger_path) -> LedgerResult:
    """Every prior recommendation must appear exactly once with a status; nothing
    invented; copied text byte-identical; a non-addressed item carries a reason."""
    derived = prior_recommendations(state_dir, round_num)
    ledger_path = Path(ledger_path)
    if not ledger_path.exists():
        return _bad(
            f"carry-over ledger not found at {ledger_path} "
            f"({len(derived)} prior recommendation(s) require one)"
        )
    try:
        ledger = json.loads(ledger_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        return _bad(f"ledger is not valid JSON: {exc}")
    if not isinstance(ledger, dict):
        return _bad("ledger JSON must be an object")
    version = ledger.get("version")
    if isinstance(version, bool) or version != 1:  # True == 1 in Python, so reject bool explicitly
        return _bad(f"unsupported ledger version '{version}'")
    round_val = ledger.get("round")
    if round_val is None:
        return _bad("ledger is missing 'round'")
    if not isinstance(round_val, int) or isinstance(round_val, bool):
        return _bad(f"ledger 'round' is not a valid integer: '{round_val}'")
    if round_val != round_num:
        return _bad(f"ledger is for round {round_val}, invoked for round {round_num}")

    entries = ledger.get("entries")
    if entries is None:
        entries = []
    if not isinstance(entries, list):
        return _bad("ledger 'entries' must be an array")
    for e in entries:
        if not isinstance(e, dict):
            return _bad("ledger entry is not an object")
        if not (isinstance(e.get("id"), str) and e["id"]):
            return _bad("ledger entry is missing a string 'id'")

    ids = [e["id"] for e in entries]
    dupes = sorted({i for i in ids if ids.count(i) > 1})
    if dupes:
        return _bad(f"duplicate ledger entries: {', '.join(dupes)}")
    derived_ids = [d["id"] for d in derived]
    missing = [i for i in derived_ids if i not in ids]
    if missing:
        return _bad(f"OMITTED prior recommendation(s): {', '.join(missing)}")
    unknown = [i for i in ids if i not in derived_ids]
    if unknown:
        return _bad(f"ledger invents unknown recommendation(s): {', '.join(unknown)}")

    by_id = {d["id"]: d for d in derived}
    for e in entries:
        d = by_id[e["id"]]
        for field in _MATCH_FIELDS:
            if e.get(field) != d[field]:
                return _bad(f"entry '{e['id']}' does not match the canonical verdict text (mutation)")
        status = e.get("status")
        if not isinstance(status, str) or status not in _VALID_STATUS:  # str check first: a list status would raise TypeError on `in`
            return _bad(f"entry '{e['id']}' has invalid status '{status}'")
        if status != "addressed" and not (isinstance(e.get("reason"), str) and e["reason"].strip()):
            return _bad(f"entry '{e['id']}' is '{status}' but carries no reason")

    return LedgerResult(True, None, entries, derived)


def render_carryover_text(entries: list[dict]) -> str:
    """The PRIOR ROUNDS block, rendered from the validated ledger. Sorted by id."""
    if not entries:
        return ""
    lines = [
        "== PRIOR ROUNDS (trusted) ==",
        "Each item below is a recommendation you made in an earlier round, with what",
        "happened to it. Verify each was genuinely addressed. Do not re-open a settled",
        "point without new evidence.",
    ]
    for e in sorted(entries, key=lambda x: x["id"]):
        lines.append(f"- [{e['id']}] ({e['severity']}) {e['location']} — {e['issue']}")
        lines.append(f"  you asked for: {e['suggestion']}")
        reason = e.get("reason")
        suffix = f" — {reason}" if reason else ""
        lines.append(f"  status: {e['status']}{suffix}")
    lines.append("")
    return "\n".join(lines) + "\n"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python -m pytest tests/test_state.py -v`
Expected: PASS (18 tests).

- [ ] **Step 5: Run the full Phase-1 suite and commit**

Run: `python -m pytest -v`
Expected: PASS (all Phase-1 tests green).

```bash
git add gauntlet-review/python/gauntlet_review/state.py gauntlet-review/python/tests/test_state.py
git commit -m "feat(py): state dir + prior recommendations + carry-over ledger validation"
```

---

## Roadmap: Phases 2–5 (task outlines, full plans to follow)

These are captured so the whole shape is visible; each becomes its own plan document with complete TDD code before implementation.

**Phase 2 — Container image + sandbox + broker (needs Docker).**
- `Dockerfile` + entrypoint wrapper: pinned Codex CLI, non-root/arbitrary-UID image, in-container watchdog with an absolute deadline, blocks-on-marker so the tmpfs verdict survives copy-out.
- `sandbox.py`: build the `run` argv; create-with-cidfile (no `--rm`); private PID/IPC/UTS/cgroup namespaces, `--cap-drop ALL`, `no-new-privileges`, `--read-only`, `--log-driver=none`, `--pids-limit`, limits; size-bounded `docker cp -` verdict retrieval; bounded stream capture with per-channel + aggregate limits; run-as invoking host UID/GID with userns-remap/idmapped-mount handling; per-run lease; reaper that acquires the lease + re-inspects run id before touching a container.
- `broker.py`: host-side `~/.codex` owner; prefer a non-rotating token exchange; stage access-only `auth.json` + `AGENTS.md` from `O_NOFOLLOW` fds; verify staged `AGENTS.md` bytes against `agents_md_sha256`; interprocess lock + fsync-atomic, generation-checked persistence; require token remaining lifetime ≥ deadline + margins or fail closed.

**Phase 3 — Premises/evidence + policy validator + entry point (needs Docker + model).**
- `premises.py`: the manifest (`image_config_digest`, `platform_manifest_digest?`, `os_arch`, `codex_version_in_image`, `schema_sha256`, `agents_md_sha256`, `host_impl_digest`, `python_runtime_fingerprint`, `container_invocation_profile_hash`, `live_evidence{schema_gate, security_battery}`); the canonical *semantic* invocation profile (typed placeholders for per-run values); the **non-self-calibrating policy validator** asserting every mandatory value before evidence/round; the closed `host_impl_digest` file set; image-identity pinning + `--accept-new-image`.
- `invoke_codex.py`: one round — pin check → stage credential → run → usage gate → normalize/validate verdict → create-only canonical artifacts; the shared exit-code contract (0/10/11/12/13/14/16).

**Phase 4 — Publisher (needs `gh`).**
- `publish.py` + `state.py` pr-mode paths: provenance binding (checked first, locally), idempotency (`--paginate --slurp`), four-field drift, commit-pinned REST publish, post-publication verification + dismissal, the review marker, `publication.json`.

**Phase 5 — Live battery + installer + dispatch (needs Docker + model).**
- Container security battery (tool-denial control-verification inside the image, runtime-qualified mount/socket allowlist, host-PID same-UID canary, all-output-channel secret audit, control-reachability preconditions, policy-validator negative tests, image-pin refusal).
- `install.py`/`install.sh`: transactional fail-closed bootstrap (stage immutable artifact → offline suite → invalidate + both live gates → revalidate manifest → atomic versioned-sibling install + symlink flip with `F_FULLFSYNC` durability → atomic `CLAUDE.md` update).
- `SKILL.md` platform branch: resolve `current` once (`realpath`), thread the concrete path; Windows → `pwsh`, Unix → the pinned Python interpreter.

## Self-Review (Phase 1)

**Spec coverage (Phase-1 scope):** ✅ canonical serialization (RFC 8785) — Task 1; ✅ identical id derivation with authoritative vectors — Task 2; ✅ verdict normalization + severity invariant + size bounds — Task 3; ✅ acceptance-time usage gate (fails closed) — Task 4; ✅ default-deny feature policy — Task 5; ✅ state dir + prior recommendations + carry-over ledger — Task 6. Container/broker/premises/publish/battery/installer are explicitly deferred to Phases 2–5 (roadmap above).

**Placeholder scan:** none — every code and test step contains complete, runnable content.

**Type consistency:** `recommendation_id(round_num, index, rec)` defined in Task 2 is consumed with the same signature in Task 6; `normalize_verdict` / `parse_run_usage` / `disable_set` / `validate_carryover_ledger` return the dataclasses named in their Interfaces blocks; `jcs.canonical` (Task 1) is consumed in Task 3. Golden id vectors in Task 2 are authoritative (captured from the PowerShell `Get-RecommendationId`).
