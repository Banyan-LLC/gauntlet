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
