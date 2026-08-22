"""Verdict normalization + recommendation-id derivation.
Behavioral port of Test-Verdict and Get-RecommendationId (lib.ps1)."""
from __future__ import annotations

import hashlib


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
