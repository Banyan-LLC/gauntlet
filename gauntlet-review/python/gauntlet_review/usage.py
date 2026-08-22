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
