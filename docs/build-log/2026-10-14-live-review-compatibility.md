# Live review compatibility and cleanup reconciliation

The RetroSeq Plan 3 review encountered three independent compatibility failures on Codex
0.162.0-alpha.17.2: synthetic repository setup attempted a needless Git commit; a generic MCP event
triggered the computer-use narrowed-class assertion without retained tool identity; and a profile with roughly
3,000 entries exhausted the original ten-second native cleanup deadline. The failed battery did
not certify security. Its exact owned temporary credential tree was subsequently removed and
independently verified absent after all model process trees retired.

This change starts from merged main at 79694bf in a clean worktree. It ports the owned-directory
setup regression without replacing main's newer failed-control diagnostic retention and credential
redaction. A provisional six-class promotion was withdrawn after source and live investigation;
the approved five-required/three-unproven split is preserved. Positive detection, hermetic absence
and pairwise isolation remain required for every proved class, with no novel-event exclusions.

Security cleanup now receives one finite 60-second budget for the entire attempt. Schema and
empty harness cleanup remain bounded by ten seconds. There is no automatic retry or pathname
deletion fallback. Only an explicit retry after the original worker physically settles can
reconcile original custody. Failed cleanup permanently fences producers and credential readers.
Successful native delete disposition is recorded before the next deadline observation; pending
producer entries and the root finish through their original handles before inventory. A removed
root receives an absence check only, refusing any replacement. Disposal intent irreversibly
blocks admission and schedules handle closure once, after the actual worker settles.

Independent review found three retry/disposal gaps in the first revision. Deterministic tests
using an isolated in-memory initializer delay at the native disposition boundary reproduced
root and child disposition loss, cleanup admission during deferred disposal, and revival of
producers/readers after a sharing-violation retry. They failed with 8 passed / 7 failed before
the corrections, then passed 15 / 0. No production test hook was introduced.

Review also found that deferred handle closure could run synchronously after the observer's
deadline. An actual Inspect scheduling regression reproduced that gap (21/1) and passes after
the observer schedules release asynchronously (22/0). Standalone disposal preserves its
immediate no-worker release; the bounded observer never performs native closure inline.

Other red/green regressions cover capability-policy assertions (the provisional 5/4 to 9/0;
corrected provenance/default-deny regression 7/4 to 11/0), failed-attempt
reconciliation and a 3,072-entry dummy profile (3/5 to 8/0), and directory-only security setup
(8/1 to 20/0). Fixtures contain dummy bytes only. Independent fix review has no remaining
actionable source findings. The complete offline suite passed 1,384 assertions across 15 test
files, zero failures, on the final native source. The live schema gate passed 14/0.

The first corrected security run passed 138 assertions and failed two: computer-use produced
no real tool event, leaving the verified class set incomplete. Its private redacted diagnostic
showed a guessed obsolete namespace followed by TypeError, rather than a provider invocation.
The failed run was retained and did not stamp security evidence. All owned process trees retired;
native cleanup completed, and independent no-follow stat verified its exact credential root
absent. The control prompt now requires current registered tool metadata and a genuine read-only
provider invocation; narration, discovery alone and missing-function errors remain insufficient.
The corrected prompt also failed to establish a real invocation in the next run (138/2);
its model response reports no registered entrypoint, with no native tool events. Both failures
remain retained; both exact credential roots were independently verified absent. The user explicitly
authorized one read-only screen probe, but no screen read occurred. No failed run is treated as green.

Independent source review against the selected CLI's exact public tag, rust-v0.162.0-alpha.17.2
(commit 740e5af33c71225640e0c1c1555c514c2c93ab74), closed the provenance issue. The
[feature declaration](https://github.com/openai/codex/blob/740e5af33c71225640e0c1c1555c514c2c93ab74/codex-rs/features/src/lib.rs)
describes computer-use as a requirements-only policy gate; enabling it does not establish provider
registration. A machine-only owned-profile probe of debug prompt-input made no model/UI call,
but is not an authoritative roster: [prompt_debug.rs](https://github.com/openai/codex/blob/740e5af33c71225640e0c1c1555c514c2c93ab74/codex-rs/core/src/prompt_debug.rs)
returns prompt.input, while tools occupy a separate field. Its omission cannot prove absence.
The defensible claim remains configured off and independently unproven. The original ambiguous
server event is retained as ambiguous, not reclassified as proven computer use. Default-deny,
the independent eight-class universe and every strict narrowed/positive/negative/pairwise guard
remain unchanged. Native dispatch logging includes server/tool names only, never arguments or images.
Final security certification passed 142 assertions with zero failures. The schema gate then passed 14/0 again against the same final stack fingerprint; both live records are current. Independent no-follow checks verified every exact owned credential root from these runs and the machine-only probe absent after retirement.

The following provisional ruling is superseded by the final ruling below.

Ruling: require computer-use alongside the existing five proved classes · the current CLI exposes a distinct event and narrowing it would hide an observable surface · cost if wrong: refuse certification until a valid independent control is available.

Ruling: allow one finite 60-second security cleanup attempt and only explicit settled reconciliation · real profiles exceed the former ten-second limit, while unresolved native ownership cannot be replaced · cost if wrong: retained custody and a failed gate instead of unverified credential-removal claims.

Ruling: preserve main's diagnostic retention/redaction and keep failure evidence private · the failed positive control requires an actual explanation without publishing credential-bearing raw output · cost if wrong: stop certification and inspect the protected redacted record.


Ruling: withdraw the unsupported six-class promotion and preserve five proved/three unproven classes · a generic server event lacks computer-use provenance and repeated headless controls established no real invocation · cost if wrong: any newly observed narrowed-class event fails the unchanged gate and requires investigation before promotion.

Final offline verification covers all 15 test files and 1,386 assertions with zero remaining failures. The first final suite run passed 1,385 and failed one premises-file immutability assertion because this operator concurrently ran a live gate that legitimately stamps that file. With all live writers stopped, the unchanged test-invoke.ps1 passed all 334 assertions in isolation. The other 14 files passed on the same final source. The interference run and isolated rerun remain retained; it is not reported as an initially green run.

Ruling: serialize live evidence writers and the invocation immutability suite · both intentionally inspect the real premises manifest, and concurrent stamping invalidates the isolation assertion · cost if wrong: rerun the affected suite with a quiescent manifest before publication.
