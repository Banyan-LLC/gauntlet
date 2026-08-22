"""State dirs, prior-recommendation derivation, and carry-over ledger validation.
Behavioral port of Get-StateDir (doc mode), Get-PriorRecommendations,
Test-CarryOverLedger, and ConvertTo-CarryOverText (lib.ps1).

Confinement is handle-backed: `doc_state_dir` returns a `StateDir` that retains an
open descriptor to the final directory and performs all artifact I/O relative to it
with no-follow semantics, so a symlink swap after creation cannot redirect reads or
writes outside the directory. Pathnames are display-only.

Confinement scope (narrowed, explicit): this defends against symlinked path components
at creation/open time. It does NOT defend against a concurrent local attacker who
*renames* the state directory (or an ancestor) out of the repository mid-run — a
retained directory fd tracks the inode, so subsequent no-follow I/O would follow it to
its new location. Portable atomic anti-rename confinement is not available; a deployment
that requires it must place state under a trusted, non-renamable root. This matches the
semi-trusted nature of the working repository (the state dir lives in the user's own
checkout / git dir, not in attacker-controlled space)."""
from __future__ import annotations

import json
import os
from dataclasses import dataclass
from pathlib import Path
import re

from gauntlet_review.verdict import recommendation_id

_POSIX_NOFOLLOW = os.name == "posix" and hasattr(os, "O_NOFOLLOW") and hasattr(os, "O_DIRECTORY")


def _reject_constant(name):  # NaN / Infinity / -Infinity are not valid JSON
    raise ValueError(f"non-JSON constant {name}")


_TOPIC_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}$")
_DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
_VALID_STATUS = {"addressed", "disputed", "outstanding"}
_MATCH_FIELDS = ("severity", "location", "issue", "suggestion")


class StateDir:
    """A retained handle to a state directory. On POSIX it holds an open directory fd
    and performs artifact reads (and, in later phases, create-only writes) relative to
    it with O_NOFOLLOW, so a symlink swapped in after creation cannot redirect I/O
    outside the directory, and there is no TOCTOU gap between lookup and use. Elsewhere
    it falls back to path-based access with per-file symlink rejection. `path` is for
    display/logging only — never re-derive I/O targets from it."""

    def __init__(self, path, dir_fd):
        self._path = Path(path)
        self._dir_fd = dir_fd  # int on POSIX; None on the fallback
        self._posix = dir_fd is not None  # backend selector, FIXED at construction (not `_dir_fd is None`)
        self._closed = False

    @property
    def path(self) -> Path:
        return self._path

    @classmethod
    def open(cls, path) -> "StateDir":
        """Open a handle to an EXISTING state directory. The final component is opened
        with O_NOFOLLOW so a symlinked state directory is rejected. The PARENT chain is
        assumed trusted here — for an untrusted root, obtain the handle from
        `doc_state_dir`, which traverses every component no-follow from the repo root."""
        path = Path(path)
        if _POSIX_NOFOLLOW:
            return cls(path, os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW))
        return cls(path, None)

    def read_text(self, name: str) -> str:
        """Read a file directly inside this directory (single path component), never
        following a symlink. Raises FileNotFoundError if absent."""
        if self._closed:
            raise ValueError("StateDir is closed")
        if "/" in name or "\\" in name or name in ("", ".", ".."):
            raise ValueError(f"state file name must be a single component: {name!r}")
        if self._posix:
            fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=self._dir_fd)
            with os.fdopen(fd, "r", encoding="utf-8") as fh:
                return fh.read()
        p = self._path / name
        if p.is_symlink():
            raise ValueError(f"refusing to read symlinked state file: {name}")
        return p.read_text(encoding="utf-8")

    def close(self) -> None:
        if self._posix and self._dir_fd is not None:
            try:
                os.close(self._dir_fd)
            except OSError:
                pass
        self._dir_fd = None
        self._closed = True  # subsequent operations RAISE — never silently fall back to path I/O

    def __enter__(self) -> "StateDir":
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    def __del__(self):
        self.close()


def _open_state_dir_nofollow_posix(repo_root: Path, components: list[str]) -> int:
    """Create/traverse each component relative to its parent's fd with O_NOFOLLOW and
    RETURN the still-open final directory fd (caller owns it). A symlinked component
    fails the O_NOFOLLOW open (ELOOP) and is rejected before anything is written under
    it, and no symlink is ever followed. Handle-continuous: not TOCTOU-defeatable."""
    fds = [os.open(repo_root, os.O_RDONLY | os.O_DIRECTORY)]
    keep = None
    try:
        for part in components:
            try:
                os.mkdir(part, dir_fd=fds[-1])
            except FileExistsError:
                pass
            try:
                fds.append(os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fds[-1]))
            except OSError as exc:  # ELOOP when the component is a symlink
                raise ValueError(f"refusing to traverse symlinked path component: {part}") from exc
        keep = fds.pop()  # the final dir fd stays open and is returned
        return keep
    finally:
        for fd in fds:
            try:
                os.close(fd)
            except OSError:
                pass


def _create_dirs_checked(repo_root: Path, components: list[str]) -> Path:
    """Cross-platform fallback: reject any symlinked component BEFORE creating under it,
    so no write escapes the repository (no O_NOFOLLOW/dir_fd on this platform)."""
    base = repo_root
    for part in components:
        nxt = base / part
        if nxt.is_symlink():
            raise ValueError(f"refusing to traverse symlinked path component: {nxt}")
        if nxt.exists():
            if not nxt.is_dir():
                raise ValueError(f"path component is not a directory: {nxt}")
        else:
            os.mkdir(nxt)
        base = nxt
    return base.resolve()


def doc_state_dir(repo_root, topic: str, phase: str, date: str) -> StateDir:
    """docs/superpowers/reviews/{date}-{topic}/{phase}, validated and created, returned
    as a handle-backed StateDir. No symlink is ever followed during creation, and the
    returned handle keeps confinement through subsequent I/O (POSIX)."""
    if not _TOPIC_RE.match(topic):
        raise ValueError(f"invalid topic '{topic}'")
    if not _DATE_RE.match(date):
        raise ValueError(f"invalid date '{date}'")
    if phase not in ("spec", "plan"):
        raise ValueError(f"invalid phase '{phase}'")
    repo_root = Path(repo_root)
    components = ["docs", "superpowers", "reviews", f"{date}-{topic}", phase]
    if _POSIX_NOFOLLOW:
        fd = _open_state_dir_nofollow_posix(repo_root, components)
        return StateDir(repo_root.joinpath(*components).resolve(), fd)
    path = _create_dirs_checked(repo_root, components)
    return StateDir(path, None)


def prior_recommendations(state_dir: StateDir, up_to_round: int) -> list[dict]:
    """Every recommendation from every canonical verdict in rounds 1..up_to_round-1,
    read no-follow through the state-dir handle."""
    out: list[dict] = []
    for r in range(1, up_to_round):
        try:
            text = state_dir.read_text(f"round-{r}-verdict.json")
        except FileNotFoundError:
            continue
        verdict = json.loads(text, parse_constant=_reject_constant)
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


def validate_carryover_ledger(state_dir: StateDir, round_num: int, ledger_path) -> LedgerResult:
    """Every prior recommendation must appear exactly once with a status; nothing
    invented; copied text byte-identical; a non-addressed item carries a reason.
    `ledger_path` is the caller-supplied ledger file (external to the state dir)."""
    derived = prior_recommendations(state_dir, round_num)
    ledger_path = Path(ledger_path)
    if not ledger_path.exists():
        return _bad(
            f"carry-over ledger not found at {ledger_path} "
            f"({len(derived)} prior recommendation(s) require one)"
        )
    try:
        ledger = json.loads(ledger_path.read_text(encoding="utf-8"), parse_constant=_reject_constant)
    except ValueError as exc:  # JSONDecodeError is a ValueError; also catches _reject_constant (NaN/Infinity)
        return _bad(f"ledger is not valid JSON: {exc}")
    if not isinstance(ledger, dict):
        return _bad("ledger JSON must be an object")
    version = ledger.get("version")
    if not isinstance(version, int) or isinstance(version, bool) or version != 1:  # reject bool and float 1.0
        return _bad(f"unsupported ledger version '{version}'")
    round_val = ledger.get("round")
    if round_val is None:
        return _bad("ledger is missing 'round'")
    if not isinstance(round_val, int) or isinstance(round_val, bool):
        return _bad(f"ledger 'round' is not a valid integer: '{round_val}'")
    if round_val != round_num:
        return _bad(f"ledger is for round {round_val}, invoked for round {round_num}")

    entries = ledger.get("entries")
    if not isinstance(entries, list):  # missing, null, or non-list all fail closed
        return _bad("ledger 'entries' must be a present array")
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
        reason = e.get("reason")
        if reason is not None and not isinstance(reason, str):
            return _bad(f"entry '{e['id']}' has a non-string reason")
        if status != "addressed" and not (isinstance(reason, str) and reason.strip()):
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
