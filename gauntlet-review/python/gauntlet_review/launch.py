"""Global host launcher for the collaborative servers.

One user-scope host registration serves every checkout. The host starts this module in the session's working
folder; it derives that session's operator tuple there and then runs the ordinary server entry point in the same
process, so stdio stays connected and the server still has exactly one immutable tuple:

    python -m gauntlet_review.launch core --state-root <dir>
    python -m gauntlet_review.launch peer --state-root <dir> [--timeout-seconds N]

  --repo           the checkout containing the working folder (a linked worktree is its own checkout)
  --source-ref     the branch that checkout has checked out (a detached HEAD is refused)
  --target-ref     origin's default branch (refs/remotes/origin/HEAD), else refs/remotes/origin/main or master
  --repository-id  <owner>-<repository> from origin's URL, else the main checkout's folder name
  --state-dir      <state-root>/<repository-id>--<branch>-<digest>, one private directory per checkout and ref
                   pair (the digest covers the checkout path, both refs and the ID, so a store is never rebound),
                   created on first use and restricted to the current account
  --participant    claude-author with --role author (core), or claude-peer (peer)

Refusals print one fixed code on stderr, as the servers do; the details go to <state-root>/launch.log (bounded),
which the operator owns. A host's explicit project or local registration with the same name takes precedence."""
import argparse, hashlib, json, os, re, stat, subprocess, sys, time
from dataclasses import dataclass
from pathlib import Path

LOG_NAME = "launch.log"
LOG_LIMIT = 1024 * 1024
ID_RE = re.compile(r"[A-Za-z0-9_-]{1,64}")


class LaunchRefused(Exception):
    def __init__(self, code, detail=""):
        super().__init__(code)
        self.code = code
        self.detail = detail


@dataclass(frozen=True)
class LaunchTuple:
    repo: Path
    repository_id: str
    source_ref: bytes
    target_ref: bytes
    state_dir: Path


def _slug(text):
    return re.sub(r"-{2,}", "-", re.sub(r"[^a-z0-9]+", "-", text.lower())).strip("-")


def _repository_id(url, main_checkout):
    match = re.search(r"[:/]([^/:]+)/([^/]+?)(?:\.git)?/*$", url or "")
    text = _slug(f"{match.group(1)}-{match.group(2)}") if match else _slug(main_checkout.name)
    text = text[:64].strip("-") or "repository"
    if not ID_RE.fullmatch(text):
        raise LaunchRefused("UNSUPPORTED_REPOSITORY_ID", text)
    return text


def derive(cwd, state_root):
    """The operator tuple for a session started in cwd, with its state directory under state_root (not created)."""
    try:
        from dulwich.repo import NotGitRepository, Repo
    except ImportError as error:
        raise LaunchRefused("MISSING_EXTRA") from error
    try:
        repo = Repo.discover(str(cwd))
    except NotGitRepository as error:
        raise LaunchRefused("NOT_A_GIT_CHECKOUT", str(cwd)) from error
    try:
        checkout = Path(repo.path).resolve()
        head = repo.refs.read_ref(b"HEAD") or b""
        if not head.startswith(b"ref: refs/heads/"):
            raise LaunchRefused("DETACHED_HEAD", str(checkout))
        source = head[len(b"ref: "):].strip()
        origin_head = repo.refs.read_ref(b"refs/remotes/origin/HEAD") or b""
        if origin_head.startswith(b"ref: refs/remotes/origin/"):
            target = origin_head[len(b"ref: "):].strip()
        else:
            target = next((ref for ref in (b"refs/remotes/origin/main", b"refs/remotes/origin/master")
                           if repo.refs.read_ref(ref) is not None), None)
        if target is None or repo.refs.read_ref(target) is None:
            raise LaunchRefused("NO_TARGET_REF", str(checkout))
        try:
            url = repo.get_config().get((b"remote", b"origin"), b"url").decode("utf-8", "replace")
        except KeyError:
            url = ""
        main_checkout = Path(repo.commondir()).resolve().parent
    finally:
        repo.close()
    repository_id = _repository_id(url, main_checkout)
    branch = source[len(b"refs/heads/"):].decode("utf-8", "replace")
    digest = hashlib.sha256(b"\0".join((os.fsencode(str(checkout)), repository_id.encode("ascii"), source, target))).hexdigest()[:12]
    name = f"{repository_id}--{(_slug(branch) or 'branch')[:48]}-{digest}"
    state = Path(state_root).resolve() / name
    if state == checkout or checkout in state.parents:
        raise LaunchRefused("STATE_INSIDE_REPOSITORY", str(state))
    return LaunchTuple(checkout, repository_id, source, target, state)


def _restrict(path):
    """A directory this launcher just created, restricted to the current account."""
    if os.name == "nt":
        account = f"{os.environ.get('USERDOMAIN', '')}\\{os.environ.get('USERNAME', '')}".lstrip("\\")
        if not os.environ.get("USERNAME"):
            raise LaunchRefused("STATE_NOT_PRIVATE", "no USERNAME to grant")
        result = subprocess.run(["icacls", str(path), "/inheritance:r", "/grant:r", f"{account}:(OI)(CI)F"],
                                capture_output=True, text=True, timeout=30)
        if result.returncode != 0:
            raise LaunchRefused("STATE_NOT_PRIVATE", (result.stdout + result.stderr).strip()[:500])
    else:
        os.chmod(path, 0o700)
        info = os.stat(path)
        if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077:
            raise LaunchRefused("STATE_NOT_PRIVATE", str(path))


def ensure_private_dir(path):
    """Creates path (and a missing parent state root) as private directories; an existing one is left as it is."""
    path = Path(path)
    for directory in (path.parent, path):
        try:
            directory.mkdir(mode=0o700)
        except FileExistsError:
            info = directory.lstat()
            if stat.S_ISLNK(info.st_mode) or getattr(info, "st_file_attributes", 0) & 0x400 or not stat.S_ISDIR(info.st_mode):
                raise LaunchRefused("REDIRECTED_STATE_COMPONENT", str(directory))
            continue
        except OSError as error:
            raise LaunchRefused("STATE_UNAVAILABLE", f"{directory}: {error}") from error
        try:
            _restrict(directory)
        except BaseException:
            try:
                directory.rmdir()
            finally:
                raise


def server_argv(role, launch, timeout_seconds):
    common = ["--repo", str(launch.repo), "--state-dir", str(launch.state_dir), "--repository-id", launch.repository_id,
              "--source-ref", launch.source_ref.decode("utf-8"), "--target-ref", launch.target_ref.decode("utf-8")]
    if role == "core":
        return "gauntlet-mcp", [*common, "--participant", "claude-author", "--role", "author"]
    return "gauntlet-codex", [*common, "--participant", "claude-peer", "--timeout-seconds", str(timeout_seconds)]


def _log(state_root, text):
    try:
        path = Path(state_root) / LOG_NAME
        if not path.exists() or path.stat().st_size < LOG_LIMIT:
            with open(path, "a", encoding="utf-8") as handle:
                handle.write(time.strftime("%Y-%m-%dT%H:%M:%S%z ") + text + "\n")
    except OSError:
        pass


class _Parser(argparse.ArgumentParser):
    def error(self, message):
        raise LaunchRefused("CONFIGURATION_ERROR", message)


def main(argv=None):
    state_root = None
    try:
        parser = _Parser(prog="gauntlet-launch", description="Start a collaborative server for this checkout")
        parser.add_argument("role", choices=("core", "peer"))
        parser.add_argument("--state-root", required=True)
        parser.add_argument("--timeout-seconds", type=int, default=600)
        args = parser.parse_args(argv)
        state_root = Path(args.state_root)
        if not state_root.is_absolute():
            raise LaunchRefused("CONFIGURATION_ERROR", "--state-root must be absolute")
        launch = derive(Path.cwd(), state_root)
        ensure_private_dir(launch.state_dir)
        prog, server_args = server_argv(args.role, launch, args.timeout_seconds)
        _log(state_root, f"{args.role} cwd={Path.cwd()} repo={launch.repo} id={launch.repository_id} "
                         f"source={launch.source_ref.decode()} target={launch.target_ref.decode()} state={launch.state_dir}")
    except LaunchRefused as refusal:
        if state_root is not None and state_root.is_absolute() and state_root.is_dir():
            _log(state_root, f"refused {refusal.code}: {refusal.detail} (cwd={Path.cwd()})")
        sys.stderr.write(json.dumps({"code": refusal.code, "operation": "launch"}, separators=(",", ":")) + "\n")
        return 2
    if args.role == "core":
        from gauntlet_review.collaborative.server import main as serve
    else:
        from gauntlet_review.codex_bridge.server import main as serve
    sys.argv = [prog, *server_args]
    return serve()


if __name__ == "__main__":
    raise SystemExit(main())
