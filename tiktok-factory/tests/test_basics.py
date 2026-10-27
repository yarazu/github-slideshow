from factory.history import History, similar
from factory.utils import count_words, hex_to_ass, normalize_token, slugify


def test_slugify_handles_umlauts_and_length():
    assert slugify("Warum wir Träume sofort vergessen!") == "warum-wir-traeume-sofort-vergessen"
    assert slugify("Größe & Maß") == "groesse-mass"
    assert len(slugify("wort " * 40)) <= 60


def test_count_words_ignores_dashes():
    assert count_words("Das ist – kein Witz. 70 Prozent!") == 6


def test_normalize_token():
    assert normalize_token("„Straße,“") == "strasse"
    assert normalize_token("Wusstest") == normalize_token("wusstest?")


def test_hex_to_ass():
    assert hex_to_ass("#FFE135") == "&H0035E1FF"
    assert hex_to_ass("#000000", alpha=0x96) == "&H96000000"


def test_similar_topics():
    assert similar("Warum wir Träume sofort vergessen", "Warum vergessen wir Träume so schnell?")
    assert not similar("Warum Katzen schnurren", "Die Geschichte des Geldes")


def test_history_duplicates(tmp_path):
    h = History(tmp_path / "history.json")
    h.add({"thema": "Warum wir Träume sofort vergessen", "titel": "Träume vergessen", "nische": "psychologie",
           "media_ids": ["pexels-video-1"], "musik": "a.mp3"})
    assert h.find_duplicate("Warum vergessen wir unsere Träume sofort?")
    assert h.find_duplicate("Warum Oktopusse drei Herzen haben") is None
    assert History(tmp_path / "history.json").used_media_ids(5) == {"pexels-video-1"}
    assert h.topics("psychologie")[0].startswith("Träume vergessen")


def test_similar_is_not_too_eager():
    assert not similar("Warum Katzen schnurren", "Warum Katzen im Dunkeln sehen")
    assert not similar("Warum wir Träume vergessen", "Was Träume über dich verraten")
    assert similar("Schwarze Löcher", "Schwarze Löcher einfach erklärt")
