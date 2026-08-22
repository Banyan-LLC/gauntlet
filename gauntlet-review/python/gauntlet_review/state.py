"""State dirs, prior-recommendation derivation, and carry-over ledger validation.
Behavioral port of Get-StateDir (doc mode), Get-PriorRecommendations,
Test-CarryOverLedger, and ConvertTo-CarryOverText (lib.ps1)."""
from __future__ import annotations

import json
import os
from dataclasses import dataclass
from pathlib import Path
import re

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
