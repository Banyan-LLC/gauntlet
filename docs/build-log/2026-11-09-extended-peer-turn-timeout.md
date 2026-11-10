# Explicit override for longer peer turns

The SDK adapter refuses any turn deadline above 1800 seconds. A peer review of a
277 KB plan reached that 30-minute deadline before submitting, and the only way to
continue was to split the review into several 30-minute turns in one conversation.
Starting the peer with `--timeout-seconds 5400` exited at startup with the generic
`CONFIGURATION_OR_RUNTIME_ERROR`, which did not say why or what to do. The owner
asked for a longer turn as an explicit operator choice rather than a workaround.

`--allow-extended-timeout` is that choice. It raises only the ceiling, from 1800
to 7200 seconds; the 10-second minimum, the five-second close reserve and every
other limit are unchanged. The adapter (`gauntlet-codex`) takes it, and so does the
launcher's `peer` role, which checks the value against the adapter's own bounds and
forwards the flag. The engine stays the one place the bounds live
(`TIMEOUT_MIN`, `TIMEOUT_MAX`, `EXTENDED_TIMEOUT_MAX`, `timeout_refusal`).

Without the flag nothing changes for an accepted value: the launcher hands the
adapter the same arguments, writes the same `launch.log` line, and `codex_status`
returns the same four fields. A value over 1800 is still refused, now by the
launcher before it creates anything, with `TIMEOUT_OUT_OF_RANGE` on stderr. That
body carries fixed fields only: the accepted range and, for a value the override
would accept, the flag and its 7200 ceiling. `launch.log` records the refused value
and the flag to add. The adapter run directly prints the same body without
`operation`. Library callers still get `CONFIGURATION_ERROR`, now with cause
`timeout_range`.

With the flag, the launcher's `launch.log` line for that peer ends with
`timeout_seconds=N extended_timeout=on max_seconds=7200`, and `codex_status` adds
`"extended_timeout":{"timeout_seconds":N,"max_seconds":7200}`. `install.ps1` still
registers the default entry, so the override is never on unless the operator edits
the `gauntlet-peer` registration.

## Verification

- New tests: `tests/codex_bridge/test_engine.py` covers the default ceiling (10,
  600 and 1800 accepted with the unchanged four-field status; 1801 and 5400 refused
  with cause `timeout_range`), the override (10, 1800, 5400 and 7200 accepted and
  shown in status), its hard upper bound (7201 and 10800 refused), a strictly boolean
  flag, the 5400-second deadline reaching the turn wait, and every refusal body.
  `tests/codex_bridge/test_server.py` covers the CLI refusing out-of-range values with
  the structured body, passing the timeout and override to the adapter, and
  `codex_status` over MCP with and without the override.
  `tests/collaborative/test_launch.py` covers the launcher forwarding the flag and
  logging it, the core ignoring it, the unchanged default log line, refusals before
  the hand-off that create no state directory, and the launcher and adapter sharing
  one flag spelling.
- End-to-end, through real launcher processes over stdio with a scratch state root
  and no model turn: `--timeout-seconds 5400` alone exits 2 with the opt-in body;
  `7201 --allow-extended-timeout` exits 2 naming only the 7200 ceiling; the default
  peer's `codex_status` has its four fields; `5400 --allow-extended-timeout` adds
  the `extended_timeout` block and the log suffix.
- Windows, Python 3.14.6, `tests/run-collaborative-matrix.py` on 6b7b357 with an
  empty `CODEX_HOME`: custody probes passed (45 run, POSIX-only probes skipped);
  collaborative 298 passed; codex_bridge 141 passed; legacy 145 passed and 7 skipped.
- A plain `pytest` run outside the controller fails only
  `test_live_driver.py::test_altered_regression_tests_cannot_produce_acceptance_evidence`
  ("missing test ownership context"). It fails the same way on unmodified
  `origin/main` and passes under the controller, which provides that context.
