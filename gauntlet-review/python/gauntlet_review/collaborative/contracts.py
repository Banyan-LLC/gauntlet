"""Strict optional collaborative-v1 contracts and logical payload policy."""
from __future__ import annotations

import base64
import binascii
from dataclasses import dataclass
import hashlib
import os
from pathlib import Path, PureWindowsPath
import re
from typing import Annotated, Any, Literal

from pydantic import AfterValidator, BaseModel, ConfigDict, Field, ValidationError, model_validator

from gauntlet_review.jcs import canonical_bytes

MAX_EXACT = 2**53 - 1
ASSURANCE = "collaborative-v1"


class CoreError(Exception):
    def __init__(self, code: str, retryable: bool = False, detail: dict | None = None):
        self.code, self.retryable, self.detail = code, retryable, detail or {}
        # Call sites supply bounded safe identifiers/reasons, never source bodies.
        try:
            if len(canonical_bytes(self.detail)) > 1024:
                self.detail = {"reason": "detail_exceeds_limit"}
        except (TypeError, ValueError, RecursionError, UnicodeError):
            self.detail = {"reason": "invalid_error_detail"}
        super().__init__(code)


def encode(value: object) -> bytes:
    try:
        return canonical_bytes(value)
    except (ValueError, TypeError, UnicodeError, RecursionError) as error:
        raise CoreError("INVALID_ARGUMENT", detail={"reason": "noncanonical_value"}) from error


@dataclass(frozen=True)
class Policy:
    assurance: str = ASSURANCE
    changed_paths: int = 1000
    blob_bytes: int = 4 * 1024 * 1024
    changed_bytes: int = 64 * 1024 * 1024
    artifact_page_bytes: int = 64 * 1024
    evidence_call_bytes: int = 256 * 1024
    evidence_series_bytes: int = 16 * 1024 * 1024
    verdict_bytes: int = 256 * 1024
    findings: int = 200
    new_findings: int = 20
    verdicts: int = 10
    revisions: int = 20
    carryover_reason_bytes: int = 256
    series_payload_bytes: int = 64 * 1024 * 1024
    store_payload_bytes: int = 1024 * 1024 * 1024
    graph_commits: int = 1_000_000
    tree_entries: int = 100_000
    raw_path_bytes: int = 4096
    listing_rows: int = 100
    listing_bytes: int = 80 * 1024
    binary_metadata_bytes: int = 4096
    mcp_result_bytes: int = 256 * 1024

    @property
    def digest(self):
        from dataclasses import asdict
        return hashlib.sha256(encode(asdict(self))).hexdigest()


@dataclass(frozen=True)
class OperatorConfig:
    repo_path: Path
    state_dir: Path
    repository_id: str
    source_ref: bytes
    target_ref: bytes
    participant: str
    role: str

    @property
    def series_scope(self):
        return hashlib.sha256(encode({"repository_id": self.repository_id,
            "source_ref_b64": base64.b64encode(self.source_ref).decode("ascii"),
            "target_ref_b64": base64.b64encode(self.target_ref).decode("ascii")})).hexdigest()


def validate_operator_config(config: OperatorConfig) -> OperatorConfig:
    try:
        if not isinstance(config, OperatorConfig):
            raise ValueError("configuration type")
        for path in (config.repo_path, config.state_dir):
            if not isinstance(path, Path) or not path.is_absolute():
                raise ValueError("absolute native paths required")
            text = str(path)
            if text.startswith(("\\\\", "//")) or any(ord(ch) < 32 for ch in text):
                raise ValueError("unsupported path")
            text.encode("utf-8", "strict")
            if os.name != "nt" and (PureWindowsPath(text).drive or "\\" in text):
                raise ValueError("non-native path")
        for identity in (config.repository_id, config.participant):
            if type(identity) is not str or not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", identity):
                raise ValueError("identity")
        if config.role not in ("author", "reviewer"):
            raise ValueError("role")
        for ref, target in ((config.source_ref, False), (config.target_ref, True)):
            if type(ref) is not bytes or not (0 < len(ref) <= 1024):
                raise ValueError("ref type/length")
            ref.decode("utf-8", "strict")
            prefixes = (b"refs/heads/", b"refs/remotes/") if target else (b"refs/heads/",)
            if not ref.startswith(prefixes) or any(ch <= 32 or ch == 127 for ch in ref):
                raise ValueError("full ref required")
            if any(value in ref for value in (b"..", b"@{", b"//", b"~", b"^", b":", b"?", b"*", b"[", b"\\")):
                raise ValueError("invalid ref")
            if ref.endswith((b"/", b".")) or any(not part or part.startswith(b".") or
                part.endswith(b".lock") for part in ref.split(b"/")):
                raise ValueError("invalid ref component")
    except (ValueError, TypeError, UnicodeError) as error:
        raise CoreError("CONFIGURATION_ERROR", detail={"reason": "invalid_operator_configuration"}) from error
    return config


def _pattern(pattern):
    def check(value):
        if not re.fullmatch(pattern, value):
            raise ValueError("invalid identifier")
        return value
    return check


def _text(limit, *, nonempty=False):
    def check(value):
        if len(value.encode("utf-8", "strict")) > limit or (nonempty and not value):
            raise ValueError("text byte limit")
        if any(ord(ch) < 32 and ch not in "\t\r\n" for ch in value):
            raise ValueError("disallowed control")
        return value
    return check


Key = Annotated[str, Field(min_length=1, max_length=64, pattern=r"^[A-Za-z0-9_-]{1,64}$"),
                AfterValidator(_pattern(r"[A-Za-z0-9_-]{1,64}"))]
Id = Annotated[str, Field(min_length=32, max_length=32, pattern=r"^[a-f0-9]{32}$"),
               AfterValidator(_pattern(r"[a-f0-9]{32}"))]
Digest = Annotated[str, Field(min_length=64, max_length=64, pattern=r"^[a-f0-9]{64}$"),
                   AfterValidator(_pattern(r"[a-f0-9]{64}"))]
FindingId = Annotated[str, Field(max_length=36, pattern=r"^r([1-9]|10)-[a-f0-9]{32}$"),
                      AfterValidator(_pattern(r"r(?:[1-9]|10)-[a-f0-9]{32}"))]
Version = Annotated[int, Field(ge=0, le=MAX_EXACT)]
Location = Annotated[str, Field(max_length=150), AfterValidator(_text(150))]
FindingText = Annotated[str, Field(max_length=500), AfterValidator(_text(500))]
Summary = Annotated[str, Field(max_length=800), AfterValidator(_text(800))]
Reason = Annotated[str, Field(max_length=256), AfterValidator(_text(256))]
Command = Annotated[str, Field(max_length=2048), AfterValidator(_text(2048))]
Runtime = Annotated[str, Field(max_length=256), AfterValidator(_text(256))]
Uri = Annotated[str, Field(max_length=4096), AfterValidator(_text(4096, nonempty=True))]


class StrictModel(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid", revalidate_instances="always")


class OpenRequest(StrictModel):
    key: Key
    expected_version: Version


class BoundRequest(StrictModel):
    review_id: Id
    revision_id: Id
    snapshot_digest: Digest


class MutationRequest(BoundRequest):
    key: Key
    expected_version: Version


class Recommendation(StrictModel):
    severity: Literal["blocking", "important", "nit"]
    location: Location
    issue: FindingText
    suggestion: FindingText


class Carryover(StrictModel):
    id: FindingId
    digest: Digest
    status: Literal["addressed", "disputed", "outstanding"]
    reason: Reason

    @model_validator(mode="after")
    def require_reason(self):
        if self.status != "addressed" and not self.reason:
            raise ValueError("non-addressed findings require a reason")
        return self


class VerdictRequest(MutationRequest):
    verdict: Literal["approve", "request_changes"]
    summary: Summary
    recommendations: Annotated[list[Recommendation], Field(max_length=20)]
    coverage_digest: Digest
    coverage: Annotated[list[Id], Field(max_length=1000)]
    carryover: Annotated[list[Carryover], Field(max_length=200)]

    @model_validator(mode="after")
    def unique_references(self):
        if len(set(self.coverage)) != len(self.coverage) or len({v.id for v in self.carryover}) != len(self.carryover):
            raise ValueError("duplicate references")
        return self


class InlineEvidence(StrictModel):
    kind: Literal["inline"]
    data_b64: Annotated[str, Field(max_length=349528)]

    @model_validator(mode="after")
    def canonical_base64(self):
        try:
            decoded = base64.b64decode(self.data_b64, validate=True)
            if len(decoded) > 256 * 1024 or base64.b64encode(decoded).decode("ascii") != self.data_b64:
                raise ValueError("noncanonical or oversized evidence")
        except (binascii.Error, UnicodeError, ValueError) as error:
            raise ValueError("invalid evidence encoding") from error
        return self


class ExternalEvidence(StrictModel):
    kind: Literal["external"]
    uri: Uri
    length: Version
    sha256: Digest


class EvidenceRequest(MutationRequest):
    origin: Literal["agent_report", "ci_receipt", "legacy_certificate"]
    command: Command
    runtime: Runtime
    exit_status: Annotated[int, Field(ge=-(2**31), le=2**31-1)] | None
    content: Annotated[InlineEvidence | ExternalEvidence, Field(discriminator="kind")]


class ReadRequest(BoundRequest):
    view: Literal["history", "manifest", "source_tree", "artifact", "evidence"]
    cursor: Annotated[str, Field(max_length=4096), AfterValidator(_text(4096))] | None = None
    limit: Annotated[int, Field(ge=1, le=100)] = 100
    artifact_id: Id | None = None
    offset: Version = 0
    length: Annotated[int, Field(ge=1, le=65536)] = 65536

    @model_validator(mode="after")
    def select_view(self):
        if self.view in ("artifact", "evidence"):
            if self.artifact_id is None or self.cursor is not None:
                raise ValueError("artifact ID required without a cursor")
        elif self.artifact_id is not None or self.offset != 0 or self.length != 65536:
            raise ValueError("listings cannot select artifact offsets")
        return self


class StatusRequest(StrictModel):
    review_id: Id | None = None


REQUESTS = {"open_review": OpenRequest, "read_review": ReadRequest,
            "record_evidence": EvidenceRequest, "submit_review": VerdictRequest,
            "review_status": StatusRequest}


def validate_request(operation: str, payload: dict | BaseModel) -> BaseModel:
    try:
        if isinstance(payload, BaseModel):
            payload = payload.model_dump(mode="python", warnings=False)
        model = REQUESTS[operation].model_validate(payload, strict=True)
        if operation == "submit_review" and len(encode({"request": model.model_dump(mode="json")})) > Policy().verdict_bytes:
            raise ValueError("verdict payload exceeds limit")
        return model
    except (ValidationError, ValueError, TypeError, KeyError, UnicodeError, RecursionError) as error:
        # Pydantic's normal diagnostics may contain complete untrusted inputs.
        raise CoreError("INVALID_ARGUMENT", detail={"reason": "invalid_request"}) from error


def verdict_capacity(prior_count: int) -> int:
    if type(prior_count) is not int or not 0 <= prior_count <= 200:
        raise CoreError("LIMIT_EXCEEDED", detail={"limit": "findings"})
    value = dict(key="k"*64, expected_version=MAX_EXACT, review_id="a"*32,
        revision_id="b"*32, snapshot_digest="c"*64, verdict="request_changes",
        summary="\\"*800, coverage_digest="d"*64, coverage=[f"{i:032x}" for i in range(1000)],
        recommendations=[dict(severity="important", location="\\"*150, issue="\\"*500,
                              suggestion="\\"*500) for _ in range(20)],
        carryover=[dict(id="r10-"+f"{i:032x}", digest="e"*64, status="outstanding",
                       reason="\\"*256) for i in range(prior_count)])
    model = VerdictRequest.model_validate(value, strict=True)
    return len(encode({"request": model.model_dump(mode="json")}))


@dataclass(frozen=True)
class RefObservation:
    source_oid: str
    target_oid: str
    checked_at: str


@dataclass(frozen=True)
class Change:
    change_id: str
    old_path_b64: str | None
    new_path_b64: str | None
    old_mode: int | None
    new_mode: int | None
    old_oid: str | None
    new_oid: str | None
    old_length: int | None
    new_length: int | None
    old_digest: str | None
    new_digest: str | None


@dataclass(frozen=True)
class ArtifactHandle:
    artifact_id: str
    kind: str
    side: str | None
    byte_length: int
    sha256: str
    mode: int | None = None
    oid: str | None = None


@dataclass(frozen=True)
class ManifestRow:
    change: Change
    old_artifact: ArtifactHandle | None
    new_artifact: ArtifactHandle | None


@dataclass(frozen=True)
class Snapshot:
    header: dict
    changes: tuple[Change, ...]
    digest: str


@dataclass(frozen=True)
class SourceEntry:
    raw_path_b64: str
    mode: int
    oid: str
    length: int | None
    digest: str | None
    artifact_id: str | None


@dataclass(frozen=True)
class BytePage:
    data: bytes
    offset: int
    total: int
    eof: bool
    digest: str


@dataclass(frozen=True)
class Event:
    id: str
    seq: int
    revision_id: str
    kind: str
    body: bytes
    body_digest: str
    store_version: int = 0


@dataclass(frozen=True)
class SeriesView:
    id: str
    store_version: int
    current_revision: str
    snapshot: Snapshot
    events: tuple[Event, ...]
    findings: tuple[dict, ...]
    verdict_count: int
    revision_count: int
    payload_bytes: int = 0
    evidence_bytes: int = 0


@dataclass(frozen=True)
class StoreView:
    store_version: int
    series: SeriesView | None
    store_payload_bytes: int


@dataclass(frozen=True)
class Mutation:
    event: Event
    evidence_body: bytes | None
    operation_result: bytes


@dataclass(frozen=True)
class StoredResult:
    event_id: str
    result_bytes: bytes
    store_version: int
    replayed: bool


@dataclass(frozen=True)
class Page:
    items: tuple[Any, ...]
    next_cursor: str | None
    complete: bool
    store_version: int


@dataclass(frozen=True)
class AcceptedVerdict:
    normalized_verdict: str
    recommendations: tuple[dict, ...]
    carryover: tuple[dict, ...]
    coverage_digest: str
    status: str


@dataclass(frozen=True)
class Status:
    series: dict | None
    status: str | None
    finding_rollups: tuple[dict, ...]
    counts: dict
    snapshot_digest: str | None
    freshness: dict
