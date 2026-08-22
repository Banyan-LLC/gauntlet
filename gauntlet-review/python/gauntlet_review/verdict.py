"""Verdict normalization + recommendation-id derivation.
Behavioral port of Test-Verdict and Get-RecommendationId (lib.ps1)."""
from __future__ import annotations

import hashlib
import json
import os
from dataclasses import dataclass

import jsonschema

from gauntlet_review import jcs


def recommendation_id(round_num: int, index: int, rec: dict) -> str:
    """Stable, content-derived id over ALL FOUR fields plus round and index.
    Matches PowerShell Get-RecommendationId byte-for-byte."""
    material = "{}|{}|{}|{}|{}|{}".format(
        round_num,
        index,
        rec["severity"],
        rec["location"],
        rec["issue"],
        rec["suggestion"],
    )
    digest = hashlib.sha256(material.encode("utf-8")).digest()
    return "r{}-".format(round_num) + digest[:16].hex()


@dataclass
class NormalizeResult:
    valid: bool
    reason: str | None
    downgraded: bool
    normalized: dict | None
    canonical_json: str | None


def normalize_verdict(json_text: str, schema_path: str | os.PathLike) -> NormalizeResult:
    """Structural validation + severity-invariant downgrade + canonical JSON.
    Behavioral port of Test-Verdict (lib.ps1)."""
    try:
        obj = json.loads(json_text)
    except (ValueError, RecursionError):  # ValueError covers JSONDecodeError + oversized-int; RecursionError = deeply nested
        return NormalizeResult(False, "structural validation failed", False, None, None)

    with open(schema_path, "r", encoding="utf-8") as fh:
        schema = json.load(fh)
    try:
        jsonschema.validate(instance=obj, schema=schema, cls=jsonschema.Draft7Validator)
    except (jsonschema.ValidationError, RecursionError):
        return NormalizeResult(False, "structural validation failed", False, None, None)

    downgraded = False
    reason = None
    if obj["verdict"] == "approve":
        non_nit = [r for r in obj["recommendations"] if r["severity"] != "nit"]
        if non_nit:
            obj["verdict"] = "request_changes"
            downgraded = True
            reason = f"approve carried {len(non_nit)} non-nit recommendation(s); downgraded"

    try:
        canonical = jcs.canonical(obj)
    except (ValueError, TypeError) as exc:
        # e.g. a lone surrogate that passed json.loads + schema but is not valid Unicode.
        # Fail closed via the result contract rather than raising.
        return NormalizeResult(False, f"canonicalization failed: {exc}", False, None, None)
    return NormalizeResult(True, reason, downgraded, obj, canonical)
