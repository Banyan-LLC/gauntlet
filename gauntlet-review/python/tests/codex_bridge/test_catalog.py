"""The Codex model catalog as the peer and the operator commands see it."""
import pytest

pytest.importorskip("openai_codex")
from openai_codex.generated.v2_all import ModelListResponse

from gauntlet_review.codex_bridge import catalog
from gauntlet_review.codex_bridge.catalog import Catalog, CatalogModel

pytestmark = pytest.mark.anyio

EFFORTS = ("low", "medium", "high", "xhigh", "max", "ultra")


def model(name, display, efforts, *, default_effort="low", is_default=False, hidden=False):
    return {"id": name, "model": name, "displayName": display, "description": display, "hidden": hidden,
            "isDefault": is_default, "defaultReasoningEffort": default_effort,
            "supportedReasoningEfforts": [{"reasoningEffort": e, "description": e} for e in efforts]}


def response(next_cursor=None):
    return ModelListResponse.model_validate({"data": [
        model("gpt-6.1-sol", "GPT-6.1-Sol", EFFORTS),
        model("gpt-6-luna", "GPT-6-Luna", EFFORTS[:-1], default_effort="medium", is_default=True),
        model("codex-auto-review", "Codex Auto Review", ("low",), hidden=True),
    ], "nextCursor": next_cursor})


def test_from_response_keeps_every_field_and_completeness():
    parsed = catalog.from_response(response())
    assert parsed == Catalog((
        CatalogModel("gpt-6.1-sol", "GPT-6.1-Sol", False, False, "low", EFFORTS),
        CatalogModel("gpt-6-luna", "GPT-6-Luna", True, False, "medium", EFFORTS[:-1]),
        CatalogModel("codex-auto-review", "Codex Auto Review", False, True, "low", ("low",)),
    ), True)
    assert catalog.from_response(response("c")).complete is False


def test_check_answers_each_case():
    complete, partial = catalog.from_response(response()), catalog.from_response(response("c"))
    assert catalog.check(complete, "gpt-6.1-sol", "xhigh") is None
    assert catalog.check(complete, "GPT-6.1-SOL", "xhigh") is None
    assert catalog.check(complete, "gpt-6-luna", "ultra") == "EFFORT_NOT_SUPPORTED"
    assert catalog.check(complete, "gpt-7", "low") == "MODEL_UNAVAILABLE"
    assert catalog.check(partial, "gpt-7", "low") == "CATALOG_UNAVAILABLE"
    assert catalog.check(partial, "gpt-6.1-sol", "high") is None
    assert catalog.find(complete, "codex-auto-review").hidden is True
    assert catalog.find(complete, "GPT-6-Luna").model == "gpt-6-luna"
    assert catalog.find(complete, "gpt-7") is None


async def test_fetch_asks_for_hidden_models():
    seen = []

    class Client:
        async def models(self, *, include_hidden=False):
            seen.append(include_hidden)
            return response()

    assert (await catalog.fetch(Client())).models[0].model == "gpt-6.1-sol"
    assert seen == [True]
