import json

import pytest

from factory.errors import ScriptError
from factory.script import Script, ensure_hashtags, load_script_file, normalize_hashtags, validate


def test_narration_and_parts(script):
    parts = script.parts()
    assert parts[0] == (-1, script.hook)
    assert script.narration.startswith("Du vergisst 95 Prozent")
    assert script.word_count() == sum(len(t.split()) for _, t in parts)


def test_from_dict_is_tolerant():
    s = Script.from_dict({
        "hook": "Wusstest du das?",
        "szenen": ["Erster Satz.", {"text": "Zweiter Satz.", "suchbegriffe": "ocean, waves"}],
        "hashtags": "Fakten #Wusstestdu fakten",
        "quellen": ["https://example.org"],
    })
    assert s.titel == "Wusstest du das?"
    assert s.szenen[1].pexels_suchbegriffe == ["ocean", "waves"]
    assert s.hashtags == ["#fakten", "#wusstestdu"]
    assert s.quellen[0].url == "https://example.org"
    assert s.schluss_typ == "loop"


def test_from_dict_requires_hook_and_scenes():
    with pytest.raises(ScriptError):
        Script.from_dict({"hook": "", "szenen": []})


def test_validate_flags_rule_violations(cfg, script):
    script.hook = "Hallo und willkommen zu einem neuen Video über Träume und warum wir sie vergessen"
    script.hashtags = ["#a", "#b"]
    problems = " | ".join(validate(script, cfg))
    assert "Wörter" in problems           # Länge
    assert "Begrüßung" in problems        # Hook-Floskel
    assert "Hashtags" in problems         # 3–5
    assert "Szenen" in problems           # zu wenige Szenen


def test_validate_passes_for_good_script(cfg, script):
    script.szenen = script.szenen * 3
    assert validate(script, cfg, check_length=False) == []


def test_hashtags_are_filled_from_niche_pool(cfg, script):
    script.hashtags = ["#träume"]
    ensure_hashtags(script, cfg.niche("psychologie"))
    assert 3 <= len(script.hashtags) <= 5
    assert script.hashtags[0] == "#träume"
    assert normalize_hashtags(["A B", "#c"]) == ["#ab", "#c"]


def test_load_script_file_errors(tmp_path):
    bad = tmp_path / "bad.json"
    bad.write_text("{kein json", encoding="utf-8")
    with pytest.raises(ScriptError, match="kein gültiges JSON"):
        load_script_file(bad)
    good = tmp_path / "good.json"
    good.write_text(json.dumps({"hook": "Frage?", "szenen": ["Antwort."]}), encoding="utf-8")
    assert load_script_file(good).hook == "Frage?"
