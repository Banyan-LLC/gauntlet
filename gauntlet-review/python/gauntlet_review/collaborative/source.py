"""Read-only, exact Git-object snapshots. No porcelain, worktree reads or helpers."""
from __future__ import annotations

import base64
from contextlib import contextmanager
from dataclasses import asdict
from datetime import datetime, timezone
import errno
import hashlib
import os
from pathlib import Path
import re
import stat
import zlib

from dulwich.diff_tree import tree_changes
from dulwich.errors import ChecksumMismatch, ObjectFormatException, NotGitRepository
from dulwich.objects import Blob, Commit, Tree
from dulwich.repo import Repo, UnsupportedExtension, UnsupportedVersion

from .contracts import (ArtifactHandle, BytePage, Change, CoreError, ManifestRow,
                        Policy, RefObservation, Snapshot, SourceEntry, encode,
                        validate_operator_config)


def _b64(value: bytes) -> str:
    return base64.b64encode(value).decode("ascii")


def snapshot_payload(snapshot: Snapshot) -> dict:
    return {"header": dict(snapshot.header), "changes": [asdict(c) for c in snapshot.changes]}


def _digest(value) -> str:
    return hashlib.sha256(encode(value)).hexdigest()


def _limit(name):
    raise CoreError("LIMIT_EXCEEDED", detail={"limit": name})


class GitSource:
    def __init__(self, config):
        self.config = validate_operator_config(config)
        self.policy = Policy()
        self.closed = False
        # Each later operation opens/closes a fresh object store. A previous
        # successful page must not authorize bytes cached before disk corruption.
        with self._repository() as repo:
            self.repo_binding = os.path.normcase(str(Path(repo.commondir()).resolve(strict=True)))

    def __enter__(self):
        if self.closed:
            raise CoreError("CONFIGURATION_ERROR", detail={"reason": "source_closed"})
        return self

    def __exit__(self, *_):
        self.close()

    def close(self):
        self.closed = True

    @contextmanager
    def _repository(self):
        if self.closed:
            raise CoreError("CONFIGURATION_ERROR", detail={"reason": "source_closed"})
        try:
            with Repo(str(self.config.repo_path)) as repo:
                self._supported(repo)
                yield repo
        except CoreError:
            raise
        except (UnsupportedVersion, UnsupportedExtension, NotGitRepository, ValueError) as error:
            raise CoreError("UNSUPPORTED_REPOSITORY", detail={"reason": "unsupported_git_storage"}) from error
        except (ChecksumMismatch, ObjectFormatException, zlib.error) as error:
            raise CoreError("DIGEST_MISMATCH", detail={"reason": "invalid_git_object"}) from error
        except (KeyError, FileNotFoundError) as error:
            raise CoreError("MISSING_OBJECT", detail={"reason": "git_object_or_ref_unavailable"}) from error
        except OSError as error:
            raise CoreError("STORAGE_ERROR", retryable=error.errno in
                (errno.EAGAIN, errno.EBUSY, errno.EINTR, errno.ETIMEDOUT),
                detail={"reason": "git_read_failed"}) from error

    @staticmethod
    def _supported(repo):
        config = repo.get_config()
        for extension, value in config.items((b"extensions",)):
            if extension.lower() == b"objectformat":
                if value != b"sha1":
                    raise CoreError("UNSUPPORTED_REPOSITORY", detail={"reason": "object_format"})
            elif extension.lower() not in (b"worktreeconfig", b"relativeworktrees"):
                raise CoreError("UNSUPPORTED_REPOSITORY", detail={"reason": "repository_extension"})
        common = Path(repo.commondir())
        try:
            (common / "shallow").stat()
        except FileNotFoundError:
            pass
        else:
            raise CoreError("UNSUPPORTED_REPOSITORY", detail={"reason": "shallow_repository"})
        for section in config.sections():
            if section[0].lower() == b"remote" and config.get_boolean(section, b"promisor", False):
                raise CoreError("UNSUPPORTED_REPOSITORY", detail={"reason": "promisor_repository"})
        pack = common / "objects" / "pack"
        try:
            pack_mode=pack.stat().st_mode
        except FileNotFoundError:
            pack_mode=None
        if pack_mode is not None and stat.S_ISDIR(pack_mode):
            with os.scandir(pack) as entries:
                if any(entry.name.endswith(".promisor") for entry in entries):
                    raise CoreError("UNSUPPORTED_REPOSITORY", detail={"reason": "promisor_objects"})

    @staticmethod
    def _object(repo, oid: str, expected_type):
        if type(oid) is not str or not re.fullmatch(r"[a-f0-9]{40}", oid):
            raise CoreError("UNSUPPORTED_REPOSITORY", detail={"reason": "object_identity"})
        value = repo.object_store[oid.encode("ascii")]
        if not isinstance(value, expected_type):
            raise CoreError("UNSUPPORTED_REPOSITORY", detail={"reason": "object_type"})
        raw = value.as_raw_string()
        actual = hashlib.sha1(value.type_name + b" " + str(len(raw)).encode("ascii") + b"\0" + raw).hexdigest()
        if actual != oid:
            raise CoreError("DIGEST_MISMATCH", detail={"reason": "git_object_identity"})
        return value

    def _observe(self, repo):
        source = repo.refs[self.config.source_ref].decode("ascii")
        target = repo.refs[self.config.target_ref].decode("ascii")
        self._object(repo, source, Commit)
        self._object(repo, target, Commit)
        return RefObservation(source, target, datetime.now(timezone.utc).isoformat())

    def observe(self):
        with self._repository() as repo:
            return self._observe(repo)

    def _ancestor(self, repo, target, head, policy):
        pending, seen = [head], set()
        while pending:
            oid = pending.pop()
            if oid in seen:
                continue
            if len(seen) >= policy.graph_commits:
                _limit("graph_commits")
            seen.add(oid)
            commit = self._object(repo, oid, Commit)
            if oid == target:
                return
            # Actual stored parents only: no replace refs, grafts or revision walk.
            pending.extend(parent.decode("ascii") for parent in commit.parents)
        raise CoreError("NEEDS_SYNC", detail={"reason": "target_is_not_ancestor"})

    def _inventory(self, repo, root, policy):
        entries, pending = {}, [(b"", root)]
        while pending:
            prefix, oid = pending.pop()
            tree = self._object(repo, oid, Tree)
            for name, mode, child in tree.iteritems(name_order=True):
                path = prefix + name
                if len(path) > policy.raw_path_bytes:
                    _limit("raw_path_bytes")
                if not name or b"/" in name or b"\0" in name or name in (b".", b".."):
                    raise CoreError("UNSUPPORTED_REPOSITORY", detail={"reason": "tree_path"})
                child_oid = child.decode("ascii")
                if mode == 0o040000:
                    pending.append((path + b"/", child_oid))
                elif mode in (0o100644, 0o100755, 0o120000, 0o160000):
                    if len(entries) >= policy.tree_entries:
                        _limit("tree_entries")
                    if path in entries:
                        raise CoreError("UNSUPPORTED_REPOSITORY", detail={"reason": "duplicate_tree_path"})
                    entries[path] = mode, child_oid
                else:
                    raise CoreError("UNSUPPORTED_REPOSITORY", detail={"reason": "tree_mode"})
        return entries

    def _blob(self, repo, oid, policy):
        blob = self._object(repo, oid, Blob)
        data = blob.as_raw_string()
        if len(data) > policy.blob_bytes:
            _limit("blob_bytes")
        return data

    @staticmethod
    def _header(config, observation, policy):
        return {"repository_id": config.repository_id, "source_ref_b64": _b64(config.source_ref),
                "target_ref_b64": _b64(config.target_ref), "source_oid": observation.source_oid,
                "target_oid": observation.target_oid, "policy_digest": policy.digest,
                "object_format": "sha1"}

    def _build(self, repo, observation, policy):
        self._ancestor(repo, observation.target_oid, observation.source_oid, policy)
        base = self._object(repo, observation.target_oid, Commit)
        head = self._object(repo, observation.source_oid, Commit)
        # Bound complete tree enumeration independently of the changed-path cap.
        self._inventory(repo, base.tree.decode("ascii"), policy)
        self._inventory(repo, head.tree.decode("ascii"), policy)
        header = self._header(self.config, observation, policy)
        records, seen, total = [], set(), 0
        for difference in tree_changes(repo.object_store, base.tree, head.tree, rename_detector=None):
            if len(records) >= policy.changed_paths:
                _limit("changed_paths")
            record = {}
            for side, entry in (("old", difference.old), ("new", difference.new)):
                if entry is None:
                    record.update({f"{side}_{field}": None for field in ("path_b64", "mode", "oid", "length", "digest")})
                    continue
                path, mode, oid = entry.path, entry.mode, entry.sha.decode("ascii")
                if len(path) > policy.raw_path_bytes:
                    _limit("raw_path_bytes")
                record.update({f"{side}_path_b64": _b64(path), f"{side}_mode": mode, f"{side}_oid": oid})
                if mode == 0o160000:
                    record[f"{side}_length"] = record[f"{side}_digest"] = None
                else:
                    data = self._blob(repo, oid, policy)
                    if total + len(data) > policy.changed_bytes:
                        _limit("changed_bytes")
                    total += len(data)
                    record[f"{side}_length"] = len(data)
                    record[f"{side}_digest"] = hashlib.sha256(data).hexdigest()
            change_id = _digest({"header": header, "change": record})[:32]
            if change_id in seen:
                raise CoreError("DIGEST_MISMATCH", detail={"reason": "change_id_collision"})
            seen.add(change_id)
            records.append(Change(change_id=change_id, **record))
        records.sort(key=lambda c: (base64.b64decode(c.new_path_b64 or c.old_path_b64),
                                    0 if c.new_path_b64 is None else 1))
        snapshot = Snapshot(header, tuple(records), "")
        return Snapshot(header, snapshot.changes, _digest(snapshot_payload(snapshot)))

    def capture(self, policy):
        self.policy = policy
        with self._repository() as repo:
            before = self._observe(repo)
            result = self._build(repo, before, policy)
            after = self._observe(repo)
            if (before.source_oid, before.target_oid) != (after.source_oid, after.target_oid):
                raise CoreError("STALE", detail={"reason": "refs_moved_during_capture"},observation=after)
            return result

    def _validate_snapshot(self, snapshot):
        if not isinstance(snapshot, Snapshot) or _digest(snapshot_payload(snapshot)) != snapshot.digest:
            raise CoreError("DIGEST_MISMATCH", detail={"reason": "snapshot_digest"})
        header = snapshot.header
        observation = RefObservation(header.get("source_oid"), header.get("target_oid"), "")
        if header != self._header(self.config, observation, self.policy):
            raise CoreError("CONFIGURATION_MISMATCH", detail={"reason": "snapshot_configuration"})
        ids = set()
        for change in snapshot.changes:
            record = asdict(change)
            identifier = record.pop("change_id")
            if identifier in ids or _digest({"header": header, "change": record})[:32] != identifier:
                raise CoreError("DIGEST_MISMATCH", detail={"reason": "change_identity"})
            ids.add(identifier)

    def check_snapshot(self, snapshot):
        self._validate_snapshot(snapshot)
        with self._repository() as repo:
            pinned = RefObservation(snapshot.header["source_oid"], snapshot.header["target_oid"], "")
            actual = self._build(repo, pinned, self.policy)
            if actual != snapshot:
                raise CoreError("DIGEST_MISMATCH", detail={"reason": "snapshot_objects"})
            return self._observe(repo)

    def read_blob(self, oid, offset, length, expected_sha256):
        if (type(offset) is not int or not 0 <= offset <= 2**53-1 or type(length) is not int
                or not 1 <= length <= self.policy.artifact_page_bytes or type(expected_sha256) is not str
                or not re.fullmatch(r"[a-f0-9]{64}", expected_sha256)):
            raise CoreError("INVALID_ARGUMENT", detail={"reason": "blob_page_arguments"})
        with self._repository() as repo:
            data = self._blob(repo, oid, self.policy)
            digest = hashlib.sha256(data).hexdigest()
            if digest != expected_sha256:
                raise CoreError("DIGEST_MISMATCH", detail={"reason": "blob_digest"})
            if offset > len(data):
                raise CoreError("INVALID_ARGUMENT", detail={"reason": "offset_past_end"})
            end = min(len(data), offset + length)
            return BytePage(data[offset:end], offset, len(data), end == len(data), digest)

    @staticmethod
    def _artifact_id(snapshot, side, path_b64, oid):
        return _digest({"snapshot_digest": snapshot.digest, "side": side,
                        "path_b64": path_b64, "oid": oid})[:32]

    def manifest_rows(self, snapshot):
        self._validate_snapshot(snapshot)
        rows, ids = [], set()
        for change in snapshot.changes:
            handles = []
            for field, side in (("old", "base"), ("new", "head")):
                mode = getattr(change, field + "_mode")
                if mode is None or mode == 0o160000:
                    handles.append(None)
                    continue
                oid = getattr(change, field + "_oid")
                identifier = self._artifact_id(snapshot, side, getattr(change, field + "_path_b64"), oid)
                if identifier in ids:
                    raise CoreError("DIGEST_MISMATCH", detail={"reason": "artifact_id_collision"})
                ids.add(identifier)
                handles.append(ArtifactHandle(identifier, "blob", side, getattr(change, field + "_length"),
                                              getattr(change, field + "_digest"), mode, oid))
            rows.append(ManifestRow(change, *handles))
        return iter(rows)

    def source_entries(self, snapshot):
        return iter(tuple(self.describe_entry(snapshot,entry) for entry in self.source_inventory(snapshot)))

    def source_inventory(self,snapshot):
        """Enumerate cheap pinned identities without reading unrelated blob bodies."""
        self._validate_snapshot(snapshot)
        entries,ids=[],set()
        with self._repository() as repo:
            head = self._object(repo, snapshot.header["source_oid"], Commit)
            inventory = self._inventory(repo, head.tree.decode("ascii"), self.policy)
            for path, (mode, oid) in sorted(inventory.items()):
                identifier = None
                if mode != 0o160000:
                    identifier = self._artifact_id(snapshot, "head", _b64(path), oid)
                    if identifier in ids:
                        raise CoreError("DIGEST_MISMATCH", detail={"reason": "artifact_id_collision"})
                    ids.add(identifier)
                entries.append(SourceEntry(_b64(path), mode, oid, None, None, identifier))
        return tuple(entries)

    def describe_entry(self,snapshot,entry):
        self._validate_snapshot(snapshot)
        if entry.mode==0o160000:
            return entry
        if entry.artifact_id!=self._artifact_id(snapshot,"head",entry.raw_path_b64,entry.oid):
            raise CoreError("DIGEST_MISMATCH",detail={"reason":"source_entry_identity"})
        with self._repository() as repo:
            data=self._blob(repo,entry.oid,self.policy)
            return SourceEntry(entry.raw_path_b64,entry.mode,entry.oid,len(data),
                               hashlib.sha256(data).hexdigest(),entry.artifact_id)
