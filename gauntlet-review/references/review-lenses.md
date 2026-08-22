# Review lenses (anti-churn)

The Gauntlet reviewer (gpt-5.6-sol xhigh) is adversarial and deep. Left to a bare "review this
diff" prompt it surfaces defects a **layer at a time**: it fixes attention on whatever the last
change touched, reports the shallowest defect there, and only on the *next* round — after your fix
exposes the next layer — reports the one beneath it. PR #2 took **7 rounds** this way; one defect
*class* (bounded-runner stream/process safety) unfolded across **eight** rounds:

> overflow-kill(stdout/stderr) → aggregate cap → immediate-during-stdin → cleanup grace →
> tree-kill → stdin-only descendant → pgid race → aggregate-retention regression → no-follow handles

That churn is not the reviewer withholding — it reports every defect it *sees* each round. It is
**emergent depth**: narrow, instance-level fixes keep revealing the next instance of the same
class. Two counters, applied together, collapse ~7 rounds into ~2–3:

1. **Pre-harden with these lenses BEFORE the gate** (gauntlet-dev pre-review), so the first
   submission already clears most of them — spend cheap local subagents, not paid Codex rounds.
2. **Direct the reviewer to apply ALL lenses and report the whole CLASS each round** (embedded in
   the prompt template), so a class is surfaced in one round instead of unfolded over six.

What no prompt can do: make round 1 find a defect in code a *later fix* introduces (the round-6
aggregate-retention regression did not exist in round 1). Those still cost a round — so also
**run your own tests + a regression scan before every push**, and never submit a fix you have not
exercised.

## The two meta-rules (apply to every lens below)

- **Fix/report the CLASS, not the instance.** Treat each finding as one representative. Before
  fixing, enumerate every sibling: the same defect in the other stream/channel/path/platform, at
  every call site, on every branch. Fix them all in one pass. A fix that resolves only the exact
  line reported is a fix that guarantees another round.
- **Audit the whole SUBSYSTEM a change touches**, not just the changed lines. A diff draws the
  reviewer's full scrutiny to the file/seam it lands in; get there first.

## The lenses

Each names what to check, then the class to expand it into. The parenthetical is the PR-#2 round
where it first bit — evidence these are what this reviewer actually applies, not speculation.

1. **Fail-closed on unverified or partial state.** Never proceed on a result that was not
   confirmed complete and successful. *Class:* every branch that consumes a result first checks
   start-failure, error, partial delivery, failed/oversized copy-out, and unconfirmed removal;
   output derived from incomplete input is discarded, not accepted. (r1 `run_round` ignored
   `start_failed`; r2 incomplete stdin accepted a verdict from a prefix; r3 failed copy-out;
   r4 crash between staging and container creation.)

2. **Resource bounds & lifecycle (concurrency/process).** *Class, enumerate exhaustively:* every
   output stream capped **per-channel AND in aggregate**, and the cap bounds **retained bytes**,
   not just a threshold; crossing any cap **terminates immediately**, not at the deadline; ONE
   shared deadline bounds every wait AND all cleanup (reaps, joins, fallback subprocess calls —
   none unbounded); termination kills the whole process **tree** (group/job), and works after the
   direct child exits; a descendant that inherits **any** pipe (stdout, stderr, *or* stdin) is
   still reaped; cleanup is guaranteed on every path including unexpected exceptions; a
   BufferedReader/Writer is never closed under an active worker. (rounds 1–6, the eight-layer
   cascade above.)

3. **Path & filesystem safety.** *Class:* every path built from external or enumerated input is
   opened no-follow (POSIX `O_NOFOLLOW`; elsewhere `lstat`-and-reject, incl. **intermediate**
   components); no `unlink`/`rmtree` through a symlink or an unvalidated entry; identifiers are
   validated against their exact generated format before any filesystem action on them; `ENOENT`
   is distinguished from other stat errors (a permission error is not "absent"); removal is
   verified, and unlink/rmtree errors are captured, not swallowed. (r3/r5 broker no-follow;
   r5 reaper deleting unrelated dirs; r6/r7 symlinked staging entry & swallowed errors.)

4. **Cross-platform parity — name the production platform.** State which platform runs in
   production, make **it** robust and tested, and make the other explicitly best-effort **and
   documented**; guard platform-specific syscalls so imports/tests pass everywhere. A dispute
   sticks only when the production boundary is explicit: PR #2's two Windows-only findings were
   **accepted and dropped** once "this container path runs on Unix/macOS; Windows uses the
   PowerShell stack" was stated as the boundary. (r3/r4.)

5. **Typed & structured errors / API completeness.** *Class:* a domain failure raises a **typed**
   exception (not a bare `ValueError`), so a caller can map it; a function that can partially fail
   returns a **structured** result (not `list[str]` / `str | None`) preserving the underlying
   errors, so a caller can act on the partial outcome. (r5 `ImageIdentityMismatch`; r7 structured
   reaper result.)

6. **Spec conformance, line by line.** Every explicit requirement in the controlling spec — every
   "MUST", every "corrects round-N" amendment — has a **complete** implementation, not a partial
   one. Diff the code against the spec's own words before the first review. (r1's blocking finding
   was spec lines 144–148: per-channel **and aggregate** bounds with **immediate** termination,
   only partially implemented.)

## How this file is used

- **gauntlet-dev pre-review gate** (before any Codex gate): one subagent per lens over the changed
  files/artifact; aggregate; fix by class; only then invoke `gauntlet-review`. Local and cheap.
- **gauntlet-review prompt** embeds a condensed form of lenses 1–6 + the class rule (the reviewer
  is hermetic and cannot read this file), directing it to apply all lenses and report full classes
  each round.
- **Humans / receiving-code-review:** the checklist to self-audit against before claiming done.
