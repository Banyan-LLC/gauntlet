# Global collaborative registration

Every server process takes one immutable operator tuple (checkout, ref pair,
repository ID, state directory, participant), so each review needed its own
hand-written host entry, keyed to the folder a session starts in. A session
opened in a new branch or worktree had no Gauntlet tools until someone wrote one,
and a Claude Code session started before that could not load them at all. The
owner asked for Gauntlet to work from every project, as the skills already do.

`gauntlet_review.launch` is a host-side launcher. Started by the host in the
session's working folder, it derives that session's tuple with dulwich (the
checkout, its checked-out branch, origin's default branch, `<owner>-<repository>`
from origin's URL), keeps one private state directory per checkout and ref pair
under a state root (the name's digest covers the checkout path, the ID and both
refs, so no store is ever rebound), and then runs the unchanged server entry point
in the same process. Refusals print one fixed code, like the core's; details go to
a bounded `launch.log` under the state root. The core, the adapter, their
validation and the store are unchanged: every process still has exactly one tuple,
fixed at start, which no MCP client can change.

`install.ps1` now registers `gauntlet-core` and `gauntlet-peer` once, at Claude
Code's user scope, as `python -I -m gauntlet_review.launch core|peer --state-root
<root>` from the collaborative venv. It replaces earlier user-scope entries with
those names, skips with a warning when `claude`, the venv or the launcher is
missing, and takes `-SkipMcpRegistration`, `-McpPython` and `-StateRoot`. Project
and local entries with the same names keep precedence, which leaves reviews bound
to an earlier explicit tuple on their existing stores.

## Verification

- `tests/collaborative/test_launch.py`, 17 tests on fixture repositories built
  with `git`: the derived tuple from a subfolder, a linked worktree with its own
  branch, distinct stores for branches with the same slug, `origin/HEAD` naming
  the target, repository IDs from three URL forms and the folder fallback,
  refusals for a non-Git folder, a detached HEAD, no origin default branch and a
  state root inside the checkout, private creation (no inherited ACL entries on
  Windows, `0700` elsewhere) and a redirected component, and `main` handing the
  exact arguments to each server and refusing with a fixed code.
- Windows, Python 3.14.6: `tests/collaborative`, `tests/test_entrypoint.py` and
  `tests/test_optional_install.py`, 276 passed and 3 skipped.
- Before this change, the same derivation (as a stand-alone script) was started
  directly in one repository and, registered at user scope on the owner's machine,
  through `claude mcp get` from another; each bound to its own checkout and branch,
  and a non-Git folder was refused.

## Review round 1 (PR 16)

The first review requested five changes, all made in one update:

- **F1, a redirected state root.** `derive()` resolved `--state-root`, so a junction or
  symbolic link root (or ancestor) was silently followed and nothing redirected remained for
  the core to refuse. The root is now never resolved: every existing component is checked with
  `lstat` (no link, no reparse point, a directory) before anything is created or logged, and the
  unresolved path is handed to the core. Regressions: `main` and `derive` with a junction
  (Windows) or link as the root and as an ancestor refuse with `REDIRECTED_STATE_COMPONENT`,
  and the target folder stays empty (no state, no log).
- **F2, losing registrations.** Registration moved to `mcp-registration.ps1`
  (`Register-GauntletMcp`). It reads both current user-scope definitions before changing
  anything and, if any remove or add fails, puts both names back exactly as they were.
  Regressions in `tests/test-install-registration.ps1`, with a stub `claude` that keeps its
  own store: a failure at each of the four mutations restores both originals (environment
  included) and leaves other settings alone; with no previous entries a failed second add
  leaves no half pair.
- **F3, a relative interpreter.** `-McpPython` is resolved to an absolute path before the
  check, the state-root default or any mutation. Regression: a relative path registers an
  absolute command that resolves from another folder.
- **F4, uncontained startup errors.** Expected setup failures map to fixed codes
  (`STATE_UNAVAILABLE` for `OSError`, `STATE_NOT_PRIVATE` for `icacls` and subprocess
  failures), unexpected ones to `INTERNAL_ERROR` with a correlation ID; stderr carries the
  code only, details go to the log, and a failed cleanup is logged without replacing the
  original error. Regressions inject `PermissionError`, `TimeoutExpired`,
  `FileNotFoundError`, an unexpected `RuntimeError` and a failing `rmdir`.
- **F5, unchecked pins.** `python -m gauntlet_review.launch check` runs both servers'
  `_require_extra()` checks (exact pins) and starts nothing; `Register-GauntletMcp` runs it in
  the selected interpreter before any host change. Regressions: the check passes with the
  pinned extras and reports `MISSING_EXTRA` and `UNSUPPORTED_EXTRA` with stubbed metadata; a
  failing check in the installer changes nothing.

Run against the round-0 launcher, 10 of the new launcher tests fail (both redirect cases, the
containment cases, the cleanup case and the `check` cases); against this update all 28 pass.
`tests/test-install-registration.ps1`: 43 assertions pass.
