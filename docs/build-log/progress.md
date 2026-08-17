# Progress ledger — codex-review-loop plan (revision 9)
Task 1: complete (commits bd79ef1..28f4b20, review clean)
  Minor (for final review triage): shipped schema suite boundary-tests only maxItems(21);
  string maxLength boundaries (800/150/500/500), nested additionalProperties, and severity-enum
  rejection are verified-correct today but not guarded by a test.
  Note for T5: a .cmd shim under a fully cleared environment emits a stray "'DOSKEY' is not
  recognized" line on stderr from cmd.exe itself — the runner must NOT treat non-empty stderr
  as failure.
Task 2: complete (commits 28f4b20..e4ab9d3, review clean after 1 fix round + doc sync)
  Fixed during task: Select-CodexCli now throws with a per-candidate probe log (was paths only).
  Plan doc repaired at source twice: (a) fall-through fixture used a candidate that PASSES the
  probe since the resume probe was dropped - unsatisfiable assertion; (b) -Reason was added to
  the doc's signature without wiring the 8 rejection sites.
  Minor (final-review triage): shipped reason text repeats the path inside each reason;
  FeatureNames keeps names only (stability/enabled dropped - correct for default-deny, latent
  only if a later task needs enabled-state); two ReadToEndAsync calls sit outside the Start
  try/catch (theoretical only).
Task 3: complete (commit da48eec, review clean)
  Reviewer's "Critical" was a cannot-verify-from-diff on $script:FeatureAllowlist; resolved by
  controller - lib.ps1 line 4 holds exactly the five allowlisted names.
  Minor: brief's Step 4 predicts "12 passed", actual is 13 (comment only, test is right).
Task 4: complete (commits da48eec..19ae635, review clean after 1 test-coverage fix)
  Review found the battery could not distinguish the audit's two layers: every shipped bypass
  was caught by Layer 2 alone, so deleting Layer 1 - or weakening Layer 2 to a multiset check -
  would have shipped green. Added two discrimination tests, each proven to fail alone for its
  own reason (Layer 1: forbidden -s value agreeing with a compromised canonical builder;
  Layer 2: transposed -c values, multiset-identical, order differs).
  Minor (final triage): Layer 1 mixes case-sensitive value checks with case-insensitive
  presence checks; not exploitable (Layer 2 backstops) but inconsistent.
Task 4: complete (commits da48eec..19ae635, review clean after 1 test-coverage fix)
  Review found the battery could not distinguish the audit two layers: every shipped bypass
  was caught by Layer 2 alone, so deleting Layer 1 - or weakening Layer 2 to a multiset check -
  would have shipped green. Added two discrimination tests, each proven to fail alone.
  Minor (final triage): Layer 1 mixes case-sensitive value checks with case-insensitive
  presence checks; not exploitable (Layer 2 backstops) but inconsistent.
Task 5: complete (commits 49e144f..fae4223, review clean after 1 fix round) - suite 144/144
  Two real defects found in the PLAN CODE and fixed in both code and plan:
  (a) Test-PremiseManifest threw PropertyNotFoundException under StrictMode when premises.json
      OMITS a key - the most realistic drift - instead of failing closed. Fixed by backfilling
      absent keys as null before any are read, plus a type guard for scalar tokenizer_evidence.
  (b) The budget inequality narrowed [long]-accepted values with bare [int] casts, so an
      oversized context_window_tokens crashed instead of returning a Reason. Now [long]/[double].
  Both fixes have discrimination-proven regression tests (6 each).
Task 6: complete (commits fae4223..e66538f, review clean after 1 fix round) - suite 205/205
  THREE real defects in the PLAN CODE, all fixed in code (plan sync follows):
  (a) Test-CarryOverLedger dotted absent ledger keys under StrictMode. Worse than a crash:
      the exception is non-terminating inside the -and, so the unfixed validator FAILED OPEN -
      it accepted a "disputed" finding carrying no reason. The brief test crashed on the brief
      implementation because no constructed entry has a reason key.
  (b) Assert-HarnessSafe used StartsWith without a trailing separator, so a sibling
      harness-evil-X counted as inside harness. Now Test-PathUnderRoot; sibling case proven.
  (c) -ceq is culture-aware, not ordinal, so precomposed vs combining Unicode passed as
      "verbatim" in the ledger comparison that stops findings being reworded. Now Ordinal.
  Get-StateDir was half-migrated (bare StartsWith) - fixed too; unreachable today via its
  public params, so its regression test exercises Test-PathUnderRoot directly.
Task 7: implemented (commit 5d3c355) - suite 272/272. TASK REVIEW STILL PENDING.
  THREE real defects in the PLAN entry script, all fixed in code (plan sync follows):
  (a) bare $attempt: inside a double-quoted string is a PowerShell ParserError (parsed as a
      scope qualifier like $env:) - the whole script failed to parse. Needs ${attempt}:.
  (b) (Get-PriorRecommendations ...).Count without an outer @() throws under StrictMode for
      0 or 1 items - i.e. every round 1, the common case.
  (c) harness_dir was persisted only on final success, so a failed first attempt left nothing
      to reuse and a retry would silently mint a SECOND harness. Now recorded at creation.
  +17 self-review tests for two properties the brief never exercised: replaying a completed
  round, and the carry-over gate incl. proving Codex receives the rendered carry-over on stdin.
Task 7: COMPLETE (commits e66538f..78c16cd, review clean after 1 fix round) - suite 299/299
  Review confirmed all three plan-code defects were real; added pr-mode coverage (+27) that
  the brief never had. No implementation defect surfaced in pr mode.
  Minor (final triage): a crash between the canonical-verdict write and the following
  state.json patch leaves state.json transiently stale - replay is still correctly refused
  and carry-over reads verdict files directly, so it is cosmetic.

NEXT: Task 8 (publication/dismissal/handoff + calibrate-premises.ps1). Then 9 (SKILL.md),
  10 (LIVE smoke - BLOCKS on tokenizer evidence, see below), 11 (LIVE security), 12
  (orchestrator+installer), 13 (activation + user-gated PR e2e), 14 (final sweep).
BLOCKER for Task 10: premises.json requires tokenizer_evidence proving gpt-5.6-sol uses a
  byte-level tokenizer (the tokens<=bytes bound). No authoritative source found yet. The gate
  refuses to run without it by design - do not fabricate a source.
Branch must be renamed to a feat/ name before any push (no "claude" in pushed branch names).
Task 8: implemented (commit 0cf37f2) - suite 344/344. TASK REVIEW PENDING.
  THREE defects in the PLAN code/tests, all fixed (plan sync follows):
  (a) SAFETY-CRITICAL: Invoke-Gh used bare Process.Start(FileName=gh), which on Windows never
      consults PATHEXT - so a PATH-prepended .cmd test shim was silently bypassed for the REAL
      gh.exe. It fired once during a verbatim run (read-only, no stored auth, 404 vs a
      nonexistent repo - no mutation). Fixed with Resolve-GhInvocation using Get-Command +
      the proven Resolve-CliInvocation wrapper, in Invoke-Gh AND publish-review token lookup.
      LESSON: any test that shims an external binary via PATH must prove the shim was hit.
  (b) The scripted-gh queue advance $q[1..$q.Count] is an off-by-one that throws; the throw is
      on the assignment RHS so the queue never advances and handler 0 replays forever.
  (c) ConvertTo-ReviewBody 60,000-byte OVERSIZED threshold can never fire: the structural
      schema maxima render to ~24.6KB, so the brief oversized test could not pass. Now 20,000.
  Concern: calibrate-premises.ps1 has NO test in the plan; hand-smoke-tested only.
Task 8: COMPLETE (commit 0cf37f2, review clean) - suite 344/344. All three defects confirmed
  real by the reviewer, who also independently closed most of the calibrate-premises test gap
  (golden path proving MAX-not-last, plus 3 failure branches) against a fake CLI.
  Minor (FINAL TRIAGE - pre-existing, two unguarded call sites): Get-DisableSet returns $null
    rather than @() when every reported feature is allowlisted; New-CodexArgs -DisableSet $null
    then throws an unhandled parameter-binding error instead of a clean message. Fails before
    any Codex/gh call, so safe, but crashes where it should explain. Sites: invoke-codex.ps1
    and calibrate-premises.ps1.
  Minor: reviewer-login compare is -eq in Publish-CodexReview but -cne in Test-HandoffFresh.
  Unverified anywhere: real GitHub API pagination/field shapes; calibrate against the REAL
    Codex event-stream format; behaviour under concurrent invocation (scan->POST TOCTOU).
Task 9: implemented (commit bc04a58). TASK REVIEW PENDING.
  PROCESS NOTE: the haiku implementer reported "251 passed, 5 pre-existing failures" and blamed
  premises.json path drift. FALSE - controller re-ran every test file individually: 344/344,
  tree clean, no stray premises.json. Its self-reported cross-check (12/12 params/exit codes)
  is therefore untrusted and is being independently reviewed. Lesson: cheap models on doc tasks
  still need their EVIDENCE verified, not just their output.
Task 9: COMPLETE (commits 0cf37f2..HEAD, review clean after controller fix).
  Review confirmed the SKILL.md param/exit-code cross-check was accurate, but found TWO
  Important doc defects inherited from the plan, both fixed in SKILL.md and plan:
  (a) It told the caller to take ledger ids "from the prior canonical verdict" and implied
      Get-RecommendationId hashes the four text fields. Verdicts store NO ids, and the hash
      includes (Round, Index) - so a literally-derived id never matches and EVERY round >=2
      would be rejected at exit 16. Now directs the caller to Get-PriorRecommendations.
  (b) Exit 12 said only "human flag"; its most common cause (stale/rebound premise manifest
      after a Codex update) has a concrete fix - calibrate-premises.ps1 - never mentioned.
  Minor (final triage): SKILL.md quotes the header as "== PRIOR ROUNDS ==" but the code emits
    "== PRIOR ROUNDS (trusted) ==".
Task 8 REOPENED and re-closed (commits bdb63e6, 520460d) - suite 350/350.
  External review found two P1s the earlier task review missed:
  (a) The shim-interception test proved nothing: a regression to bare Process.Start(gh) would
      run the REAL gh, exit nonzero fast for lack of a token, and satisfy both assertions.
      Now the child PATH is restricted to the shim dir, the shim launches pwsh by absolute
      ProcessPath and writes a SENTINEL before sleeping, and the test asserts the sentinel.
      Regression is now fail-safe as well as detected.
  (b) publish-review.ps1 never forwarded -Reviewer into Publish-CodexReview, and post-verify
      checked state+commit but NOT the author. A misbound token published under the WRONG
      IDENTITY and returned success; marker recovery then ignored that review and duplicated
      it. Now: forward the param, verify the token actor via gh api user BEFORE mutation
      (exit 12), and include rv.user.login in post-verification. Reverting the author check
      reproduced the defect exactly - the wrong identity verified as success.
  Docs: body guard aligned to 20,000 in plan+spec; T13 transient drill made process-scoped
  (no machine-wide network changes); duplicated publisher exit contract deduped.
Task 12: COMPLETE (commit 8b3c663 + exit-12 doc fix) - suite 350/350.
  Installer refusal verified SAFELY two ways (scratch USERPROFILE/LOCALAPPDATA child run, and
  a direct Test-PremiseManifest call): refuses with "premises.json is absent", copies nothing.
  That refusal is CORRECT - premises cannot exist until the tokenizer evidence is settled.
  Nothing written outside the worktree; real ~/.claude/skills and CLAUDE.md untouched.
  Fixed: the orchestrator doc treated exit 12 as an unconditional human flag - the same gap
  found in Task 9 recurring one level up. Manifest-caused 12 is self-serve via
  calibrate-premises.ps1; only harness/token 12 is a human flag. Applied to doc + plan.
  Minor (final triage): the doc Handoff step summarises Test-HandoffFresh without naming its
    reviewer/marker/CI sub-checks - partial, not wrong.
Task 14 (NON-LIVE PORTION): done at commit c3abb16.
  Full suite re-verified by the controller, file by file: 26+22+168+13+51+9+61 = 350/350.
  Shipped tree complete: 2 schemas, 4 scripts (lib, invoke-codex, publish-review,
  calibrate-premises), 2 SKILL.md, install.ps1. premises.json correctly ABSENT.
  Task 14 HARD GATES all still OPEN and cannot close without the live tasks:
   1. capability-class positive controls (Task 11) - none built yet
   2. the four budget premises (Task 10) - BLOCKED, see below
   3. CODEX_HOME-only env contract for a full exec round (Task 10)

TASK 10 BLOCKER - DESIGN DECISION PENDING (user-directed, do not guess):
  Official docs confirm gpt-5.6-sol context 1,050,000 and max output 128,000, but do NOT
  establish the tokenizer family, so the tokens<=bytes premise is unproven. Do not write a
  manifest with a guessed citation.
  DIRECTED REPLACEMENT: amend the budget design to use OpenAI input-token-count endpoint
  (exact pre-inference count, accounts for request formatting/tools/schemas) + the
  conservative measured CLI overhead + output reserve - PROVIDED gpt-5.6-sol and suitable API
  auth work with that endpoint. Otherwise keep the gate closed or narrow the claimed
  guarantee. Ref: developers.openai.com/api/docs/guides/token-counting

TASK 13 AUTHORIZED, still gated behind Task 10:
  New PRIVATE uniquely-named Banyan-LLC/codex-review-e2e-* repo ONLY. Branches, commits, PR,
  formal reviews and a scratch-only base-advance commit are authorized. Do NOT touch existing
  repos, do NOT merge the reviewed e2e PR, use PROCESS-SCOPED network fault injection only,
  ARCHIVE (not delete) afterwards. Stop on any repo or identity mismatch.

REMAINING: 10 (blocked), 11 (needs real CLI, so behind the same manifest gate), 13 (behind 10),
  14 hard gates. Branch still needs renaming to feat/ before any push.

=== TOKEN-COUNTING VIABILITY INVESTIGATION (read-only; no design amendment made) ===
OUTCOME 3: model/authentication unsupported. Recorded as a FAILED PREMISE, not a workaround.
Evidence:
 1. NO API KEY EXISTS on this machine. $env:OPENAI_API_KEY unset; ~/.codex/auth.json has
    OPENAI_API_KEY explicitly NULL and only OAuth material (id_token/access_token/
    refresh_token/account_id). ~/.openai, %APPDATA%/OpenAI, ~/.config/openai all absent.
    No credential value was printed, copied or persisted at any point.
 2. The token-counting endpoint documents API-key auth (Bearer $OPENAI_API_KEY in its own
    examples). No official statement supports using ChatGPT OAuth against it, so the
    user-set boundary forbids repurposing Codex OAuth. => the one authorized minimal request
    COULD NOT BE MADE. Not attempted.
 3. gpt-5.6-sol is NOT listed by the token-counting docs (examples cite gpt-5.6 only). No
    exclusion list either, so support for the -sol variant is UNESTABLISHED, not confirmed.
 4. The gpt-5.6-sol model page confirms 1,050,000 context / 128,000 max output but states NO
    tokenizer or encoding - the original premise remains independently unproven.
 5. EQUIVALENCE would fail even with a key: the endpoint counts what the CALLER sends via the
    Responses shape, while the Codex CLI is a closed binary that composes its own system
    instructions, output schema and account AGENTS.md on a ChatGPT-authenticated path. The
    CLI exposes no token-count/usage subcommand (checked --help). So an endpoint count would
    describe a different request than the one actually billed/consumed.
 6. Better instrument available on the REAL path: the CLI --json event stream reports actual
    input tokens. Whether it does so on THIS CLI version is the one remaining empirical check
    and requires a live codex exec - deliberately NOT run, since Tasks 10/11/13 are paused.

=== CORRECTIONS to the investigation record (user review) ===
C1. The proposed "tokens(text) <= UTF-8 bytes(text) for any tokenizer" argument is REJECTED and
    must NOT be recorded as an argued-not-cited premise. It is not valid in general: a
    tokenizer may insert tokens, normalization may EXPAND text (NFKD decomposition alone
    breaks it), and one input unit may encode as multiple tokens - tokens need not partition
    the input into nonempty spans. Likewise a few minimal runs do NOT establish that CLI
    overhead is content-independent.
C2. Restate outcome as "AUTHENTICATION UNAVAILABLE; APPLICABILITY UNTESTED" - NOT "model
    unsupported". Official docs say gpt-5.6 routes to GPT-5.6 Sol and Sol supports the
    Responses API. The absent API key is decisive locally; the MODEL is not documented as
    unsupported. The endpoint stays unsuitable for proving THIS CLI request regardless, since
    its guarantee covers the payload submitted to it, not a separately composed CLI request.

=== REPLACEMENT DESIGN (user-directed): ACCEPTANCE-TIME USAGE GATE ===
  1. Keep the 50,000-byte preflight cap, described ONLY as an operational input bound.
  2. After the real CLI finishes and BEFORE writing the canonical verdict, require the
     terminal JSON event to report actual input-token usage for that run.
  3. Accept only when: actual_input_tokens + 128,000 <= 0.75 * 1,050,000  (i.e. <= 659,500).
  4. Fail closed if usage is missing, malformed, ambiguously duplicated, or over the bound.
  5. Persist the reported usage AND its originating event in attempt metadata.
  6. If this works, REMOVE the tokenizer and estimated-base-overhead premises entirely -
     actual usage from the reviewed request subsumes both.
  7. Guarantee narrows to: no canonical verdict or publication is accepted unless the
     COMPLETED run reported the required 25% headroom. It does NOT promise an oversized
     request is never attempted.
  Status: bounded non-publishing live diagnostic authorized and RUNNING (production hermetic
  path, temp state, two deterministic prompts). No premises.json, no GitHub, 11/13 still paused.

=== BLOCKER FOUND BY THE FIRST REAL CLI INVOCATION (commit c72e82e) - suite 350->355 ===
  The real `codex login status` prints "Logged in using ChatGPT" to STDERR and exits 0, leaving
  STDOUT EMPTY. Invoke-Candidate returns stdout only, and Test-CodexCandidate tested that value
  for truthiness - so the probe REJECTED EVERY CORRECTLY-AUTHENTICATED CLI. Select-CodexCli
  always threw; every review round would have exited 12. The skill was unusable end-to-end.
  ROOT CAUSE OF THE MISS: the fake shim wrote that line to STDOUT, so the fake was UNFAITHFUL
  to the real CLI and the bug shipped green through 350 tests. Fixed the FAKE first, watched
  test-discovery go red, then fixed the probe (Test-CandidateExitsZero - exit code only,
  stdout ignored; the three stdout-parsing probes deliberately untouched so stderr DOSKEY noise
  cannot corrupt them). Regression pins both directions: empty-stdout-success ACCEPTED,
  nonzero-exit REJECTED. Plan synced.
  LESSON (generalise): every fake must match the real tool stream-for-stream, not just in
  content. A fake that is merely plausible converts a live blocker into a green suite.
  Minor (final triage): under the interim state test-invoke.ps1 SILENTLY TRUNCATED to 74/168
    and still exited 0, because a non-terminating PropertyNotFoundException ends the file
    early. A test file that truncates and reports success is a false green - worth hardening.

=== DIAGNOSTIC RESULT 1: INCONCLUSIVE on usage; FALSIFIED the environment premise ===
  Both live runs exited 1 in 31s with NO verdict and NO usage fields - but they never reached
  the model. stderr: "failed to connect to websocket ... os error 11003" against
  wss://chatgpt.com, i.e. DNS resolution failure.
  CAUSE: the hermetic CODEX_HOME-only child environment breaks Windows name resolution.
  PROVEN WITHOUT ANY MODEL CALL: child with CODEX_HOME only -> DNS_FAIL; + SystemRoot -> DNS_OK;
  SystemDrive tested, NOT required. The earlier "CODEX_HOME only works" check used
  `codex --version`, which never touches the network - insufficient evidence for a network path.
  ACTION: $script:RequiredChildEnv = @{ SystemRoot } with the observed error recorded inline;
  spec + plan amended per the pre-authorised Task 5 Step 5 procedure (necessary + non-sensitive).
  Usage question REMAINS OPEN - the runs must be repeated now that they can reach the API.

  CALIBRATION DATA captured from the real stream (supersedes the plan guesses):
    event types seen: thread.started, item.completed (item.type=error), turn.started, error
    NOT seen: session_created / exec_command / tool_call - the plan taxonomy was invented.
    Deprecation notices surfaced: [features].use_legacy_landlock, web_search_cached,
      web_search_request are deprecated in 0.147 - our default-deny passes them harmlessly.
    Default-deny CONFIRMED WORKING live: "Code Mode is unavailable because code-mode host is
      disabled. Code mode will fail closed" - exactly the intended hermetic behaviour.

=== DIAGNOSTIC RESULT 2: SystemRoot fixed the network; API then REJECTED OUR OUTPUT SCHEMA ===
  Runs now reach the API and fail in ~2s with HTTP 400:
    invalid_json_schema: "In context=(), \x27if\x27 is not permitted." (param text.format.schema)
  THIS INVALIDATES THE DUAL-SCHEMA DESIGN (Task 1 decision #3, the load-bearing one):
  the codex-facing verdict.schema.json carries the top-level if/then severity clause, and
  OpenAI structured-output schemas DO NOT PERMIT `if`. Every review round would 400 before
  inference. 355 unit tests passed against a schema the API will never accept - the fake CLI
  never validated the schema it was handed, so nothing local could have caught this.
  CONSEQUENCE: the severity invariant cannot be enforced by the model output schema at all.
  It must rest solely on Test-Verdict normalisation (which already exists and is tested).
  The two schemas then become identical, so the split - and its whole Test-Json if/then
  rationale - is void and should collapse to ONE schema.
  IN PROGRESS: probing which keywords the API does accept (if/then, minLength/maxLength,
  maxItems) so the surviving schema is known-good rather than guessed. Rejections cost ~2s
  and happen before inference.

=== DIAGNOSTIC RESULT 3: BOTH QUESTIONS ANSWERED - OUTCOME 1 (gate is implementable) ===
SCHEMA: the ONLY offending keyword is if/then. Probe variant B (no if/then, but KEEPING
  minLength/maxLength/maxItems) was ACCEPTED and produced a verdict. So the fix is surgical:
  delete the top-level if/then from verdict.schema.json. All size bounds survive.
  => the dual-schema split collapses: both files become identical, and the Test-Json if/then
     rationale that justified the split is void. The severity invariant now rests SOLELY on
     Test-Verdict normalisation (already implemented and tested).
USAGE: reported on the TERMINAL event, exactly one per run, unambiguous:
  {"type":"turn.completed","usage":{"input_tokens":N,"cached_input_tokens":..,
   "cache_write_input_tokens":..,"output_tokens":..,"reasoning_output_tokens":..}}
MEASURED, real CLI, accepted schema:
    147 prompt bytes   -> input_tokens =  9,456   (terminalEvents=1, verdict written)
  20,160 prompt bytes  -> input_tokens = 23,168   (terminalEvents=1, verdict written)
  => usage RESPONDS to prompt size. CLI overhead ~9,400 tokens. Dense base64 measured at
     ~1.46 bytes/token ((20160-147)/(23168-9456)).
GATE ARITHMETIC: accept iff input_tokens + 128,000 <= 0.75 * 1,050,000 = 787,500,
  i.e. input_tokens <= 659,500. At the 50,000-byte cap, even a pathological 1 byte/token gives
  50,000 + ~9,400 = ~59,400 - two orders of magnitude of headroom. The cap is comfortably an
  operational bound, and the GATE is what actually guarantees the 25% headroom.
CONSEQUENCE: the tokenizer premise and the estimated-base-overhead premise can BOTH be removed
  - actual usage from the reviewed request subsumes them, as the user predicted.
STILL TRUE: the public token-count endpoint remains unusable here (no API key) AND unnecessary
  - the CLI reports exact usage for the real request on the real path.

NEXT (pre-authorised by the user, conditional on the event being usable - it is):
  1. Delete if/then from verdict.schema.json; collapse the dual-schema design; update Task 1
     tests that assert the codex schema REJECTS approve+important (it no longer can).
  2. Implement the acceptance-time usage gate in invoke-codex.ps1: parse the single terminal
     turn.completed usage BEFORE writing the canonical verdict; accept only if
     input_tokens + 128,000 <= 787,500; fail closed on missing/malformed/duplicate/over-limit;
     persist usage + originating event in attempt metadata.
  3. Regressions: missing usage, malformed usage, >1 terminal event, over-limit.
  4. Amend spec+plan: remove tokenizer/base-overhead premises; narrow the guarantee to
     "no canonical verdict or publication is accepted unless the COMPLETED run reported the
     required headroom" - it does NOT promise an oversized request is never attempted.
  5. Event taxonomy for the live batteries is now KNOWN: thread.started, turn.started,
     item.completed (item.type=agent_message|error), turn.completed, error.

=== SCHEMA COLLAPSE + ACCEPTANCE-TIME USAGE GATE: IMPLEMENTED (commit 9d8ca67) ===
  Unit suite 359 -> 397. Live shipped-schema gate 8/8 PASSES.
  - if/then deleted; verdict.structural.schema.json DELETED; one schema serves generation and
    local validation; severity invariant now solely in Test-Verdict with approve+blocking and
    approve+important regressions (object AND json).
  - Acceptance gate before the canonical verdict: process success, no error event, EXACTLY ONE
    turn.completed, positive-integer usage.input_tokens, and input_tokens+128000 <= 787500.
    missing/malformed/duplicated -> 11 (one retry); over-limit -> 10 (human flag). No canonical
    verdict on any failure. Usage + exact terminal event persisted in a CREATE-ONLY
    round-N-attempt-M-usage.json - attempt metadata is never rewritten.
  - 50,000-byte check kept but documented as an OPERATIONAL bound, not a guarantee.
  - Regressions 2-5 discrimination-proven by reverting the gate decision (24 failures) and the
    arithmetic alone (4 failures, zero collateral).
  - NEW live gate: tools/claude-skills/tests/live/live-schema-gate.ps1 - runs the SHIPPED schema
    against the real API. Run whenever the CLI or schema hash changes. This closes the hole that
    let 355 unit tests pass against a schema the API refuses.
  SUBAGENT BUG CAUGHT BY ITS OWN VERIFICATION (worth remembering): a Mandatory [string[]]
    parameter silently REJECTS arrays containing an empty string - which real process stdout
    always has after a trailing-newline split - as a NON-TERMINATING bind error, which cascaded
    into skipping the entire usage gate with nothing surfaced. Fixed by dropping Mandatory.
    SAME LATENT PATTERN elsewhere (currently unreachable): Get-InvocationAudit -CodexArgs,
    Get-DisableSet -FeatureNames, New-CodexArgs -DisableSet. FINAL-TRIAGE ITEM.
  Spec amended (live-evidence round entry at top). PLAN doc NOT yet synced for this change -
    the subagent declined, citing a convention that does not exist here. OUTSTANDING.

GATES NOW SATISFIED for Task 11: amended unit suite PASSES (397) and one live shipped-schema
  run PASSES. Per user direction, TASK 11 (live security battery) IS THE NEXT STEP.
  Task 13 remains paused; its authorization boundaries are recorded above.

=== RELOCATED TO ITS OWN REPO (2026-08-15) ===
  Now at C:\Users\geoff\Documents\Projects\Banyan\spec-plan-review, branch main, remote
  git@github.com:Banyan-LLC/spec-plan-review.git (NOT pushed yet - outward-facing, awaiting call).
  Layout: skills at repo root (codex-review/, codex-reviewed-dev/, tests/, install.ps1);
  docs/design.md + docs/implementation-plan.md are the controlling documents; docs/build-log/
  holds this ledger and every task report. Relative paths were preserved (tests remains a
  sibling of codex-review), so nothing needed rewriting.
  VERIFIED IN THE NEW LOCATION: 380 unit tests (composer 34, discovery 27, invoke 183,
  policy 15, publish 51, schema 9, state 61) + live schema gate 8/8.
  The cavu.photo worktree branch claude/reusable-spec-plan-review-8fcff9 at 51b2c71 is
  UNCHANGED - nothing was deleted there. Remove it once satisfied with this repo.
  NOTE: the build log lived in cavu.photo/.git/worktrees/<name>/sdd/ and would have been
  destroyed by worktree pruning; it is now tracked here.

=== PLAN SYNC + PARAM SAFETY (commits 37aa69c, 51b2c71 in the source worktree) ===
  Plan doc synced to the live-evidence design: single schema, acceptance-time usage gate,
  create-only usage artifact, operational byte cap, live schema gate, real event taxonomy,
  CODEX_HOME+SystemRoot. Four-premise/tokenizer/base-overhead procedure removed.
  PREMISE MANIFEST DECISION: kept Test-PremiseManifest/premises.json/calibrate-premises.ps1 for
  their STACK-IDENTITY binding (CLI hash/version, schema, AGENTS.md, invocation profile) so a
  changed reviewer stack still invalidates prior results; DROPPED the four numeric premises,
  tokenizer_evidence and the 0.75x inequality, which the usage gate now proves on real usage.
  calibrate-premises.ps1 no longer makes a live model call, so the unobtainable-evidence
  blocker is GONE rather than papered over - the production path can run.
  Suite 397 -> 374 (-23 numeric-premise assertions) -> 380 (+6 param regressions).
  Three Mandatory [string[]] params fixed by CONTRACT CHANGE (not a safety proof):
  Mandatory dropped + Assert-NoEmptyStringElements terminating throw, each regression proven
  red against a reverted old-contract copy.
  OUTSTANDING (final triage): FOUR more identically-shaped params left unfixed -
    Get-InvocationAudit -ExpectedDisable, Get-InvocationProfileHash -DisableSet,
    Invoke-CodexProcess -CodexArgs, Invoke-Gh -GhArgs.
  OUTSTANDING: test-invoke.ps1 is not safe to run concurrently with itself (races on the shared
    real premises.json). Pre-existing, found incidentally.

NEXT: Task 11 (live security battery). Task 13 stays paused until Task 11 and its
  capability-class gates pass.

=== TASK 11 COMPLETE (commits 6d1b337, f9f79da) - live security battery GREEN: 72 passed, 0 failed ===
  CLI 0.147.0-alpha.6.6, sha256 592958...c69b3 (bin 8e8bf206e63ac436).
  CONTROL-VERIFIED (positive fires isolated + absent under real disable set + pairwise-distinct):
    shell (command_execution), web (web_search), mcp (out-of-band canary), apps (mcp_tool_call
    server=codex_apps), plugins (plugin-bundled canary, tested in its OWN home).
  NARROWED (configured-off by default-deny, NOT independently control-proven on this CLI version -
  no signal distinguishes enabled from disabled in headless exec): computer_use, skills, subagents.
    Narrowed consistently in docs/design.md, codex-review/SKILL.md, README.md (codex-reviewed-dev
    SKILL.md makes no independent claim). The battery still RUNS their controls and asserts they do
    NOT fire, so a future CLI making one observable goes red.
  STRONGER PROPERTY found live: code_mode_host (denied unconditionally) is a router-level
    prerequisite for shell/web/apps/computer_use/skills alike - denying it blocks all five before
    their own feature flag is consulted.
  Injection: never coerced into approve 3/3 (hard-asserted). Explicit self-report 1/3 = model
    variance on gpt-5.6-sol@xhigh, now logged not asserted.
  DESIGN DECISION (controller, surface for user review): requiredClasses reduced to the 5 proven +
    a separate Constant narrowedClasses(3) with an exhaustiveness check, so verified==required
    passes GREEN per user requirement 3 instead of a permanently-red battery. Narrowing MOVES a
    class between two lists that jointly cover the full surface; it can never drop one silently.
  Cleanup verified: no copied auth.json, no stray temp trees, real premises.json absent, tree clean.
  Review found + fixed 4 items (hermetic-usable hard gate, plugins-own-home proof, Constant lists,
  injection self-report soft) - all in commit f9f79da, battery re-run green after.
  ~55-60 live calls total across exploration + verification runs (subagent), + 2 controller verify
  runs. Cost noted; each driven by a genuinely unknown CLI fact.

OUTSTANDING before push/Task 13 (user decision): task-14 hard gates (premise live-evidence stamp
  wiring end-to-end, CODEX_HOME-only env contract already amended to +SystemRoot). Task 13 (gated
  PR e2e) still paused - authorized into a NEW private Banyan-LLC/codex-review-e2e-* repo only,
  no merge, process-scoped fault injection, archive-not-delete, stop on any identity mismatch.

=== TASK 14 SECURITY-REVIEW PASS COMPLETE (offline 454/0; both live gates green) ===
  All seven review findings fixed. Commits: dd46ad0 (--ephemeral), 3dd64c2 (Get-RunUsage fail
  closed), 7e09b88 (dual live_evidence), 0f72a5b (fingerprint split), dc74f59 (doc sync),
  0f5e533/753b4f8/01faa81/306c5f6 (master list, battery parser, AGENTS.md, injection oracle),
  f3b842f (battery stamp + disclosure regex), 2400d4a (calibration message), 58244c9 (fail-open).
  RESULTS: offline 454 passed/0 failed; live-schema-gate 10/0; live-security 112/0 (was 72).
  Manifest AUTHORIZES: Test-PremiseManifest Valid=True, both sub-records sharing one wrapper
  fingerprint 303b3ed4...79691 (recomputed from disk, matches) and one gate fingerprint.
  Cleanup verified: no stray temp trees, no copied auth.json, premises.json gitignored, tree clean.

  TWO DEFECTS THE REVIEW DID NOT NAME, both found by RUNNING things rather than reading them:
  1. FAIL-OPEN LIVE GATES (P1, would have shipped). Write-LiveEvidence read
     .PSObject.Properties.Name on the EMPTY pscustomobject built when a manifest has no
     live_evidence key; StrictMode makes an empty property collection's .Name a statement-
     terminating error, so nothing was written -- and live-schema-gate.ps1 neither caught it nor
     verified the write, printing "8 passed, 0 failed" and exiting 0 having authorized NOTHING.
     This was the NORMAL path (calibration always drops live_evidence, so every first stamp hit
     it). Every existing stamping test began from a manifest that already had live_evidence,
     which is exactly why 432 green tests missed it. Fixed + read-back verification + both gates
     now assert the record is readable. Regression discriminates (pre-fix RED with the observed
     error, post-fix 252/0).
  2. The new no-disclosure assertion flagged any identifier=value at line start, and finding 5
     had just added an unbounded-retry defect that invites `maxRetries=5` -- a CORRECT verdict
     would have failed the battery. Narrowed to env-var shape, which exposed that PowerShell's
     -match is CASE-INSENSITIVE by default (an uppercase-only class still matched camelCase);
     needs -cmatch. Verified against 9 discrimination cases.
  Recurring lesson, now three-for-three: the fake/test environment differed from the real one in
  exactly the dimension that mattered (stdout-vs-stderr, repo-vs-installed tree, already-stamped-
  vs-freshly-calibrated manifest). Offline green is necessary, never sufficient.

  STILL NOT DONE (user decision): push main, Task 13, remove cavu.photo worktree.

=== FOUR-FINDING FOLLOW-UP COMPLETE (offline 485/0; both live gates green, re-stamped) ===
  Commits 667c1a8 (gate-source binding), a4a1e02 (gate self-identity), 2b8e3f0 (Get-PropertyNames),
  8f7c080 (injection requirement restated).
  P1 gate binding: tests/helpers.ps1 now IN the gate fingerprint (it defines every assertion and
    the exit decision, so editing it previously left the fingerprint unchanged). Provenance-only
    mode is now opt-in via -AllowProvenanceOnlyGateSources, never inferred: all sources present =>
    always verified strictly; PARTIAL tree => always refused (even with the switch); wholly absent
    => provenance-only only for the identified installed-tree caller (invoke-codex.ps1). install.ps1
    stays strict by omission, documented inline.
  P1 gate identity: each record must satisfy rec.gate -ceq its own property name, so duplicating
    the schema record under security_battery no longer authorizes the stack (every other
    fingerprint field is shared, which is exactly why it passed before).
  P2 StrictMode: one shared Get-PropertyNames helper replaces 19 unsafe .PSObject.Properties.Name
    sites. Get-RunUsage now returns Ok=False on a typeless {} instead of throwing. Remaining
    textual hits are comments plus the generated MCP canary, which runs as its OWN child process
    without StrictMode and inside try/catch (verified, documented at New-McpCanaryScript).
  P2 docs: design.md + battery comment restate the hard requirements as non-compliance,
    identification of the independent retry defect, and no disclosure; narration explicitly
    non-gating. Marked as a Corrected note, history preserved.
  VERIFIED SEQUENCE: offline 485/0 -> stale evidence correctly REFUSED (wrapper fingerprint proved
    itself live) -> recalibrate -> schema gate 10/0 -> security battery 112/0 -> both re-stamped.
    NEW wrapper_fp 3ca4aadf...5164, NEW gate_fp 82ab0290...2cf0, both recomputed from disk and
    matching, both records self-identifying, Test-PremiseManifest Valid=True. Tree clean, no
    stray temp dirs, no copied auth.json.

  NOT DONE PENDING USER DECISION: push main / verify remote SHA / Task 13. A background task
  ("Ship tests/live/ so Get-SecuritySourceFingerprint works installed") was started in a separate
  session; its premise is OBSOLETE (superseded by the wrapper/gate split) and it would edit this
  same repo concurrently. Flagged to the user; do not push until it is stopped or resolved.

=== DOCSTRING RESIDUAL FIXED + FULL SEQUENCE RERUN (commit 7024a7e) ===
  Test-PremiseManifest's gate_fingerprint bullet still said "the two live gates" (three sources
  since helpers.ps1 joined) and described absence as unconditional provenance-only, contradicting
  the -AllowProvenanceOnlyGateSources rule six lines below. Docstrings are the spec here, so a
  bullet contradicting the authoritative rule is a defect. Fixed + two stale test comments.
  calibrate-premises.ps1's "two live gates" left alone: it means the two GATES, still correct.
  Rerun because lib.ps1 is inside the wrapper fingerprint: offline 485/0 -> recalibrate ->
  schema 10/0 -> security 112/0. NEW wrapper_fp c969b5f4...03a8; gate_fp UNCHANGED at
  82ab0290...2cf0 -- correct, since only wrapper sources changed. Both recomputed and matching,
  both records self-identifying, Valid=True, tree clean.
  Two concurrency worries raised by the parallel session, both checked and UNFOUNDED: tests use a
  GUID-unique temp skill root ($tmp = codexinv-<guid>), never the real premises.json, so the suite
  neither clobbers live evidence nor races itself. That session made no commits.

=== TASK 13 STEP 2 (PARTIAL) - STOPPED ON A P1 FOUND BY DRILL 6 ===
  Scratch repo: Banyan-LLC/codex-review-e2e-20260816 (private). NOT archived yet - drill 6 must be
  re-run after the fix below. Nothing merged. Two PRs, both authored geoffroth, reviewed BanyanLLC.

  PR #1 (fetcher.js, deliberate unbounded-retry fixture): review loop ran ROUNDS 1-10 and hit the
    ROUND CAP without approving. That is the designed escalation, not a failure: every round
    returned request_changes on genuine findings, and the loop refused to approve. Fixed real
    defects across rounds (unbounded retry; unbounded cache; JSON parsed inside the retry path;
    501/505 retried; unencoded id; no deadline; body-transport vs JSON-syntax conflation;
    AbortError-only retry classification; Symbol-id re-interpolation). Round 8 caught a
    ReferenceError I had shipped (normalizeId referenced, never defined - my patch silently
    no-matched and `node --check` only validates syntax, not references). I did NOT raise
    RoundCap to force an approval.
  ROUND 9 WASTED ON A STALE HEAD: the GitHub PR API returned the pre-push headRefOid seconds
    after a push, so round 9 re-reviewed the old blob. GAP: the caller must confirm the PR head
    equals the pushed commit BEFORE composing the prompt. SKILL.md does not say this.
  PR #2 (trivial .gitignore, a second fixture created solely to exercise the approval path):
    approved in one round, published APPROVED as BanyanLLC pinned to the reviewed head.

  DRILL 5 head-drift: PASS. Baseline Fresh=True; after pushing a commit -> Fresh=False
    'head advanced'.
  DRILL 6 base-drift: *** FAILED - P1 DEFECT IN SHIPPED CODE ***
    Advanced the scratch repo's main to 3dc0738 after approval. Expected Fresh=False
    'base advanced'; got Fresh=True. ROOT CAUSE (verified, not inferred): Get-PrOids reads the
    PR's `baseRefOid`, which GitHub keeps STATIC at the commit the PR was opened against - it does
    NOT track the base branch tip. Evidence: main tip = 3dc0738 while baseRefOid stayed 8fa5aafa,
    unchanged after a 20s wait. publication.json's base_oid was recorded from that same static
    field, so lib.ps1:1446 `if ($now.BaseOid -ne $pub.base_oid)` compares a value to ITSELF and
    the 'base advanced' branch is UNREACHABLE. One of the four handoff-freshness guards has never
    worked. FIX: compare the recorded base against the base BRANCH TIP
    (repos/<o>/<r>/git/ref/heads/<baseRefName>), not the PR's static baseRefOid; record that tip
    at publication time; add a regression that moves the base branch and asserts 'base advanced'.
  DRILL 7 idempotency: PASS. Re-running publish-review.ps1 with identical inputs exited 0 and the
    review count stayed at 2 (no duplicate review).
  DRILL 8 transient fault injection: NOT RUN - stopped per instruction on the drill-6 mismatch.

=== DRILL-6 FIX (P1) SHIPPED - base_ref_name/base_tip_oid replace the dead base_oid check ===
  See docs/build-log/task-14-report.md ("Task 14 follow-up: two P1 fixes from the live e2e drill")
  for full detail. base_oid kept as the diff base; two new fields (base_ref_name, the LIVE base
  branch tip via a NEW Get-BaseBranchTip call against repos/<o>/<r>/git/ref/heads/<branch>, a
  genuinely separate endpoint from baseRefOid) threaded through attempt meta, the review marker,
  and publication.json, and enforced at pre-publication, post-publication, AND handoff (not just
  handoff). Test-HandoffFresh's dead `$now.BaseOid -ne $pub.base_oid` line is gone, replaced by a
  base-ref-rename check + a live-tip check that reuses the 'base advanced' reason string.
  Discrimination proven: reverting Test-HandoffFresh to the exact original line and re-running
  tests/test-publish.ps1 sends the new case-(a) assertion (and 6 others) RED; restored -> GREEN.
  Suite 485 -> 504 (test-invoke +6, test-publish +13). Drill 6 itself not yet re-run against the
  scratch e2e repo (offline fix + regressions only, per this task's scope). FIX 2 (stale-head
  protection, round-9 waste) follows in a separate commit.

=== ROUND-9 FIX (P1) SHIPPED - Wait-PrHeadSynced makes stale-head protection executable ===
  New bounded-poll helper in lib.ps1 (Get-PrOids-backed): Wait-PrHeadSynced -ExpectedHead
  -StaleHead [-TimeoutSec] [-PollIntervalSec] -> {Synced;ActualHead;Reason}, never throws for the
  normal mismatch/timeout path. -StaleHead lets it tell "still propagating" apart from an
  UNEXPECTED third head (someone else pushed concurrently) with its own distinct reason, instead
  of polling a genuinely different problem all the way to the timeout. Documented as a hard
  MUST-confirm-before-composing requirement in both codex-review/SKILL.md (pr-mode inputs) and
  codex-reviewed-dev/SKILL.md (PR pipeline bullets c and d -- (d) is the exact push-then-re-review
  transition round 9 wasted). Not yet wired into invoke-codex.ps1 itself (hermetic, must not call
  gh) or publish-review.ps1 -- an orchestrator-level precondition, same pattern as
  Test-HandoffFresh. Suite 504 -> 516 (+12, test-publish.ps1, 3 cases: becomes-synced,
  permanently-stale-bounded, unexpected-third-head-distinct-reason). Task overall: 485 -> 516.

=== TASK 13 STEP 2 COMPLETE - all four drills PASS; scratch repo archived ===
  Fixes first (313297a base-drift guard, 9398c78 Wait-PrHeadSynced, f424cb8 two follow-ups).
  Offline 516/0. Live gates re-run TWICE (each wrapper edit invalidates the fingerprint):
  schema 10/0, security 112/0 both times. Pushed main: 24dad6d -> 9398c78 -> f424cb8, remote
  SHA verified each time.

  *** THE CODEX CLI AUTO-UPDATED MID-TASK: 0.147.0-alpha.6.6 -> 0.148.0-alpha.9. ***
  The manifest caught it ("invocation profile changed") and refused to authorize until both gates
  re-ran. The security battery then passed 112/0 on the NEW binary, so the 5 control-proven /
  3 narrowed capability split re-verified on 0.148 rather than being assumed to carry over. A
  pinned-CLI change also correctly forced exit 13 (-AcceptNewBinary) on a live review round.

  DRILL 5 head-drift: PASS (Fresh=False 'head advanced').
  DRILL 6 base-drift: PASS after the fix, proven against the exact condition that defeated the old
    code: baseRefOid stayed STATIC at 8fa5aafa while the live tip moved 3dc0738 -> 2403a80, and
    Test-HandoffFresh returned 'base advanced'. Baseline Fresh=True first, carrying the new
    base_ref_name/base_tip_oid provenance.
  DRILL 7 idempotency: PASS (re-publish exit 0, review count unchanged).
  DRILL 8 transient: PASS. Injection method DEVIATED from the plan and this is itself a finding:
    the plan suggested HTTPS_PROXY/GH_HOST in the child env, but Invoke-Gh CLEARS the child
    environment to GH_TOKEN + SystemRoot, so env-based injection cannot reach the child at all.
    Used a PATH-scoped fake gh instead (process-scoped; workstation network untouched): faulted
    exit=5 'TRANSIENT: actor lookup failed' with NO review created, then recovery with identical
    inputs exited 0 with the review count unchanged.

  TWO DEFECTS IN THE NEW CODE, found by driving it live, fixed in f424cb8:
   - Wait-PrHeadSynced made -StaleHead Mandatory, so a caller syncing for the FIRST time (no prior
     head to name - the common case) could not call it at all. Now optional; it only sharpens the
     diagnosis, the gate is unchanged.
   - A publication predating the fix has no base_ref_name/base_tip_oid; reading them under
     StrictMode threw and surfaced as "transport or malformed response" - a misleading diagnosis
     for an operator. Now fails closed naming the missing fields and the remedy.

  OPEN DESIGN QUESTION (surfaced by an operator error of mine, worth a decision):
    base_tip_oid is bound into the idempotency marker as specified, so a transient retry that
    happens AFTER the base branch moves posts a SECOND review instead of recovering. I hit this
    exactly: markers differed only in base_tip (3dc0738 vs 2403a80), same head/round/digest, and
    PR #2 ended with 4 APPROVED reviews, 2 of them now stale-but-standing. Defensible (a moved
    base IS a different review context) but the stale prior approval is left APPROVED rather than
    dismissed. Recommend deciding: dismiss superseded reviews on base movement, or exclude
    base_tip from the marker and rely on Test-HandoffFresh alone.

  FIXTURE SPLIT (kept explicit): PR #1 = fetcher.js, the real adversarial fixture; ran rounds 1-10
    and hit the ROUND CAP without approving - valid escalation evidence, cap NOT raised, approval
    NOT manufactured. PR #2 = a trivial .gitignore, created SOLELY to exercise the approval-only
    mechanics (drills 5-8) that PR #1 could not reach. All drill results above are from PR #2.
  Scratch repo ARCHIVED (not deleted), still private, 0 merged PRs, both PRs left open.
  REMAINING: Task 13 Step 1 activation checklist - a manual gate the user runs in a fresh session
    after install.ps1; four exact prompts, record observed skill routing.

=== FOUR-FINDING FOLLOW-UP COMPLETE + INSTALLED (commits 3030f38, 0f783c7, de69306, e7d5b71) ===
  Decision honored: base_tip_oid STAYS in the marker; superseded tool-owned reviews are dismissed
  instead of loosening the marker.
  P1 verdict binding: publish-review.ps1 now requires the canonical round-N-verdict.json, locates
    the successful attempt's immutable metadata, and exactly compares PR, round, base_oid,
    base_ref_name, base_tip_oid and head BEFORE any gh call. Mismatch = NEW EXIT 6 (collision-free;
    documented in the script header, both SKILL.md files, design.md and the plan). Regressions
    prove no gh invocation occurs, via a recording fake gh whose log file is asserted absent.
    This closes exactly the hole I fell through live: a tip-3dc0738 verdict relabelled as 2403a80.
  P1 ordering + retirement: the exact-marker scan now precedes the drift return, so a POST that
    succeeded before an exit-5 is FOUND and dismissed on retry instead of hitting a stale exit 2;
    no existing review + drift still returns 2. Retirement is a separate explicit operation,
    Revoke-SupersededReview, with three preconditions (authored by the configured Reviewer; carries
    the exact tool marker; Test-HandoffFresh's Reason is exactly head advanced / base advanced /
    base ref renamed). Test-HandoffFresh remains READ-ONLY - verified by inspection: no dismiss,
    PUT, POST or --method inside it. Dismissal denial stays exit 4.
  P2 poll guard: the unexpected-head branch is now gated on $PSBoundParameters.ContainsKey
    ('StaleHead'). Without -StaleHead a non-expected head is simply not-yet-synced and polling
    continues. This was MY bug from the previous round - making the parameter optional without
    updating its guard made the helper return after ONE poll for the most common caller.
  P2 docs: design.md + implementation-plan.md synced to the four-part provenance (base_oid as the
    DIFF BASE, base_ref_name, base_tip_oid as the live moving tip, head), verdict/attempt binding,
    retirement, and the PATH-scoped intercepted-gh fault injection - recording that the plan's
    HTTPS_PROXY/GH_HOST method is IMPOSSIBLE here because Invoke-Gh clears the child env to
    GH_TOKEN + SystemRoot. Plan now says ARCHIVE ONLY.
  VERIFIED: offline 553/0 (from 516; +37 in test-publish). Stale evidence correctly refused ->
    recalibrate -> schema 10/0 -> security 112/0 on CLI 0.148.0-alpha.9. wrapper_fp
    4f529e0a...5342 recomputed and matching, one wrapper fp and one gate fp across both records,
    Valid=True. Pushed af33ccd..4febd54, remote SHA verified. install.ps1 exit 0 - both skills
    installed to ~/.claude/skills and the CLAUDE.md pointer appended.

  REMAINING: Task 13 Step 1 ONLY - the fresh-session activation checklist, which the user runs.
    Keep the cavu.photo worktree until that passes.

=== SILENT NO-OP ASSERTION IN test-publish.ps1 (user-reported) ===
  DEFECT (test-only; no product defect): `Assert-True ((pipeline) -ne $null)` is not a null
    comparison when the pipeline returns MULTIPLE elements - `-ne` goes element-wise and FILTERS,
    handing back an Object[]. Assert-True's [bool]$Condition then fails argument transformation
    ("Cannot convert value 'System.Object[]' to type 'System.Boolean'"), and that error is
    NON-TERMINATING at script level: the run continues and the assertion increments NEITHER
    $script:Passes NOR $script:Failures. It silently verifies nothing while the file still
    reports "N passed, 0 failed".
  HOW IT GOT IN: drill 6's own P1 fix added the SECOND Get-BaseBranchTip call (pre- AND
    post-publication). Both hit git/ref/heads/main, so the happy-path filter went from one
    element to two and "live base-branch-tip endpoint called" stopped asserting - i.e. the fix
    disarmed its own regression test. 100% deterministic, not flaky; easy to miss only because
    the error prints mid-stream rather than at the end.
  AUDIT METHOD: not grep alone. Assert-True was TEMPORARILY instrumented (type untyped + report
    any non-[bool] condition with caller file:line) and all seven files re-run, which proves
    EMPIRICALLY that across all 553 executing assertions exactly ONE non-boolean condition
    reached Assert-True. Instrumentation then reverted; `git diff --stat` confirms helpers.ps1
    is untouched. A static sweep of tests/ (including live/) independently found only two
    `-ne $null` conditions in the entire tree, both on these two adjacent lines.
  FIXED: both lines now use `@(...).Count -gt 0`, so 0/1/many behave identically. Line 81
    ("slurp pagination") was NOT broken yet - one call matches today, so Where-Object yields a
    scalar and `-ne $null` is a genuine [bool] - but it is the same booby trap and was hardened
    with it, since a second matching call would silently disarm it exactly as above.
  VERIFIED: offline 554/0 (from 553/0). The +1 is precisely the previously-uncounted assertion;
    every other file is byte-identical in count (composer 37, discovery 27, invoke 285, policy
    15, publish 115->116, schema 9, state 65). No transformation errors anywhere in the run.
    NEGATIVE CONTROL: with both regexes mutated to non-matching sentinels the file reports
    114 passed, 2 FAILED, naming both assertions - proving they now genuinely bite rather than
    merely being counted. No production code in codex-review/ was touched; the newly-functioning
    assertion passes on its merits, so it uncovered no latent product defect.
  NOTE - BOTH ACTIONED, see the next section: the root cause of the SILENCE is Assert-True's
    [bool]$Condition failing transformation non-terminatingly and uncounted. A guard in
    helpers.ps1 - accept $Condition untyped and record an explicit FAILURE for any non-boolean -
    makes this whole class impossible to reintroduce anywhere in the suite. Same class:
    `(pipeline).Property -match '...'` (test-publish.ps1:79, 80, 101) returns an Object[] the
    moment the pipeline yields more than one element.

=== ASSERTION BACKSTOP + SELECTOR CARDINALITY (user-directed follow-up) ===
  P1 BACKSTOP (helpers.ps1): Assert-True's $Condition is now UNTYPED with an explicit [bool] gate.
    [bool]$Condition looked stricter but was catastrophically weaker, because the strictness was
    enforced by the PARAMETER BINDER: an unconvertible argument raised a NON-TERMINATING
    transformation error, the body never ran, and the assertion incremented neither counter. Any
    non-[bool] now records a COUNTED failure carrying the received type and element count ($null
    reported as count 0, not @($null).Count's misleading 1). This is the only fix that makes the
    class non-recurring rather than fixing sites one at a time; it matters doubly because
    Write-TestResult's exit code is what BOTH live gates live and die by.
    Deliberately rejects single-element arrays too: @(1) is Object[] and is NOT unwrapped by
    parameter binding (verified directly) -- and a one-element result is exactly the state a
    `-ne $null` check sits in right before a second matching call silently disarms it.
  DURABLE REGRESSION (tests/test-harness.ps1, NEW, 39 assertions): child-process probes, because
    the claim under test IS $script:Passes/$script:Failures -- asserting it in-process would
    corrupt the counters doing the reporting. Same isolation rationale as
    Test-EmptyElementFailsClosed. Covers multi-element Object[], single-element, empty, string and
    $null (each must be ONE counted failure naming type + count + which assertion), $true/$false/
    an ordinary -match (behavior must be unchanged), and the original shipped expression
    end-to-end. Named test-*.ps1 so run-tests.ps1's glob picks it up: the suite is now EIGHT
    offline files, not seven. NOT added to Get-GateFingerprint's list - correctly, since the live
    gates never execute it.
    NEGATIVE CONTROL: run against HEAD's [bool]$Condition helpers.ps1 (via git show, so the
    comparison is the real prior file) it reports 13 passed, 26 FAILED - every
    "expected '1', got '0'" being the old silent skip caught in the act.
  P2 SELECTOR CARDINALITY (test-publish.ps1): all six $script:GhCalls selectors materialized with
    @(), cardinality asserted, then indexed [0] - happy-path POST, slurp scan, base-tip, downgrade
    POST, fresh-POST-after-dismissed-marker, dismissal, hostile-content POST. Base-tip asserts
    EXACTLY 2 (pre- and post-publication: the two reads that ARE the drill 6 fix), not `-gt 0`,
    which would still pass if either check were dropped.
    The dismissal site was the subtlest and the one the backstop structurally CANNOT catch:
    `$dis.Input -match A -and $dis.Input -match B` has `-and` coerce both Object[] operands back to
    [bool], so a genuine boolean still reaches Assert-True and the assertion merely degrades from
    "THE dismissal body is complete" to "SOME dismissal has A and SOME has B". Split into two
    assertions so a failure names which half is missing.
    Cardinality 1 for dismissal is by construction, not by observation: production issues ONE PUT
    to .../dismissals and its read-back is a plain review GET with no 'dismissals' in the URL.
  IN PASSING: the first draft of test-harness.ps1 used `-like "*type=System.Object[]*"`, where []
    parses as an empty CHARACTER CLASS -> WildcardPatternException -> also non-terminating, also
    uncounted, silently 36 passed instead of 39. The same defect class, inside the test written to
    catch it. Now uses literal .Contains(). Worth remembering: -like is unsafe for any needle
    containing [ or ].
  VERIFIED: offline 602/0 across EIGHT files (composer 37, discovery 27, harness 39, invoke 285,
    policy 15, publish 125, schema 9, state 65). publish 116 -> 125 = +1 happy POST, +1 downgrade
    POST, +1 hostile POST, +6 from the dismissal split across three loop iterations.
    NEGATIVE CONTROL on cardinality: mutating every expected count yields exactly 9 failures,
    including base-tip's "expected '1', got '2'" - proving it discriminates a DROPPED pre/post
    check rather than merely "at least one".
  LIVE (helpers.ps1 is in Get-GateFingerprint's fixed list, so both stamps had to be re-earned):
    gate fp moved 82ab0290... -> cb4aeb7e..., confirming FINDING 1a's mechanism. schema gate 10/0,
    security battery 112/0, both re-stamped; both records now carry ONE gate fp (cb4aeb7e...) and
    ONE wrapper fp, each matching the freshly computed value. Wrapper fp UNCHANGED at 4f529e0a...
    5342 - independent confirmation that no production code was touched. Test-PremiseManifest
    (the real gate invoke-codex.ps1 and install.ps1 call) returns Valid=True.
    FIRST battery run failed 56/2: a live round hung past Invoke-Control's 600s bound at HERMETIC
    CONTROL (plugins-home), so the battery correctly refused to assert canary ABSENCE against a
    non-usable run, threw, and withheld the stamp. NOT related to this change - Assert-Usable
    passes $Result.Usable, a genuine [bool]; the log contained no NON-BOOLEAN failures; and nothing
    in helpers.ps1 can affect a live codex.exe wall-clock. Clean 112/0 on re-run. Recording it
    because a recurrence at that same stage would be a real CLI/API finding, not a test bug.
    premises.json is gitignored (machine-bound), so these stamps are a LOCAL authorization gate;
    the push carries only the three test files.
