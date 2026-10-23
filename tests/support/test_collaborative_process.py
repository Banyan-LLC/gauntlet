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
import signal
import time
import unittest
from unittest import mock

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
        result = self.case("stdin-closed", GAUNTLET_TEST_STDIN="x" * 32768,
                           GAUNTLET_TEST_STDIN_AFTER_CHECKPOINT="stdin-closed")
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

    def protected_thread_case(self, *, primary=False, recover=False, rollback=False):
        """Refuse a real CloseHandle, then explicitly retire the protected handle."""
        api=self.api
        create,close,resume=api._create_process,api._close,api._resume
        terminate=api._terminate_process
        initialize,pipe_initialize=api.NativeChild.__init__,api.RawPipe.__init__
        handles=[]; children=[]; pipes=[]; attempts=[]; observed={}

        def created(*args):
            result=create(*args)
            if result:
                handles.append(args[-1]._obj.hThread)
            return result

        def closing(handle):
            if handle in handles:
                previous=sum(row["handle"]==handle for row in attempts)
                if not previous:
                    api._check(api._handle_info(handle,2,2))
                elif recover:
                    api._check(api._handle_info(handle,2,0))
                result=close(handle)
                attempts.append({"handle":handle,"closed":bool(result),
                                 "winerror":None if result else api.ctypes.get_last_error()})
                return result
            return close(handle)

        def initialized(child,*args,**kwargs):
            children.append(child)
            initialize(child,*args,**kwargs)

        def pipe_initialized(pipe,*args,**kwargs):
            pipes.append(pipe)
            pipe_initialize(pipe,*args,**kwargs)

        def resumed(handle):
            if primary:
                raise RuntimeError("injected resume primary")
            return resume(handle)

        def terminated(handle,code):
            if rollback:
                raise OSError("injected rollback termination")
            return terminate(handle,code)

        try:
            with mock.patch.object(api,"_create_process",created), \
                    mock.patch.object(api,"_close",closing), \
                    mock.patch.object(api,"_resume",resumed), \
                    mock.patch.object(api,"_terminate_process",terminated), \
                    mock.patch.object(api.NativeChild,"__init__",initialized), \
                    mock.patch.object(api.RawPipe,"__init__",pipe_initialized):
                result=self.case("success",seconds=5)
                child=children[0]
                observed.update({"attempts":attempts,
                    "thread":getattr(child,"thread",None),
                    "process":child.process,"job":child.job,
                    "retained_valid":[bool(api._handle_info(handle,0,0)) for handle in handles],
                    "all_pipes_closed":all(pipe.child_closed and pipe.parent_closed for pipe in pipes)})
        finally:
            cleaned=[]
            for handle in handles:
                if api._handle_info(handle,0,0):
                    api._check(api._handle_info(handle,2,0))
                    child=children[0]
                    if getattr(child,"thread",None)==handle:
                        child.close()
                    else:
                        api._check(close(handle))
                    cleaned.append(not bool(api._handle_info(handle,0,0)))
            observed["explicit_cleanup_closed"]=cleaned
            (self.evidence/"thread-close-observation.json").write_text(
                json.dumps(observed,indent=2)+"\n",encoding="utf-8")
        return result,observed

    @unittest.skipUnless(os.name=="nt","real Windows protected thread handle")
    def test_startup_thread_close_refusal_is_failed_and_handle_retained(self):
        result,observed=self.protected_thread_case()
        self.assert_failure(result)
        self.assertTrue(result.root_reaped and result.tree_retired)
        self.assertTrue(any("WinError 6" in str(error) for error in result.errors))
        self.assertTrue(any("WinError 6" in str(error) for error in result.cleanup_errors))
        self.assertEqual(observed["thread"],observed["attempts"][0]["handle"])
        self.assertIsNone(observed["process"])
        self.assertIsNone(observed["job"])
        self.assertTrue(observed["all_pipes_closed"])
        self.assertEqual(observed["retained_valid"],[True])
        self.assertEqual(observed["explicit_cleanup_closed"],[True])

    @unittest.skipUnless(os.name=="nt","real Windows protected thread handle")
    def test_startup_primary_survives_actual_thread_close_refusal(self):
        result,observed=self.protected_thread_case(primary=True)
        self.assert_failure(result)
        self.assertTrue(result.root_reaped and result.tree_retired)
        self.assertTrue(any("injected resume primary" in str(error) for error in result.errors))
        self.assertTrue(any("WinError 6" in str(error) for error in result.errors))
        self.assertTrue(any("WinError 6" in str(error) for error in result.cleanup_errors))
        self.assertIsNone(observed["process"])
        self.assertIsNone(observed["job"])
        self.assertTrue(observed["all_pipes_closed"])
        self.assertEqual(observed["explicit_cleanup_closed"],[True])

    @unittest.skipUnless(os.name=="nt","real Windows protected thread handle")
    def test_startup_close_refusal_remains_failed_after_later_closure(self):
        result,observed=self.protected_thread_case(recover=True)
        self.assert_failure(result)
        self.assertTrue(result.root_reaped and result.tree_retired)
        self.assertTrue(any("WinError 6" in str(error) for error in result.errors))
        self.assertNotIn("handle-close",[error.stage for error in result.cleanup_errors])
        self.assertIsNone(observed["thread"])
        self.assertIsNone(observed["process"])
        self.assertIsNone(observed["job"])
        self.assertEqual([row["closed"] for row in observed["attempts"]],[False,True])
        self.assertEqual(observed["retained_valid"],[False])
        self.assertTrue(observed["all_pipes_closed"])

    @unittest.skipUnless(os.name=="nt","real Windows protected thread handle")
    def test_startup_primary_survives_rollback_and_thread_close_refusals(self):
        result,observed=self.protected_thread_case(primary=True,rollback=True)
        self.assert_failure(result)
        self.assertTrue(result.root_reaped and result.tree_retired)
        for detail in ("injected resume primary","injected rollback termination","WinError 6"):
            self.assertTrue(any(detail in str(error) for error in result.errors),detail)
        self.assertTrue(result.cleanup_errors)
        self.assertIsNone(observed["process"])
        self.assertIsNone(observed["job"])
        self.assertTrue(observed["all_pipes_closed"])
        self.assertEqual(observed["explicit_cleanup_closed"],[True])

    def test_unstarted_stdin_thread_still_closes_and_persists_failed_outcome(self):
        with mock.patch.object(self.api.threading.Thread,"start",side_effect=RuntimeError("injected writer start failure")):
            result=self.case("sleep",seconds=3)
        self.assert_failure(result)
        self.assertTrue(result.root_reaped and result.tree_retired and result.writer_settled)
        self.assertTrue(any("writer start failure" in error.detail for error in result.errors))

    def test_pipe_setup_failure_closes_both_allocated_endpoints(self):
        if os.name=="nt":
            handles=[]
            original=self.api._create_pipe
            def allocate(rd,wr,*args):
                result=original(rd,wr,*args)
                handles.extend([rd._obj.value,wr._obj.value])
                return result
            with mock.patch.object(self.api,"_create_pipe",allocate),mock.patch.object(self.api,"_handle_info",return_value=False):
                with self.assertRaises(OSError):
                    self.api.RawPipe()
            for handle in handles:
                self.assertFalse(self.api._handle_info(handle,0,0),"allocated pipe handle leaked")
                self.assertEqual(self.api.ctypes.get_last_error(),6)
        else:
            descriptors=[]
            original=os.pipe
            def allocate():
                value=original(); descriptors.extend(value); return value
            with mock.patch.object(os,"pipe",allocate),mock.patch.object(os,"set_inheritable",side_effect=OSError("injected pipe setup")):
                with self.assertRaises(OSError):
                    self.api.RawPipe()
            for descriptor in descriptors:
                with self.assertRaises(OSError):
                    os.fstat(descriptor)

    def test_nested_receipt_write_failure_cannot_allow_worker_continuation(self):
        result=self.case("nested-save-failure",seconds=5)
        self.assert_failure(result)
        self.assertNotIn(b"continued",result.stdout.prefix)
        self.assertIn(b"ValueError",result.stderr.prefix)
        self.assertIn(b"receipt",result.stderr.prefix)

    @unittest.skipUnless(importlib.util.find_spec("mcp"),"optional SDK not installed")
    def test_transport_diagnostic_and_cleanup_failures_are_always_terminal(self):
        for failure in ("save","poll","close"):
            with self.subTest(failure=failure):
                result=self.case("mcp-fatal-"+failure,seconds=8)
                self.assert_failure(result)
                self.assertNotIn(b"continued",result.stdout.prefix)
                self.assertTrue(result.root_reaped and result.tree_retired)
                if failure=="close":
                    self.assertIn(b"handle-close-attempt",result.control.prefix)

    def test_nested_owner_inherits_deadline_and_no_new_job(self):
        result = self.case("nested-success")
        self.assertTrue(result.completed, result)
        data = json.loads(result.stdout.prefix)
        self.assertEqual(data["token"], data["child_token"])
        self.assertEqual(data["deadline"], data["child_deadline"])
        self.assertFalse(data["fresh_owner"])

    def assert_cutoff_refusal(self,scenario,*,completion=False):
        result=self.case("cutoff-"+scenario,seconds=10)
        self.assert_failure(result)
        self.assertNotIn(b"continued",result.stdout.prefix)
        self.assertNotIn(b"actual-late-launch",result.control.prefix)
        self.assertFalse((self.evidence/"forbidden-launch.txt").exists())
        self.assertTrue(result.root_reaped and result.tree_retired,result)
        receipts=[json.loads(p.read_text("utf-8")) for p in self.evidence.glob("*-receipt.json")]
        nested=[item for item in receipts if not item["fresh_owner"]]
        self.assertTrue(any(not item["completed"] and item["timed_out"] for item in nested),nested)
        if completion:
            self.assertTrue(any(item["exit_code"]==0 and item["timed_out"] for item in nested),nested)
        else:
            self.assertTrue(all(not item["started"] and item["exit_code"] is None for item in nested),nested)

    def test_execution_cutoff_refuses_nested_launch(self):
        self.assert_cutoff_refusal("nested-admission")

    def test_execution_cutoff_refuses_late_real_exit_success(self):
        self.assert_cutoff_refusal("nested-completion",completion=True)

    @unittest.skipUnless(importlib.util.find_spec("mcp"),"optional SDK not installed")
    def test_execution_cutoff_refuses_transport_launch(self):
        self.assert_cutoff_refusal("transport-admission")

    @unittest.skipUnless(importlib.util.find_spec("mcp"),"optional SDK not installed")
    def test_execution_cutoff_refuses_transport_closure_after_cutoff(self):
        self.assert_cutoff_refusal("transport-completion",completion=True)

    @unittest.skipUnless(os.name=="posix","legacy session wrapper is installed only on POSIX")
    def test_execution_cutoff_refuses_legacy_launch_and_late_ack(self):
        for scenario in ("legacy-direct","legacy-ack"):
            with self.subTest(scenario=scenario):
                self.assert_cutoff_refusal(scenario)

    def test_execution_cutoff_preserves_cleanup_and_pre_cutoff_success(self):
        control=self.case("cutoff-nested-control",seconds=10)
        self.assertTrue(control.completed,control)
        self.assertEqual(json.loads(control.stdout.prefix),{"completed":True,"exit_code":0})
        cleanup=self.case("cutoff-cleanup-checkpoint",seconds=10)
        self.assertTrue(cleanup.completed,cleanup)
        self.assertIn(b"cleanup-reserve-checkpoint",cleanup.control.prefix)
        self.assertIn(b"cleanup-usable",cleanup.stdout.prefix)

    def test_nested_fatal_error_stops_enclosing_worker(self):
        result = self.case("nested-failure")
        self.assert_failure(result)
        self.assertNotIn(b"continued", result.stdout.prefix)
        self.assertTrue(result.tree_retired)

    def test_nested_receipt_directory_failure_cannot_continue(self):
        result=self.case("nested-mkdir-failure")
        self.assert_failure(result)
        self.assertNotIn(b"continued",result.stdout.prefix)
        self.assertIn(b"FileExistsError",result.stderr.prefix)
        self.assertTrue(result.root_reaped and result.tree_retired)

    def test_receipt_directory_failure_retains_structured_outcome(self):
        blocked=self.evidence/"not-directory"
        blocked.write_bytes(b"original")
        environment=dict(os.environ,GAUNTLET_TEST_RECEIPTS=str(blocked))
        environment.pop("GAUNTLET_TEST_OWNER",None)
        with self.assertRaises(self.api.CommandFailure) as caught:
            self.api.run_case([],cwd=HERE,environment=environment,deadline_seconds=2)
        result=caught.exception.outcome
        self.assertFalse(result.started or result.completed)
        self.assertTrue(any(error.exception_type=="FileExistsError" for error in result.errors))
        self.assertEqual(blocked.read_bytes(),b"original")

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

    @unittest.skipUnless(importlib.util.find_spec("openai_codex"),"optional Codex SDK not installed")
    def test_outer_expiry_retires_real_sdk_and_reviewer_mcp(self):
        result=self.case("sdk-real-expiry",seconds=30)
        self.assert_failure(result)
        self.assertTrue(result.timed_out and result.root_reaped and result.tree_retired,result)
        self.assertIn(b"sdk-ready",result.stdout.prefix)

    @unittest.skipUnless(os.name=="posix","native changed-group custody is POSIX")
    def test_native_changed_group_is_retired_after_root_and_pipes_close(self):
        result=self.case("changed-group",seconds=4)
        records=[json.loads(line) for line in result.control.prefix.splitlines()]
        record=next(item for item in records if item["checkpoint"]=="changed-group-ready")
        try:
            self.assertNotEqual(record["group"],record["session"])
            self.assert_failure(result)
            self.assertTrue(result.root_reaped and result.tree_retired,result)
            self.assertIn(record["group"],result.ownership_inventory["observed_groups"])
            for pid in record["pids"]:
                while time.monotonic()<result.deadline:
                    try:
                        os.kill(pid,0)
                    except ProcessLookupError:
                        break
                    time.sleep(.005)
                with self.assertRaises(ProcessLookupError):
                    os.kill(pid,0)
        finally:
            # A RED regression must not abandon the deliberately escaped group.
            try:
                os.killpg(record["group"],signal.SIGKILL)
            except ProcessLookupError:
                pass

    @unittest.skipUnless(os.name=="posix","legacy separate-session custody is POSIX; Windows uses the enclosing job")
    def test_outer_expiry_retires_legacy_sut_separate_session_and_descendant(self):
        result=self.case("legacy-session-expiry",seconds=4)
        self.assert_failure(result)
        self.assertTrue(result.timed_out and result.root_reaped and result.tree_retired,result)
        self.assertTrue(result.ownership_inventory["registered_groups"])
        self.assertFalse(result.ownership_inventory["pending_sessions"])

    @unittest.skipUnless(os.name=="posix","POSIX session registration protocol")
    def test_unconfirmed_session_launch_cannot_claim_complete_retirement(self):
        result=self.case("legacy-pending",seconds=4)
        self.assert_failure(result)
        self.assertFalse(result.tree_retired)
        self.assertTrue(result.ownership_inventory["pending_sessions"])

    @unittest.skipUnless(importlib.util.find_spec("mcp"), "optional SDK not installed")
    def test_cancelled_transport_teardown_cannot_record_success_or_continue(self):
        result=self.case("mcp-teardown-deadline",seconds=10)
        self.assertIn(b"teardown-deadline-injected",result.control.prefix)
        self.assert_failure(result)
        self.assertNotIn(b"continued",result.stdout.prefix)
        self.assertTrue(result.root_reaped and result.tree_retired,result)
        receipts=[json.loads(p.read_text("utf-8")) for p in self.evidence.glob("*-receipt.json")]
        self.assertTrue(any(not item["fresh_owner"] and not item["completed"] for item in receipts))

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
