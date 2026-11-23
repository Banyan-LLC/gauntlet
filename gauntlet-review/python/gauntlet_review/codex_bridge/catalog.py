"""The Codex model catalog (`model/list`), which never starts a model turn.

The peer checks its selection against it before every turn and the operator commands validate a change with it.
Import is safe without the optional SDK; only fetch_catalog imports it."""
from __future__ import annotations

import asyncio
from dataclasses import dataclass


@dataclass(frozen=True)
class CatalogModel:
    model: str
    display_name: str
    catalog_default: bool
    hidden: bool
    default_effort: str
    efforts: tuple[str, ...]


@dataclass(frozen=True)
class Catalog:
    models: tuple[CatalogModel, ...]
    complete: bool


def _value(effort):
    return getattr(effort, "value", effort)


def from_response(response):
    return Catalog(tuple(CatalogModel(item.model, item.display_name, bool(item.is_default), bool(item.hidden),
                                      _value(item.default_reasoning_effort),
                                      tuple(_value(option.reasoning_effort) for option in item.supported_reasoning_efforts))
                         for item in response.data), response.next_cursor is None)


def find(catalog, model):
    wanted = model.casefold()
    return next((item for item in catalog.models if item.model.casefold() == wanted), None)


def check(catalog, model, effort):
    """None when Codex lists the model with that effort; otherwise the refusal code."""
    item = find(catalog, model)
    if item is None:
        # A paged answer without the model cannot prove the model is gone.
        return "MODEL_UNAVAILABLE" if catalog.complete else "CATALOG_UNAVAILABLE"
    return None if effort in item.efforts else "EFFORT_NOT_SUPPORTED"


async def fetch(client):
    return from_response(await client.models(include_hidden=True))


def fetch_catalog():
    """The catalog from a short-lived native Codex runtime (for the operator commands)."""
    from openai_codex import AsyncCodex, CodexConfig

    async def run():
        async with AsyncCodex(CodexConfig()) as client:
            return await fetch(client)

    return asyncio.run(run())
