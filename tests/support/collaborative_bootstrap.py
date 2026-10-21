"""POSIX-only session bootstrap; all application subprocesses inherit custody."""
import json
import os
import sys

status_fd=int(os.environ.pop("GAUNTLET_TEST_EXEC_STATUS"))
try:
    # EOF after ready means exec closed this descriptor. A failed exec writes
    # its actual exception separately; bootstrap exit is not workload exit.
    os.set_inheritable(status_fd,False)
    context = json.loads(os.environ.pop("GAUNTLET_TEST_BOOTSTRAP_CONTEXT"))
    context["group"] = os.getpgrp()
    os.environ["GAUNTLET_TEST_OWNER"] = json.dumps(context, separators=(",", ":"))
    os.write(status_fd,b"ready\n")
    os.execvpe(sys.argv[1], sys.argv[1:], os.environ)
except BaseException as error:
    detail=str(error).encode("utf-8","backslashreplace")[:128].decode("utf-8","ignore")
    packet=json.dumps({"exception_type":type(error).__name__[:64],"errno":getattr(error,"errno",None),
                       "detail":detail},ensure_ascii=True,separators=(",",":")).encode()+b"\n"
    try:
        os.write(status_fd,packet)
    finally:
        os._exit(72)
