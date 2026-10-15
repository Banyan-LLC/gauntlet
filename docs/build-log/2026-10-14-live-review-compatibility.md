# Live review compatibility and cleanup reconciliation

The RetroSeq Plan 3 review encountered three independent compatibility failures on Codex
0.162.0-alpha.17.2: synthetic repository setup attempted a needless Git commit; computer-use
produced a distinct event despite remaining on the narrowed list; and a profile with roughly
3,000 entries exhausted the original ten-second native cleanup deadline. The failed battery did
not certify security. Its exact owned temporary credential tree was subsequently removed and
independently verified absent after all model process trees retired.

This change starts from merged main at 79694bf in a clean worktree. It ports the owned-directory
setup regression without replacing main's newer failed-control diagnostic retention and credential
redaction. Computer-use joins the five already required controls; skill-search and subagent
spawning remain explicitly narrowed. Positive detection, hermetic absence and pairwise isolation
are still required for every proved class.

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

Other red/green regressions cover six-class capability policy (5/4 to 9/0), failed-attempt
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
Capability/setup regressions passed again after that prompt-only correction. Security certification
and document review remain pending the corrected live control. No failed run is treated as green.

Ruling: require computer-use alongside the existing five proved classes · the current CLI exposes a distinct event and narrowing it would hide an observable surface · cost if wrong: refuse certification until a valid independent control is available.

Ruling: allow one finite 60-second security cleanup attempt and only explicit settled reconciliation · real profiles exceed the former ten-second limit, while unresolved native ownership cannot be replaced · cost if wrong: retained custody and a failed gate instead of unverified credential-removal claims.

Ruling: preserve main's diagnostic retention/redaction and keep failure evidence private · the failed positive control requires an actual explanation without publishing credential-bearing raw output · cost if wrong: stop certification and inspect the protected redacted record.
