"""The /gauntlet-model skill is user-only, pre-approves nothing, and is installed with the other skills."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[3]
SKILL = ROOT / "gauntlet-model" / "SKILL.md"


def frontmatter(text):
    lines = text.splitlines()
    assert lines[0] == "---"
    end = lines.index("---", 1)
    fields = {}
    for line in lines[1:end]:
        key, _, value = line.partition(":")
        fields[key.strip()] = value.strip()
    return fields, "\n".join(lines[end + 1:])


def test_gauntlet_model_skill_is_user_only_and_installed():
    fields, body = frontmatter(SKILL.read_text(encoding="utf-8"))
    assert fields["name"] == "gauntlet-model"
    assert fields["disable-model-invocation"] == "true"
    assert "allowed-tools" not in fields and fields["description"]
    assert "gauntlet_review.launch models" in body and "gauntlet_review.launch model " in body
    assert "registration.ps1" in body
    for path in (SKILL, ROOT / "gauntlet-model" / "registration.ps1"):
        assert chr(0x2014) not in path.read_text(encoding="utf-8"), path
    loop = re.search(r"foreach \(\$skill in ([^)]*)\)", (ROOT / "install.ps1").read_text(encoding="utf-8"))
    assert loop and "'gauntlet-model'" in loop.group(1)
