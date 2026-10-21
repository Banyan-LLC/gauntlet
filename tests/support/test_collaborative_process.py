"""Fatal ownership probes: call from the external controller, never its worker.

Each assertion catches loss of an observable ownership/capture guarantee. These
tests use stdlib unittest so they run before installing optional dependencies.
"""
from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))


class ProcessContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.owner_available = importlib.util.find_spec("collaborative_process") is not None
        if cls.owner_available:
            import collaborative_process
            cls.api = collaborative_process

    def setUp(self):
        self.assertTrue(self.owner_available, "test process ownership is not implemented")
        archive = os.environ.get("GAUNTLET_PROBE_ARCHIVE")
        if archive:
            Path(archive).mkdir(parents=True, exist_ok=True)
        self.evidence = Path(tempfile.mkdtemp(prefix="gauntlet-owner-probe-", dir=archive))

    def case(self, scenario, *, seconds=5, expected=None, **extra):
        environment = dict(os.environ)
        environment.pop("GAUNTLET_TEST_OWNER", None)
        environment["GAUNTLET_TEST_RECEIPTS"] = str(self.evidence)
        environment.update(extra)
        argv = [sys.executable, str(HERE / "collaborative_worker.py"), scenario]
        try:
            return self.api.run_case(argv, cwd=HERE, environment=environment,
                                     deadline_seconds=seconds,
                                     expected=expected or self.api.ExpectedExit())
        except self.api.CommandFailure as error:
            return error.outcome

    def assert_failure(self, outcome):
        self.assertFalse(outcome.completed)
        self.assertFalse(outcome.expectation_match)
        self.assertTrue(outcome.receipt_path.is_file())
        saved = json.loads(outcome.receipt_path.read_text("utf-8"))
        self.assertEqual(saved["exit_code"], outcome.exit_code)
        self.assertFalse(saved["completed"])

    def test_success_captures_exact_bytes_and_observed_zero(self):
        result = self.case("success")
        self.assertTrue(result.completed, result)
        self.assertEqual(result.exit_code, 0)
        self.assertEqual(result.stdout.prefix, b"hello\x00\xff\n")
        self.assertEqual(result.stderr.prefix, b"diagnostic\n")
        self.assertTrue(result.root_reaped and result.tree_retired)
        self.assertTrue(result.readers_settled and result.writer_settled)
        self.assertFalse(result.stdout.incomplete)

    def test_missing_executable_does_not_synthesize_exit(self):
        environment = dict(os.environ, GAUNTLET_TEST_RECEIPTS=str(self.evidence))
        environment.pop("GAUNTLET_TEST_OWNER", None)
        with self.assertRaises(self.api.CommandFailure) as caught:
            self.api.run_case([str(self.evidence / "nonexistent-command")], cwd=HERE,
                              environment=environment, deadline_seconds=5,
                              expected=self.api.ExpectedExit())
        result = caught.exception.outcome
        self.assert_failure(result)
        self.assertFalse(result.started)
        self.assertIsNone(result.exit_code)
        self.assertEqual(result.errors[0].stage, "launch")

    def test_unexpected_nonzero_preserves_actual_exit(self):
        result = self.case("crash")
        self.assert_failure(result)
        self.assertEqual(result.exit_code, 73)

    def test_expected_crash_requires_checkpoint_as_well_as_exit(self):
        result = self.case("crash", expected=self.api.ExpectedExit(73, "before-commit"))
        self.assertTrue(result.completed, result)
        self.assertEqual(result.exit_code, 73)
        self.assertIn(b"before-commit", result.control.prefix)
        missing = self.case("crash-no-checkpoint",
                            expected=self.api.ExpectedExit(73, "before-commit"))
        self.assert_failure(missing)

    def test_timeout_has_one_deadline_and_retires_tree(self):
        result = self.case("sleep", seconds=2)
        self.assert_failure(result)
        self.assertTrue(result.timed_out)
        self.assertTrue(result.termination_requested)
        self.assertTrue(result.root_reaped and result.tree_retired)
        self.assertLess(result.elapsed_seconds, 2.5)

    def test_stdout_overflow_stops_before_deadline(self):
        result = self.case("stdout-overflow", seconds=10)
        self.assert_failure(result)
        self.assertTrue(result.overflowed)
        self.assertLessEqual(result.stdout.retained_bytes, 4 * 1024 * 1024)
        self.assertTrue(result.stdout.incomplete)
        self.assertLess(result.elapsed_seconds, 5)

    def test_stderr_overflow_stops_before_deadline(self):
        result = self.case("stderr-overflow", seconds=10)
        self.assert_failure(result)
        self.assertTrue(result.overflowed)
        self.assertLessEqual(result.stderr.retained_bytes, 4 * 1024 * 1024)

    def test_control_overflow_stops_before_deadline(self):
        result = self.case("control-overflow", seconds=10)
        self.assert_failure(result)
        self.assertTrue(result.overflowed)
        self.assertLessEqual(result.control.retained_bytes, 64 * 1024)

    def test_combined_capture_reservation_refuses_excess(self):
        result = self.case("combined-overflow", seconds=10)
        self.assert_failure(result)
        self.assertTrue(result.overflowed)
        self.assertLessEqual(sum(c.retained_bytes for c in
                                 (result.stdout, result.stderr, result.control)), 8 * 1024 * 1024)

    def test_parent_exit_cannot_hide_descendant_holding_pipe(self):
        for channel in ("stdin", "stdout", "stderr"):
            with self.subTest(channel=channel):
                result = self.case("descendant-" + channel, seconds=3)
                self.assert_failure(result)
                self.assertTrue(result.termination_requested)
                self.assertTrue(result.root_reaped and result.tree_retired)

    def test_read_failure_is_structured_and_not_success(self):
        result = self.case("success", GAUNTLET_TEST_FAULT="read")
        self.assert_failure(result)
        self.assertIn("read", [error.stage for error in result.errors])
        self.assertTrue(result.tree_retired)

    def test_stdin_write_failure_is_structured(self):
        result = self.case("stdin-closed", GAUNTLET_TEST_STDIN="x" * 32768)
        self.assert_failure(result)
        self.assertIn("write", [error.stage for error in result.errors])

    def test_cancel_requests_tree_retirement(self):
        result = self.case("sleep", GAUNTLET_TEST_FAULT="cancel", seconds=3)
        self.assert_failure(result)
        self.assertTrue(result.cancelled)
        self.assertTrue(result.root_reaped and result.tree_retired)

    def test_failed_retirement_is_never_reported_success(self):
        result = self.case("success", GAUNTLET_TEST_FAULT="retirement")
        self.assert_failure(result)
        self.assertFalse(result.tree_retired)
        self.assertTrue(result.cleanup_errors)

    def test_failed_cleanup_is_never_reported_success(self):
        result = self.case("success", GAUNTLET_TEST_FAULT="cleanup")
        self.assert_failure(result)
        self.assertTrue(result.cleanup_errors)

    def test_nested_owner_inherits_deadline_and_no_new_job(self):
        result = self.case("nested-success")
        self.assertTrue(result.completed, result)
        data = json.loads(result.stdout.prefix)
        self.assertEqual(data["token"], data["child_token"])
        self.assertEqual(data["deadline"], data["child_deadline"])
        self.assertFalse(data["fresh_owner"])

    def test_nested_fatal_error_stops_enclosing_worker(self):
        result = self.case("nested-failure")
        self.assert_failure(result)
        self.assertNotIn(b"continued", result.stdout.prefix)
        self.assertTrue(result.tree_retired)

    def test_nested_context_cannot_be_replaced_or_start_a_fresh_owner(self):
        for scenario in ("nested-fresh-session", "nested-context-mismatch"):
            with self.subTest(scenario=scenario):
                result = self.case(scenario)
                self.assert_failure(result)
                receipts = [json.loads(p.read_text("utf-8")) for p in self.evidence.glob("*-receipt.json")]
                self.assertTrue(any(not r["fresh_owner"] and not r["started"] and r["errors"]
                                    for r in receipts))

    def test_nested_commands_share_worker_capture_reservations(self):
        result = self.case("nested-budget", seconds=15)
        self.assert_failure(result)
        self.assertNotIn(b"continued", result.stdout.prefix)
        receipts = [json.loads(p.read_text("utf-8")) for p in self.evidence.glob("*-receipt.json")]
        nested = [r for r in receipts if not r["fresh_owner"]]
        self.assertEqual(len(nested), 3)
        self.assertEqual(sum(r["completed"] for r in nested), 2)
        self.assertTrue(any(r["overflowed"] for r in nested))
        self.assertLessEqual(sum(r[c]["retained_bytes"] for r in nested for c in
                                 ("stdout", "stderr", "control")), 8 * 1024 * 1024)

    def test_outer_expiry_retires_two_hosts_and_pipe_descendants(self):
        result = self.case("matrix-expiry", seconds=3)
        self.assert_failure(result)
        self.assertTrue(result.timed_out)
        self.assertTrue(result.root_reaped and result.tree_retired)
        self.assertEqual(result.stdout.prefix.count(b"host-ready"), 2)

    @unittest.skipUnless(importlib.util.find_spec("mcp"), "optional SDK not installed")
    def test_sdk_transport_roundtrip_and_normal_shutdown(self):
        result = self.case("mcp-roundtrip", seconds=10)
        self.assertTrue(result.completed, result)
        self.assertIn(b"probe-tool", result.stdout.prefix)

    @unittest.skipUnless(importlib.util.find_spec("mcp"), "optional SDK not installed")
    def test_outer_expiry_retires_real_mcp_peers_and_pipe_fault_descendants(self):
        result = self.case("mcp-real-expiry", seconds=10)
        self.assert_failure(result)
        self.assertTrue(result.timed_out)
        self.assertTrue(result.root_reaped and result.tree_retired)
        self.assertEqual(result.stdout.prefix.count(b"host-ready"), 2)

    @unittest.skipUnless(importlib.util.find_spec("mcp"), "optional SDK not installed")
    def test_first_peer_can_close_while_second_remains_usable(self):
        result = self.case("mcp-sibling-closure", seconds=12)
        self.assertTrue(result.completed, result)
        self.assertIn(b"both-peers-closed", result.stdout.prefix)

    @unittest.skipUnless(importlib.util.find_spec("mcp"), "optional SDK not installed")
    def test_sdk_transport_refuses_oversized_frame_before_parsing(self):
        result = self.case("mcp-frame-overflow", seconds=10)
        self.assert_failure(result)
        receipts = [json.loads(p.read_text("utf-8")) for p in self.evidence.glob("*-receipt.json")]
        self.assertTrue(any(r["overflowed"] and any(e["stage"] == "protocol" for e in r["errors"])
                            for r in receipts))


if __name__ == "__main__":
    if os.environ.get("GAUNTLET_TEST_OWNER"):
        raise SystemExit("fatal ownership probes must run in the external controller")
    unittest.main()
