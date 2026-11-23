"""Operator commands: list the Codex models and switch the peer's model and reasoning effort.

    python -I -m gauntlet_review.launch models --state-root <root> [--all] [--json]
    python -I -m gauntlet_review.launch model  --state-root <root> [SCOPE] [--json]
    python -I -m gauntlet_review.launch model  --state-root <root> [MODEL] [--effort EFFORT] [SCOPE] [--json]
    python -I -m gauntlet_review.launch model  --state-root <root> --reset [model|effort|all] [SCOPE] [--json]

SCOPE is --repo PATH (the repository ID derived from that folder, as the launcher derives it) or --repository-id
ID; without it the change is global. A change sets only the fields named and must leave that scope with a model and
effort Codex lists; a global change also warns about repositories it leaves unsupported. --reset never contacts
Codex. Every change applies from the next peer turn of every running peer. Refusals print one `CODE: message` line
on stderr and exit 2; a refused change writes nothing. These commands are for the operator: no MCP tool runs them."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from gauntlet_review import launch, peer_model

SOURCES = {"built_in": "built-in default", "global": "global setting", "repository": "repository setting",
           "operator": "operator flag"}


class Refused(Exception):
    def __init__(self, code, message):
        super().__init__(code)
        self.code = code
        self.message = message


class _Parser(argparse.ArgumentParser):
    def error(self, message):
        raise Refused("CONFIGURATION_ERROR", message)


def fetch_catalog():
    from gauntlet_review.codex_bridge.catalog import fetch_catalog as fetch
    return fetch()


def _require_extra():
    from gauntlet_review.codex_bridge.server import _require_extra as require
    require()


def _codex_catalog():
    try:
        _require_extra()
    except Exception as error:
        code = getattr(error, "code", None)
        raise Refused(code if code in ("MISSING_EXTRA", "UNSUPPORTED_EXTRA") else "MISSING_EXTRA",
                      "install the exact gauntlet-review[codex] dependencies") from error
    try:
        return fetch_catalog()
    except Exception as error:
        raise Refused("CATALOG_UNAVAILABLE", "Codex could not list its models; check that Codex is installed and "
                                             f"signed in ({type(error).__name__})") from error


def repository_id_of(folder):
    """The launcher's repository ID for the checkout containing folder, whatever its branch state."""
    try:
        from dulwich.repo import NotGitRepository, Repo
    except ImportError as error:
        raise Refused("MISSING_EXTRA", "dulwich is needed for --repo") from error
    try:
        repo = Repo.discover(str(folder))
    except NotGitRepository as error:
        raise Refused("NOT_A_GIT_CHECKOUT", f"{folder} is not inside a Git checkout") from error
    try:
        try:
            url = repo.get_config().get((b"remote", b"origin"), b"url").decode("utf-8", "replace")
        except KeyError:
            url = ""
        main_checkout = Path(repo.commondir()).resolve().parent
    finally:
        repo.close()
    try:
        return launch._repository_id(url, main_checkout)
    except launch.LaunchRefused as error:
        raise Refused(error.code, f"the repository ID {error.detail!r} is not valid") from error


def _state_root(value):
    root = Path(value)
    if not root.is_absolute():
        raise Refused("CONFIGURATION_ERROR", "--state-root must be an absolute path")
    return root


def _scope(args):
    if args.repo is not None:
        return repository_id_of(Path(args.repo))
    if args.repository_id is not None:
        value = args.repository_id
        if launch._slug(value) != value or not peer_model.REPOSITORY_RE.fullmatch(value):
            raise Refused("CONFIGURATION_ERROR", f"repository IDs are lowercase slugs such as owner-repo, not "
                                                 f"{value!r}; use --repo PATH to derive one from a checkout")
        return value
    return None


def _load(root):
    try:
        return peer_model.load(root)
    except peer_model.SettingsError as error:
        raise Refused(error.code, f"{root / peer_model.SETTINGS_NAME}: {error.detail}") from error


def _save(root, settings):
    try:
        peer_model.save(root, settings)
    except peer_model.SettingsError as error:
        raise Refused(error.code, error.detail) from error
    except launch.LaunchRefused as error:
        raise Refused(error.code, error.detail) from error
    except OSError as error:
        raise Refused("STATE_UNAVAILABLE", f"{root}: {type(error).__name__}: {error}") from error


def _normalized(text):
    return " ".join(text.split()).casefold()


def _catalog_model(catalog, text):
    """The catalog model the operator named, by its model name or by the name Codex displays (case, spacing and
    width of spaces ignored); None when nothing matches. A display name shared by several models is refused."""
    wanted = _normalized(text)
    by_model = [item for item in catalog.models if item.model.casefold() == wanted]
    if by_model:
        return by_model[0]
    by_name = [item for item in catalog.models if _normalized(item.display_name) == wanted]
    if len(by_name) > 1:
        raise Refused("CONFIGURATION_ERROR", f"{text!r} names more than one Codex model "
                                             f"({', '.join(item.model for item in by_name)}); use the model name")
    return by_name[0] if by_name else None


def _describe(selection):
    return (f"{selection.model} ({SOURCES[selection.model_source]}), "
            f"effort {selection.effort} ({SOURCES[selection.effort_source]})")


def _where(repository_id):
    return "global" if repository_id is None else f"repository {repository_id}"


def _emit(args, document, text):
    sys.stdout.write((json.dumps(document, ensure_ascii=False) if args.json else text) + "\n")


def _models(argv):
    parser = _Parser(prog="gauntlet-launch models", description="List the Codex models the peer can use")
    parser.add_argument("--state-root", required=True)
    parser.add_argument("--all", action="store_true", help="include models Codex hides from its picker")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    root = _state_root(args.state_root)
    selection = peer_model.resolve(_load(root), None)
    catalog = _codex_catalog()
    models = [item for item in catalog.models if args.all or not item.hidden]
    document = {"selection": selection.public(), "models": [
        {"model": item.model, "display_name": item.display_name, "catalog_default": item.catalog_default,
         "hidden": item.hidden, "default_effort": item.default_effort, "efforts": list(item.efforts)}
        for item in models]}
    width = max([len(item.model) for item in models] + [5])
    named = max([len(item.display_name) for item in models] + [4])
    lines = [f"Peer model (global): {_describe(selection)}", "",
             f"  {'MODEL':<{width}}  {'NAME':<{named}}  EFFORTS (catalog default effort)"]
    for item in models:
        mark = "*" if item.model == selection.model else " "
        notes = (" [Codex default]" if item.catalog_default else "") + (" [hidden]" if item.hidden else "")
        lines.append(f"{mark} {item.model:<{width}}  {item.display_name:<{named}}  "
                     f"{' '.join(item.efforts)} ({item.default_effort}){notes}")
    if not catalog.complete:
        lines.append("(Codex returned only part of its catalog)")
    _emit(args, document, "\n".join(lines))
    return 0


def _show(args, root, scope):
    settings = _load(root)
    if scope is not None:
        selection = peer_model.resolve(settings, scope)
        entry = dict(settings.repositories.get(scope, {}))
        document = {"scope": "repository", "repository_id": scope, "settings": entry, "selection": selection.public()}
        _emit(args, document, f"Peer model for repository {scope}: {_describe(selection)}")
        return 0
    selection = peer_model.resolve(settings, None)
    repositories = {key: {"settings": dict(entry), "selection": peer_model.resolve(settings, key).public()}
                    for key, entry in sorted(settings.repositories.items())}
    lines = [f"Peer model (global): {_describe(selection)}"]
    for key in sorted(settings.repositories):
        lines.append(f"  {key}: {_describe(peer_model.resolve(settings, key))}")
    if not settings.repositories:
        lines.append("No repository overrides.")
    _emit(args, {"scope": "global", "selection": selection.public(), "repositories": repositories}, "\n".join(lines))
    return 0


def _unsupported(catalog, selection):
    from gauntlet_review.codex_bridge import catalog as catalogs
    return catalogs.check(catalog, selection.model, selection.effort)


def _change(args, root, scope):
    from gauntlet_review.codex_bridge import catalog as catalogs
    settings = _load(root)
    model = args.model
    effort = args.effort.lower() if args.effort is not None else None
    if effort is not None and not peer_model.EFFORT_RE.fullmatch(effort):
        raise Refused("CONFIGURATION_ERROR", f"{args.effort!r} is not a reasoning effort")
    catalog = _codex_catalog()
    if model is not None:
        listed = _catalog_model(catalog, model)
        if listed is not None:
            model = listed.model
        elif not peer_model.MODEL_RE.fullmatch(model) or not catalog.complete:
            # Not a name Codex lists. A complete catalog proves it unknown; a partial one cannot.
            raise Refused("UNKNOWN_MODEL" if catalog.complete else "CATALOG_UNAVAILABLE",
                          f"{model!r} is not in the Codex catalog; run `models` to list them")
    candidate = peer_model.with_fields(settings, scope, model=model, effort=effort)
    selection = peer_model.resolve(candidate, scope)
    code = _unsupported(catalog, selection)
    if code == "MODEL_UNAVAILABLE":
        raise Refused("UNKNOWN_MODEL", f"{selection.model} is not in the Codex catalog; run `models` to list them")
    if code == "CATALOG_UNAVAILABLE":
        raise Refused("CATALOG_UNAVAILABLE", f"Codex returned only part of its catalog, without {selection.model}")
    if code == "EFFORT_NOT_SUPPORTED":
        efforts = " ".join(catalogs.find(catalog, selection.model).efforts)
        inherited = "" if selection.effort_source == "repository" and scope is not None or \
            selection.effort_source == "global" and scope is None else \
            f" (that effort comes from the {SOURCES[selection.effort_source]}; pass --effort)"
        raise Refused("EFFORT_NOT_SUPPORTED", f"{selection.model} does not support effort {selection.effort}"
                                              f"{inherited}; it supports: {efforts}")
    warnings = []
    if scope is None:
        for key in sorted(candidate.repositories):
            other = peer_model.resolve(candidate, key)
            problem = _unsupported(catalog, other)
            if problem is not None:
                warnings.append({"repository_id": key, "model": other.model, "effort": other.effort, "code": problem})
    _save(root, candidate)
    changes = " ".join(f"{name}={value}" for name, value in (("model", model), ("effort", effort)) if value is not None)
    launch._log(root, f"peer-model set scope={peer_model.scope_name(scope)} {changes}")
    lines = [f"Peer model ({_where(scope)}) is now {_describe(selection)}. It applies from the next peer turn."]
    for item in warnings:
        lines.append(f"warning: repository {item['repository_id']} would use {item['model']} at effort "
                     f"{item['effort']} ({item['code']}); its peer turns are refused until you change it.")
    entry = dict(candidate.default if scope is None else candidate.repositories.get(scope, {}))
    _emit(args, {"scope": "global" if scope is None else "repository", "repository_id": scope, "settings": entry,
                 "selection": selection.public(), "warnings": warnings}, "\n".join(lines))
    return 0


def _reset(args, root, scope):
    fields = peer_model.FIELDS if args.reset == "all" else (args.reset,)
    candidate = peer_model.without_fields(_load(root), scope, fields)
    _save(root, candidate)
    launch._log(root, f"peer-model reset scope={peer_model.scope_name(scope)} fields={','.join(fields)}")
    selection = peer_model.resolve(candidate, scope)
    entry = dict(candidate.default if scope is None else candidate.repositories.get(scope, {}))
    _emit(args, {"scope": "global" if scope is None else "repository", "repository_id": scope, "settings": entry,
                 "selection": selection.public(), "warnings": []},
          f"Peer model ({_where(scope)}) is now {_describe(selection)}. It applies from the next peer turn.")
    return 0


def _model(argv):
    parser = _Parser(prog="gauntlet-launch model", description="Show or switch the peer's model and effort")
    parser.add_argument("--state-root", required=True)
    parser.add_argument("model", nargs="?")
    parser.add_argument("--effort")
    parser.add_argument("--reset", nargs="?", const="all", choices=("model", "effort", "all"))
    where = parser.add_mutually_exclusive_group()
    where.add_argument("--repo")
    where.add_argument("--repository-id")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    root = _state_root(args.state_root)
    if args.reset is not None and (args.model is not None or args.effort is not None):
        raise Refused("CONFIGURATION_ERROR", "--reset takes no model or --effort")
    scope = _scope(args)
    if args.reset is not None:
        return _reset(args, root, scope)
    if args.model is None and args.effort is None:
        return _show(args, root, scope)
    return _change(args, root, scope)


def main(argv):
    try:
        command, rest = argv[0], list(argv[1:])
        if command == "models":
            return _models(rest)
        if command == "model":
            return _model(rest)
        raise Refused("CONFIGURATION_ERROR", f"unknown command {command!r}")
    except Refused as refusal:
        sys.stderr.write(f"{refusal.code}: {refusal.message}\n")
        return 2
    except SystemExit as exit:
        return int(exit.code or 0)
