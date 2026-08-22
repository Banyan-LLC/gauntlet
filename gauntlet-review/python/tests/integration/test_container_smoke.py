import os

import pytest

RUN = os.environ.get("GAUNTLET_RUN_DOCKER_TESTS") == "1"
pytestmark = pytest.mark.skipif(not RUN, reason="set GAUNTLET_RUN_DOCKER_TESTS=1 to run Docker integration")


def _runtime_or_skip():
    from gauntlet_review.runtime import detect_runtime, RuntimeUnavailable
    try:
        return detect_runtime()
    except RuntimeUnavailable:
        pytest.skip("no container runtime available")


def test_build_and_run_one_container_end_to_end(tmp_path):
    rt_name = _runtime_or_skip()
    # 1) Build the pinned image from gauntlet-review/docker/ (records the identity).
    # 2) Stage a real access-only credential via broker.stage_credential (Step-0 provider).
    # 3) run_round(...) against a trivial prompt; assert a verdict.json is retrieved,
    #    exit-status recorded, streams bounded, and the container is removed afterward
    #    (`<rt> ps -a` shows no leftover with the run label).
    # This is the deliberate, usage-consuming integration gate; see the plan for the exact
    # build + credential wiring finalized in Tasks 5 and 7.
    pytest.skip("wire the build + real credential once Tasks 5/7 land on a Docker host")
