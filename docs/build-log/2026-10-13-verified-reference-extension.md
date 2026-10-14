# Verified controlling-spec reference extension

User authorized this narrow implementation and its tests through the Adventure
Creator coordinator on 2026-10-13. Worktree: `.claude/worktrees/verified-review-references`,
branch `feat/verified-review-references`, based on installed source `b1af7bd`.
No converter source, tests, ignored evidence or formal review state was modified.
No converter suite or formal review attempt was run.

## Representation

The opt-in `-VerifiedReferenceFile` manifest binds original base/head, approved
spec path/blob and normalized content SHA-256. Only one complete added spec is
supported. Its complete embedded copy remains in trusted context; only the
duplicate addition body is replaced. Original headers, mode, blob/index and hunk
identity remain visible. A notice instructs review of the embedded content as
both the control and added artifact. All other sections retain identical
normalized content and are individually covered by hashes in immutable attempt
metadata. Original diff, rendered diff, manifest, preamble and payload hashes are
retained. Only CRLF-to-LF normalization is allowed; standalone CRs are refused.
The rendered carry-over hash records exactly the transmitted text, alongside its
original rendered hash. Canonical finding text and history remain unchanged.

Read-only converter check used base `97bae6f4bd8d4657b181e1335055844fc914f7fb`,
head `d2db8c098fc122e40ba0f3fcf1e27004f85b592b`, approved spec blob
`0db38ced6bbe83af529fbb9bd8884e8fa1189696`, and normalized SHA-256
`acf2d43ecd9e7961a03d82f7ff900270dfddeab27dd72c5c9ed727cb4b2aee6c`.
The actual renderer verified 171 sections: exactly one referenced and all 170
others unchanged. All 17 carry-over entries validated. The final opt-in renderer,
including trailing preamble newlines, measured **1,030,118 UTF-8 bytes** and
**1,029,691 characters**. Fully rendered payload SHA-256:
`2684868fe8b12c72e3bdd933adac1b465af5affb532bea6fed165714cc7cd10a`.
Callers must remeasure the fully rendered payload before dispatch after any change.
The byte/character limit remains 1,048,576 for the user's authorized run.

## Capacity blocker: do not dispatch

The pinned binary remains Codex CLI 0.162.0-alpha.17.2, SHA-256
`d13914ced6c7af174d8d638db938284231227312104b06a25e9608c632a7daec`,
model `gpt-6.1-sol`, reasoning `xhigh`. Its refreshed catalog currently reports
500,000 context tokens and 95% effective context. Its bundled catalog reports
272,000 and 95%, including when queried with a unique empty CODEX_HOME, no
credential copies and no ambient configuration. `debug models` does not support
the review's `--ignore-user-config` flag, so a refreshed catalog alone is not
proof of the sealed invocation's effective capacity. The new route refuses
catalog disagreement before harness/attempt allocation. The installed stack has
not been replaced or recertified for these source changes.

With the unchanged output reserve of 128,000 and required 25% context headroom:

- Refreshed: floor(500,000 * .95) = 475,000 effective tokens;
  floor(475,000 * .75) - 128,000 = **228,250 maximum input tokens**.
- Bundled: floor(272,000 * .95) = 258,400 effective tokens;
  floor(258,400 * .75) - 128,000 = **65,800 maximum input tokens**.
- Earlier manifest basis: .75 * 1,050,000 - 128,000 = 659,500. This is not
  accepted as actual CLI capacity by the opt-in route.

The converter's saved round-1 attempt-2 input count is **233,439**, for a smaller
883,413-byte prompt. It exceeds both current ceilings. The new complete prompt's
exact token count is unknown; bytes do not establish a token count or prove that
it fits. Matching catalogs would still require the completed request's own usage
to satisfy the stricter calculated ceiling before canonical verdict acceptance.

Required decision: pause until larger sealed capacity is independently verified,
or separately authorize a complete-material multi-request protocol. Reducing the
output reserve, relaxing headroom, substituting models or accepting the old
1,050,000 basis is outside this authorization. Do not spend the converter's
reserved formal attempt as a capacity experiment.

Additional supported-mechanism checks: `exec --help`, `debug models --help`,
`debug --help`, and `debug app-server send-message-v2 --help` were inspected.
`debug models` rejects `--ignore-user-config`; a separate app-server invocation
would not establish the exact sealed exec profile's selected context.
A tiny live diagnostic fixture used the installed New-CodexArgs and
Get-InvocationAudit, pinned binary, model and xhigh, existing schema, an owned
empty external harness, ephemeral execution, disabled tools and bounded process
runner. Only Rust diagnostic logging was added to its child environment. It
completed with exit 0, valid usage (16,211 input tokens), and confirmed process
tree retirement. Profile SHA-256 was
`0371e7a39b1ef80db5a3da30bb4797a038d08bc8246cb02fbeb438a0173458c0`.
Neither its JSON events nor diagnostic output exposed a resolved context-window
field. Therefore this probe does not justify choosing 500,000 over 272,000.
Sanitized fixture evidence is retained at
`%LOCALAPPDATA%/gauntlet-review/diagnostics/capacity-36382536ccbb46b89b1c711455c40897/capacity-evidence.json`.
No shared premises or live-evidence stamp was changed by this fixture.

## Verification

- Reference and capacity tests: 41 passed, 0 failed, including actual-entry-point
  refusal before CLI discovery and attempt creation, five actual capacity-block
  cases with offline process stubs, immutable coverage serialization, altered
  blobs/headers/hunks/context, and source material preservation.
- Prompt-preflight tests: 92 passed, 0 failed. Existing extracted render-block
  fixture initializes the new optional parameter under strict mode.
- Independent read-only review identified three issues: ambient config in the
  catalog probe, the optional-variable fixture and pre-attempt behavior tests.
  The bundled probe now uses an empty home and catalog disagreement is refused;
  the fixture and behavioral checks are included above.
- Full PowerShell offline suite: **1,478 passed, 0 failed**, with all test files
  passing. No live security certification or install was attempted for this
  uninstalled candidate. The separate tiny capacity fixture is described above.

After the capacity decision, the coordinator must finish the ordinary code review
and recertify/install the changed stack once. Then the converter owner can use
its existing invocation, adding `-VerifiedReferenceFile <approved manifest>` while
retaining original state, round 2, base/head, preamble, ledger, pin, harness,
`-TimeoutSec 3600` and `-BudgetBytes 1048576`. This is an invocation shape for a
future supported route, not permission to dispatch while capacity is unresolved.
