"""Test-only custody for the legacy SUT's deliberately separate POSIX sessions."""
import os
from pathlib import Path
import signal
import time
import uuid

from collaborative_process import checkpoint,owner_context


def track_sessions(original):
    def launch(*args,**kwargs):
        if os.name!="posix" or not kwargs.get("start_new_session"):
            return original(*args,**kwargs)
        context=owner_context()
        identity=uuid.uuid4().hex
        checkpoint("session-begin",session=identity,parent=os.getpid())
        ack=Path(context["receipts"])/("session-"+context["token"]+"-"+identity+".ack")
        # Do not create a new session until the retained outer owner has seen
        # its pending launch. Lost registration can never imply full retirement.
        while True:
            if time.monotonic()>=context["execution_deadline"]:
                raise TimeoutError("session custody acknowledgement deadline expired")
            try:
                with ack.open("rb") as stream:
                    value=stream.read(10)
                    if not b"declared\n".startswith(value):
                        raise RuntimeError("invalid session custody acknowledgement")
                if value==b"declared\n":
                    break
                time.sleep(min(.002,max(0,context["execution_deadline"]-time.monotonic())))
            except FileNotFoundError:
                time.sleep(min(.002,max(0,context["execution_deadline"]-time.monotonic())))
        try:
            process=original(*args,**kwargs)
        except BaseException:
            checkpoint("session-cancel",session=identity,parent=os.getpid())
            raise
        try:
            checkpoint("session-register",session=identity,parent=os.getpid(),group=process.pid)
        except BaseException:
            # We retain the actual Popen root until registration is delivered.
            # The pending declaration forces an incomplete outer receipt too.
            try:
                os.killpg(process.pid,signal.SIGKILL)
                process.wait(timeout=max(0,context["deadline"]-time.monotonic()))
            finally:
                os._exit(74)
        return process
    return launch
