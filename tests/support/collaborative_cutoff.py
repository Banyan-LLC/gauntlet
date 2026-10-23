"""Real-child probes with deterministic transitions into the cleanup reserve."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time


def probe(scenario):
    import collaborative_process as api
    context=api.owner_context()

    class Clock:
        offset=0
        sleep=staticmethod(time.sleep)

        def monotonic(self):
            return time.monotonic()+self.offset

        def expire(self):
            self.offset=context["execution_deadline"]+.01-time.monotonic()

    clock=Clock()
    api.time=clock
    marker=Path(context["receipts"])/"forbidden-launch.txt"
    command=[sys.executable,"-c","from pathlib import Path; import sys; Path(sys.argv[1]).write_text('launched')",str(marker)]

    if scenario=="cleanup-checkpoint":
        clock.expire()
        api.checkpoint("cleanup-reserve-checkpoint")
        print("cleanup-usable",flush=True)
        return

    if scenario in {"nested-admission","transport-admission"}:
        initialize=api.NativeChild.__init__
        def expire_at_launch(self,*args,**kwargs):
            clock.expire()
            initialize(self,*args,**kwargs)
            api.checkpoint("actual-late-launch",pid=self.pid)
        api.NativeChild.__init__=expire_at_launch

    if scenario in {"nested-completion","nested-control"}:
        command=[sys.executable,"-c","pass"]
        pipes=[]
        initialize=api.RawPipe.__init__
        def retain_pipe(self,*args,**kwargs):
            initialize(self,*args,**kwargs)
            pipes.append(self)
        api.RawPipe.__init__=retain_pipe
        active=api.NativeChild.active
        def observe_real_retirement(child):
            value=active(child)
            if not value and child.poll() is not None and all(pipe.eof for pipe in pipes[1:]):
                if scenario=="nested-completion":
                    clock.expire()
            return value
        api.NativeChild.active=observe_real_retirement

    if scenario=="transport-completion":
        command=[sys.executable,"-c","pass"]
        close=api.NativeChild.close
        def expire_after_close(child):
            close(child)
            clock.expire()
        api.NativeChild.close=expire_after_close

    try:
        if scenario.startswith("transport-"):
            import anyio
            async def exercise():
                async with api.OwnedTransport(command,cwd=Path(__file__).parent) as (read,write):
                    if scenario=="transport-completion":
                        try:
                            await read.receive()
                        except anyio.EndOfStream:
                            pass
            anyio.run(exercise)
        elif scenario.startswith("legacy-"):
            import collaborative_legacy as legacy
            legacy.time=clock
            launch=legacy.track_sessions(subprocess.Popen)
            separate=scenario=="legacy-ack"
            if separate:
                original=Path.open
                class Ack:
                    def __init__(self,stream): self.stream=stream
                    def __enter__(self): self.stream.__enter__(); return self
                    def __exit__(self,*args): return self.stream.__exit__(*args)
                    def read(self,*args):
                        value=self.stream.read(*args)
                        if value==b"declared\n": clock.expire()
                        return value
                def delayed_ack(path,*args,**kwargs):
                    stream=original(path,*args,**kwargs)
                    return Ack(stream) if path.suffix==".ack" else stream
                Path.open=delayed_ack
            else:
                clock.expire()
            process=launch(command,start_new_session=separate)
            process.wait(timeout=max(.01,context["deadline"]-clock.monotonic()))
        else:
            result=api.run_case(command,cwd=Path(__file__).parent,
                environment=dict(os.environ),deadline_seconds=999)
            if scenario=="nested-control":
                print(json.dumps({"completed":result.completed,"exit_code":result.exit_code}),flush=True)
                return
    except BaseException:
        print("continued-after-exception",flush=True)
    print("continued",flush=True)
