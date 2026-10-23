# SDD ledger — plan: docs/superpowers/plans/2026-10-20-reduced-mcp-core.md

Execution: native inline, authorized 2026-10-21. Initial clean HEAD f94da93dbde3a21a269cfb7ed7caf582c3fd7e99. Branch feat/reduced-mcp-core. Target main; no approval or merge.

Ruling: Retain this workspace and every receipt instead of deleting skill scratch at completion — the Human Overlord explicitly requires all evidence/history preserved — cost if wrong: retained disk usage.

Pre-flight shared interfaces:
| Producer → consumer | Contract checked | Result |
| --- | --- | --- |
| 0 → 1,6,7,8 | stdlib owner, inherited absolute deadline/budget, OwnedTransport, persisted partial receipts | consistent; optional SDK import remains lazy |
| 1 → 2,3,4,5,6 | strict models/config/policy/JCS/errors | consistent; native absolute validation precedes resource access |
| 2 → 3,5 | resolved common-Git binding, snapshot/handles/whole-object validation | consistent; binding checked before retries |
| 3 → 4,5 | immutable events/SeriesView, mutation callback, exact retries/global version | consistent; receipts revalidated, not just hashed |
| 4 → 5 | normalized verdict, complete carryover/coverage, compact findings/status | consistent; fresh latest approval required |
| 5 → 6 | five async operations and domain envelopes | consistent; raw args validated by core as well as adapter |
| 0,1–6 → 7 | real SDK owned stdio, recovery and matrix | consistent; fatal probes run external controller |
| 1–7 → 8 | operator configuration, limits, actual evidence | consistent; unsupported/unrun platforms reported incomplete |

Task 0: in progress; BASE f94da93dbde3a21a269cfb7ed7caf582c3fd7e99. Brief read. Test owner is outside installed package.
Task 0: Windows native owner probes: 22/22 pass (task0-all-v2). Includes inherited-pipe descendants, exact exit/checkpoint, capture overflow, cancellation, failed cleanup, nested custody/budget and real SDK transport/frame cap.
Task 0: Baseline legacy Python suite completed with actual exit 0 and confirmed tree retirement (legacy-python-baseline-v1); four inherited skips. Product modules unchanged.
Task 0: Ruling: Install the unchanged direct pins from a local hash-checked wheelhouse after pip's simple-index HTTP responses repeatedly failed chunk decoding — PyPI JSON and wheel routes work with certificate validation; preserve all failed attempts and helper versions — cost if wrong: local environment may differ in transitive versions, so freeze and verify it separately per runtime.
Task 0: Cross-platform capability remains pending: Windows probes gate Windows spawned tests; Linux/macOS must pass the same external-controller probes in their matrix jobs before spawned acceptance tests. No cross-platform success is claimed here.
Task 0: Bootstrap provenance: the preserved v9 Windows owner supervised initial RED/GREEN probe controllers. Its enclosing job retained the new private nested jobs; all original wrappers report actual exit/closure. Future probes run as external controllers, not recursively inside their own run_case.
Task 0: Environment: Python 3.14.6, Windows 11 build 26200, SQLite 3.50.4; exact pip freeze and metadata/wheel provenance retained under common Git info/reduced-mcp-core/20261021-execution.
