# Task 8 Report

Status: complete, all green.
Commit: 0cf37f2c26045a2675c39878668c6a509dca1b4c, branch claude/reusable-spec-plan-review-8fcff9.
Tests: test-publish.ps1 45/45 (stable x3 reruns, ~31s/run); full suite 344/344
(26+22+168+13+45+9+61), up from 299.

Defects found in the brief's own code (each confirmed by reverting in isolation):
1. test-publish.ps1's fake-gh queue advance, `$script:GhScript[1..($script:GhScript.Count)]`,
   is an off-by-one that throws "index outside array bounds" on every call; the failed
   assignment leaves the queue unadvanced, so every call replayed handler 0 forever. Fixed
   with `Select-Object -Skip 1`.
2. ConvertTo-ReviewBody's 60,000-byte OVERSIZED cap is unreachable by any schema-valid
   verdict (schema max renders to ~24.6KB), so the brief's own oversized-body test could
   never pass. Lowered to 20,000 bytes.
3. Invoke-Gh resolved 'gh' via bare `Process.Start(FileName='gh')`, which on Windows only
   tries the literal name or name+".exe", never a PATHEXT .cmd/.ps1 — so on any machine
   with a real gh.exe installed, a PATH-prepended test shim is silently bypassed for the
   real binary. This fired once live during verbatim testing (harmless, read-only
   `gh pr view` against nonexistent "o/r", no stored auth, no mutation). Fixed with
   Resolve-GhInvocation (Get-Command + existing Resolve-CliInvocation), used in both
   Invoke-Gh and publish-review.ps1's token lookup.

Concerns: calibrate-premises.ps1 has no brief-given test; hand-smoke-tested (golden path,
2 samples, 2 failure branches) against an uncommitted fake CLI shim — all clean.

# Task 8 Report — Follow-up: two P1 review fixes

Status: complete, all green.
Commits: bdb63e6 (Fix 1: prove shim interception), 520460d (Fix 2: verify published-review author).
Tests: full suite 344/344 -> 350/350 (26+22+168+13+51+9+61); test-publish.ps1 45/45 -> 51/51.

Fix 1 (shim-interception test didn't prove interception): restricted the child's PATH to
ONLY the shim directory (this dev machine has a real gh.exe at "C:\Program Files\GitHub
CLI\gh.exe", confirmed reachable via normal PATH and confirmed unreachable once PATH is
restricted — the risk was real, not hypothetical), launched pwsh by absolute ProcessPath
(both the outer test invocation and the shim's own pwsh launch, since PATH restriction
leaves nothing left to resolve `pwsh` by name), and had the shim write a sentinel file
before sleeping. Discrimination: with the sentinel-write stripped (PATH restriction kept —
never risk a real gh), test-publish.ps1 dropped to 45 passed / 1 failed on exactly "gh shim
actually ran (PATH-restricted interception proven, not a coincidental real gh)".

Fix 2 (author never verified): forwarded `-Reviewer $Reviewer` from publish-review.ps1 into
Publish-CodexReview (was silently dropped, falling back to the library's own default for
every identity-sensitive decision); added a pre-mutation identity gate resolving the
token's actual actor via `gh api user --jq .login` through the existing bounded Invoke-Gh,
aborting before any GitHub call that could read or write on a mismatch; added the review's
`user.login` to post-publication verification's `$verified` (StrictMode-safe: read inside
try/catch, a missing key reads as "no match", never throws — `--jq` extraction sidesteps
the same risk for the actor lookup by returning plain text, never parsed JSON). Exit 12
chosen for the pre-mutation actor-mismatch abort: it reuses the existing "no usable token
for '$Reviewer'" contract slot, since a token authenticating as the wrong person is exactly
as unusable for publishing AS that reviewer as no token at all; 2/3/4/5/11 each presuppose
either a successful non-identity gh call already happened or a content-shape problem,
neither of which fits a rejection that must happen first and make zero other calls.

Discrimination, two isolated single-line reverts (everything else untouched): reverting
just the publish-review.ps1 forwarding line -> 50 passed / 1 failed, only "non-default
-Reviewer is forwarded end-to-end..." fails (expected exit 5, got 12 — the identity gate
compared the shim's claimed identity against the library's own default instead of the
custom reviewer passed on the command line). Reverting just the `$verified` author-check
line -> 50 passed / 1 failed, only "review authored by someone else fails post-verification
-> dismissed" fails (expected 3, got 0 — a review authored by 'someone-else' was reported
as successfully verified, exactly the original defect). A combined revert of all of Fix 2's
production code also correctly breaks the suite (40 passed / 10 failed, plus one assertion
whose Publish-CodexReview call throws before Assert-Eq can even run) via cascading queue
misalignment across every existing scripted-gh test — further confirmation the identity
call is load-bearing, not dead code, though too entangled with shared test fixture state to
read as a clean single-assertion signal on its own, which is why the two isolated reverts
above are the primary evidence.

New tests added (test-publish.ps1): actor-mismatch-refused-before-mutation (asserts exit 12
AND that only the identity-check gh call happened, zero others); wrong-author-dismissed;
non-default -Reviewer honoured end-to-end through the real publish-review.ps1 entry point
(E2E, PATH-restricted shim, exit 5 forwarded vs exit 12 not-forwarded). Every pre-existing
Publish-CodexReview test's scripted-gh queue was updated to include the new leading
identity-check response so it still lines up.

Concerns: none blocking.
