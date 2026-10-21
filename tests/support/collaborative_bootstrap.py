"""POSIX-only session bootstrap; all application subprocesses inherit custody."""
import json
import os
import sys

context = json.loads(os.environ.pop("GAUNTLET_TEST_BOOTSTRAP_CONTEXT"))
context["group"] = os.getpgrp()
os.environ["GAUNTLET_TEST_OWNER"] = json.dumps(context, separators=(",", ":"))
os.execvpe(sys.argv[1], sys.argv[1:], os.environ)
