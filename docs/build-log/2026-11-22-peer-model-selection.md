# Operator-selected peer model and reasoning effort

The owner asked for the Codex peer's model to be configurable: "gauntlet can continue to
default to gpt-6.1-sol, but users should have a command to list available models, and switch
the model and effort."

## Why the default had to become explicit

The SDK adapter passed `model=None` to `thread_start` unless an explicit registration gave
`--model`, and the global launcher had no model flag at all. With no model, the Codex runtime
uses the operator's native `~/.codex/config.toml`. On this machine that file sets
`model = "gpt-6.1-sol"` and `model_reasoning_effort = "xhigh"`, which was the only reason
reviews ran on gpt-6.1-sol at xhigh. The live catalog (SDK and runtime 0.163.0, 2026-11-22)
lists `gpt-6.1-terra` as Codex's default model, and gpt-6.1-sol's own default effort is `low`,
so any machine without those two native lines reviewed with a different model at a lower
effort. There was no effort setting anywhere in the adapter.

## Change

- `gauntlet_review/peer_model.py` (stdlib only): the built-in default `gpt-6.1-sol` at
  `xhigh`, and the operator's `<state-root>/peer-model.json` (version 1, a global entry plus
  per-repository entries keyed by the launcher's repository ID, each holding a model, an
  effort or both; fields resolve one at a time). Reads refuse anything but a regular file at
  open time (POSIX `O_NOFOLLOW | O_NONBLOCK`; Windows `CreateFileW` with
  `FILE_FLAG_OPEN_REPARSE_POINT` and handle-attribute checks), so a link, junction, directory
  or FIFO swapped in at any moment is refused and never blocks. Writes validate the complete
  candidate and its exact bytes (64 KiB, 256 repositories) before touching the disk, then
  replace the file atomically with bounded retries for Windows readers.
- `codex_bridge/catalog.py`: Codex's `model/list` with hidden models, and the check of a
  model and effort against it.
- Engine and SDK: `BridgeConfig` gains `effort` and `model_settings_root`. Every turn resolves
  its selection fresh, checks it against the catalog without starting a turn, and passes
  `model` and `effort` to `thread.turn` (and the model to `thread_start`). Four refusals are
  certain and leave the conversation usable: `MODEL_SETTINGS_INVALID`, `MODEL_UNAVAILABLE`,
  `EFFORT_NOT_SUPPORTED` and `CATALOG_UNAVAILABLE`. The SDK client is initialized explicitly
  first, so an initialize failure stays an uncertain, poisoning `SDK_FAILURE` and is never
  mistaken for a catalog answer. `codex_status` and completed replies carry `peer_model`
  (with each field's source, and `rerouted` when Codex rerouted the turn).
- Session servers (merged from PR 22 during this work): each binding's bridge reads the
  settings under the state root for its own repository.
- `gauntlet_review/model_cli.py`: `python -m gauntlet_review.launch models|model` to list,
  show, set and reset, validated against the live catalog, with warnings when a global change
  leaves a repository unsupported.
- `gauntlet-model/` skill: user-only (`disable-model-invocation`), no pre-approved tools; it
  finds the registration in the active profile as the installer does.
- The explicit-tuple adapter gains `--effort` and `--model-settings-root`; with neither model
  flag it now uses the built-in default instead of the native configuration.

## Process

The owner skipped the spec peer review. The plan gate ran three Codex rounds (review series
`cb43253da53340a796bbf17e556cbb7d`): round 1 found three blocking issues (initialize errors
misread as catalog refusals, writes beyond the file's limits, a stat-then-open race and FIFO
blocking) and two important ones (untested atomic-write failures, `CLAUDE_CONFIG_DIR`); round
2 found the text-mode temporary write; round 3 approved with no findings. Because this
session's host-started servers were bound to the main checkout, the gates ran through a
driver that started the installed launcher in this worktree.

## Verification (2026-11-22, Windows 11, MCP venv Python 3.14.6, SDK and runtime 0.163.0)

- Full Python suite from `gauntlet-review/python`: 794 passed, 8 skipped, 1 failed. The failure,
  `tests/codex_bridge/test_live_driver.py::test_altered_regression_tests_cannot_produce_acceptance_evidence`
  ("missing test ownership context"), fails the same way on `main` before this work.
- `pwsh tests/run-tests.ps1`: every file passes except `test-dormant-native.ps1`,
  `test-dormant-scratch-launcher.ps1`, `test-dormant-scratch.ps1`, `test-source-frame-input.ps1`
  and `test-source-line-input.ps1` (legacy-harness process-retirement and positive-control
  assertions this work does not touch). Rerun alone, the two dormant-scratch files pass on this
  branch and on `main` (their first failures came from running beside the full Python suite);
  `test-dormant-native.ps1` (117 passed, 2 failed), `test-source-frame-input.ps1` (11 passed,
  1 failed) and `test-source-line-input.ps1` fail on `main` at 6dbb0b9 as well.
  `test-install-registration.ps1` 118 passed and the new
  `test-gauntlet-model-registration.ps1` 12 passed.
- Live catalog (no model turn), with a scratch state root: `models` listed the real catalog
  (gpt-6.1-terra marked as Codex's default, gpt-6.1-sol marked current); `model gpt-6-sol --effort
  high`, a repository override with `--repo`, `model`, `--json` and `--reset` behaved as specified;
  `gpt-7-imaginary` was `UNKNOWN_MODEL` and `gpt-6-luna --effort ultra` was `EFFORT_NOT_SUPPORTED`.
  The operator's real state root gained no `peer-model.json`.
- Live turn, through this branch's peer session server against a scratch clone and scratch state
  set to gpt-6-sol at high: `codex_status` reported that selection, the turn replied "ready" with
  the same `peer_model`, and Codex's own session record for that thread shows `"model":"gpt-6-sol"`
  and `"effort":"high"` (not the native gpt-6.1-sol at xhigh). An unsupported effort and an
  unknown model written into the file were then refused as `EFFORT_NOT_SUPPORTED` and
  `MODEL_UNAVAILABLE` with `uncertain: false`, and the conversation stayed `ready`.
