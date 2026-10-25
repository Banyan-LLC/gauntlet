"""Global host launcher for the collaborative servers.

One user-scope host registration serves every checkout. The host starts this module in the session's working
folder; it derives that session's operator tuple there and then runs the ordinary server entry point in the same
process, so stdio stays connected and the server still has exactly one immutable tuple:

    python -m gauntlet_review.launch core --state-root <dir>
    python -m gauntlet_review.launch peer --state-root <dir> [--timeout-seconds N]
    python -m gauntlet_review.launch check

  --repo           the checkout containing the working folder (a linked worktree is its own checkout)
  --source-ref     the branch that checkout has checked out (a detached HEAD is refused)
  --target-ref     origin's default branch (refs/remotes/origin/HEAD), else refs/remotes/origin/main or master
  --repository-id  <owner>-<repository> from origin's URL, else the main checkout's folder name
  --state-dir      <state-root>/<repository-id>--<branch>-<digest>, one private directory per checkout and ref
                   pair (the digest covers the checkout path, both refs and the ID, so a store is never rebound),
                   created on first use and restricted to the current account. The state root is never resolved:
                   every existing component must be a real directory, the same no-follow rule the core applies,
                   and the unresolved path is what the server receives.
  --participant    claude-author with --role author (core), or claude-peer (peer)

`check` runs both servers' model-free dependency checks, exact pins included, and starts nothing; an installer
uses it before registering. Every failure before the hand-off prints one fixed code on stderr, as the servers do
(INTERNAL_ERROR adds a correlation ID); details go only to <state-root>/launch.log (bounded), which the operator
owns. A host's explicit project or local registration with the same name takes precedence."""
import argparse, hashlib, json, os, re, stat, subprocess, sys, time, uuid
from dataclasses import dataclass
from pathlib import Path

LOG_NAME = "launch.log"
LOG_LIMIT = 1024 * 1024
ID_RE = re.compile(r"[A-Za-z0-9_-]{1,64}")
REPARSE_POINT = 0x400
ICACLS_TIMEOUT = 30


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


def check_unredirected(path):
    """Every existing component of the absolute path, from its anchor down, is a real directory: no symbolic link,
    junction or other reparse point. The first missing component ends the check (the rest is created later)."""
    path = Path(path)
    if not path.is_absolute():
        raise LaunchRefused("CONFIGURATION_ERROR", f"{path} is not absolute")
    for component in reversed((path, *path.parents)):
        try:
            info = component.lstat()
        except FileNotFoundError:
            return
        if stat.S_ISLNK(info.st_mode) or getattr(info, "st_file_attributes", 0) & REPARSE_POINT:
            raise LaunchRefused("REDIRECTED_STATE_COMPONENT", str(component))
        if not stat.S_ISDIR(info.st_mode):
            raise LaunchRefused("STATE_COMPONENT_NOT_DIRECTORY", str(component))


def _same_or_inside(path, folder):
    path, folder = (os.path.normcase(os.path.abspath(p)) for p in (path, folder))
    return path == folder or path.startswith(folder.rstrip("\\/") + os.sep)


def derive(cwd, state_root):
    """The operator tuple for a session started in cwd, with its state directory under state_root (not created)."""
    state_root = Path(state_root)
    check_unredirected(state_root)
    try:
        from dulwich.repo import NotGitRepository, Repo
    except ImportError as error:
        raise LaunchRefused("MISSING_EXTRA", str(error)) from error
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
    try:
        source.decode("utf-8", "strict")
        target.decode("utf-8", "strict")
    except UnicodeDecodeError as error:
        raise LaunchRefused("UNSUPPORTED_REF", repr(source)) from error
    repository_id = _repository_id(url, main_checkout)
    branch = source[len(b"refs/heads/"):].decode("utf-8")
    digest = hashlib.sha256(b"\0".join((os.fsencode(str(checkout)), repository_id.encode("ascii"), source, target))).hexdigest()[:12]
    state = state_root / f"{repository_id}--{(_slug(branch) or 'branch')[:48]}-{digest}"
    if _same_or_inside(state, checkout):
        raise LaunchRefused("STATE_INSIDE_REPOSITORY", str(state))
    return LaunchTuple(checkout, repository_id, source, target, state)


def _restrict(path):
    """A directory this launcher just created, restricted to the current account."""
    if os.name == "nt":
        user = os.environ.get("USERNAME")
        if not user:
            raise LaunchRefused("STATE_NOT_PRIVATE", "no USERNAME to grant")
        account = f"{os.environ['USERDOMAIN']}\\{user}" if os.environ.get("USERDOMAIN") else user
        try:
            result = subprocess.run(["icacls", str(path), "/inheritance:r", "/grant:r", f"{account}:(OI)(CI)F"],
                                    capture_output=True, text=True, timeout=ICACLS_TIMEOUT)
        except (OSError, subprocess.SubprocessError) as error:
            raise LaunchRefused("STATE_NOT_PRIVATE", f"icacls: {type(error).__name__}: {error}") from error
        if result.returncode != 0:
            raise LaunchRefused("STATE_NOT_PRIVATE", (result.stdout + result.stderr).strip()[:500])
    else:
        try:
            os.chmod(path, 0o700)
            info = os.stat(path)
        except OSError as error:
            raise LaunchRefused("STATE_NOT_PRIVATE", f"{type(error).__name__}: {error}") from error
        if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077:
            raise LaunchRefused("STATE_NOT_PRIVATE", str(path))


def ensure_private_dir(path, cleanup_failures=None):
    """Creates path (and a missing parent state root) as private directories; an existing one is left as it is.
    Redirected components are refused before anything is created. A directory whose restriction fails is removed
    again; a failure of that removal goes to cleanup_failures and never replaces the original error."""
    path = Path(path)
    check_unredirected(path)
    for directory in (path.parent, path):
        try:
            directory.mkdir(mode=0o700)
        except FileExistsError:
            check_unredirected(directory)
            continue
        except OSError as error:
            raise LaunchRefused("STATE_UNAVAILABLE", f"{directory}: {type(error).__name__}: {error}") from error
        try:
            check_unredirected(directory)
            _restrict(directory)
        except BaseException:
            try:
                directory.rmdir()
            except OSError as cleanup:
                if cleanup_failures is not None:
                    cleanup_failures.append(f"{directory}: {type(cleanup).__name__}: {cleanup}")
            raise


def check_runtime():
    """The model-free dependency checks both servers run at startup, their exact pins included. Starts nothing."""
    try:
        from gauntlet_review.collaborative import server as core_server
        from gauntlet_review.codex_bridge import server as peer_server
        import dulwich.repo  # noqa: F401
    except ImportError as error:
        raise LaunchRefused("MISSING_EXTRA", f"{type(error).__name__}: {error}") from error
    for name, module in (("core", core_server), ("peer", peer_server)):
        try:
            module._require_extra()
        except Exception as error:
            code = getattr(error, "code", None)
            raise LaunchRefused(code if code in ("MISSING_EXTRA", "UNSUPPORTED_EXTRA") else "MISSING_EXTRA",
                                f"{name}: {type(error).__name__}") from error


def server_argv(role, launch, timeout_seconds):
    common = ["--repo", str(launch.repo), "--state-dir", str(launch.state_dir), "--repository-id", launch.repository_id,
              "--source-ref", launch.source_ref.decode("utf-8"), "--target-ref", launch.target_ref.decode("utf-8")]
    if role == "core":
        return "gauntlet-mcp", [*common, "--participant", "claude-author", "--role", "author"]
    return "gauntlet-codex", [*common, "--participant", "claude-peer", "--timeout-seconds", str(timeout_seconds)]


def _log(state_root, text):
    """Appends to the operator log only in a real, unredirected state root that already exists."""
    try:
        if state_root is None:
            return
        check_unredirected(state_root)
        if not stat.S_ISDIR(Path(state_root).lstat().st_mode):
            return
        path = Path(state_root) / LOG_NAME
        if not path.exists() or path.stat().st_size < LOG_LIMIT:
            with open(path, "a", encoding="utf-8") as handle:
                handle.write(time.strftime("%Y-%m-%dT%H:%M:%S%z ") + text + "\n")
    except (LaunchRefused, OSError, ValueError):
        pass


class _Parser(argparse.ArgumentParser):
    def error(self, message):
        raise LaunchRefused("CONFIGURATION_ERROR", message)


def _cleanup_note(cleanup_failures):
    return "".join(f"; cleanup failed: {item}" for item in cleanup_failures)


def _refuse(state_root, code, detail, correlation=None):
    note = f" correlation_id={correlation}" if correlation else ""
    try:
        cwd = os.getcwd()
    except OSError:
        cwd = "?"
    _log(state_root, f"refused {code}{note}: {detail} (cwd={cwd})")
    body = {"code": code, "operation": "launch"}
    if correlation:
        body["correlation_id"] = correlation
    try:
        sys.stderr.write(json.dumps(body, separators=(",", ":")) + "\n")
    except (OSError, ValueError):
        pass
    return 2


def main(argv=None):
    state_root = None
    cleanup_failures = []
    try:
        parser = _Parser(prog="gauntlet-launch", description="Start a collaborative server for this checkout")
        parser.add_argument("role", choices=("core", "peer", "check"))
        parser.add_argument("--state-root")
        parser.add_argument("--timeout-seconds", type=int, default=600)
        args = parser.parse_args(argv)
        if args.role == "check":
            check_runtime()
            return 0
        if not args.state_root or not Path(args.state_root).is_absolute():
            raise LaunchRefused("CONFIGURATION_ERROR", "--state-root must be an absolute path")
        state_root = Path(args.state_root)
        launch = derive(Path.cwd(), state_root)
        ensure_private_dir(launch.state_dir, cleanup_failures)
        prog, server_args = server_argv(args.role, launch, args.timeout_seconds)
        if args.role == "core":
            from gauntlet_review.collaborative.server import main as serve
        else:
            from gauntlet_review.codex_bridge.server import main as serve
        _log(state_root, f"{args.role} cwd={Path.cwd()} repo={launch.repo} id={launch.repository_id} "
                         f"source={launch.source_ref.decode()} target={launch.target_ref.decode()} state={launch.state_dir}")
    except LaunchRefused as refusal:
        return _refuse(state_root, refusal.code, refusal.detail + _cleanup_note(cleanup_failures))
    except ImportError as error:
        return _refuse(state_root, "MISSING_EXTRA", f"{type(error).__name__}: {error}")
    except subprocess.SubprocessError as error:
        return _refuse(state_root, "STATE_NOT_PRIVATE", f"{type(error).__name__}: {error}" + _cleanup_note(cleanup_failures))
    except OSError as error:
        return _refuse(state_root, "STATE_UNAVAILABLE", f"{type(error).__name__}: {error}" + _cleanup_note(cleanup_failures))
    except Exception as error:
        correlation = uuid.uuid4().hex
        return _refuse(state_root, "INTERNAL_ERROR", f"{type(error).__name__}: {error}", correlation)
    sys.argv = [prog, *server_args]
    return serve()


if __name__ == "__main__":
    raise SystemExit(main())
