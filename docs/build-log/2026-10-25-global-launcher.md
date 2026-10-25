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
