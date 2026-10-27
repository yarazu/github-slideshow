"""data/history.json – alle produzierten Themen, damit sich nichts wiederholt."""
from __future__ import annotations

import difflib
import json
import logging
import re
from pathlib import Path

from .errors import ConfigError

log = logging.getLogger(__name__)

_STOPWORDS = {
    "der", "die", "das", "den", "dem", "des", "ein", "eine", "einen", "einem", "einer", "und", "oder",
    "warum", "wieso", "weshalb", "was", "wie", "wer", "wir", "du", "dich", "dir", "ist", "sind", "sich",
    "nicht", "mit", "von", "für", "auf", "aus", "bei", "im", "in", "zu", "zum", "zur", "so", "nur",
    "the", "a", "an", "of", "why", "how", "what", "is", "are", "you", "your", "and", "or", "to",
}


_FOLD = str.maketrans({"ä": "a", "ö": "o", "ü": "u", "ß": "ss"})


def _stem(word: str) -> str:
    """Sehr leichte Stammform: 'Träume' ≈ 'Traum', 'Kometen' ≈ 'Komet'."""
    word = word.translate(_FOLD)
    for suffix in ("en", "er", "es", "e", "n", "s"):
        if len(word) > 4 and word.endswith(suffix):
            return word[: -len(suffix)]
    return word


def _content_words(text: str) -> set[str]:
    words = re.findall(r"\w+", text.lower())
    return {_stem(w) for w in words if len(w) > 2 and w not in _STOPWORDS}


def similar(a: str, b: str) -> bool:
    """Ähnlichkeit zweier Themen: fast gleicher Wortlaut oder überwiegend gleiche Kernbegriffe."""
    wa, wb = _content_words(a), _content_words(b)
    if not wa or not wb:
        return False
    if difflib.SequenceMatcher(None, a.lower(), b.lower()).ratio() >= 0.85:
        return True
    shared = len(wa & wb)
    return shared >= min(2, len(wa), len(wb)) and shared / min(len(wa), len(wb)) >= 0.66


class History:
    def __init__(self, path: Path):
        self.path = path
        self.entries: list[dict] = []
        if path.exists():
            try:
                self.entries = json.loads(path.read_text(encoding="utf-8") or "[]")
            except json.JSONDecodeError as exc:
                raise ConfigError(f"{path} ist beschädigt ({exc}). Datei reparieren oder löschen.") from exc
            if not isinstance(self.entries, list):
                raise ConfigError(f"{path} muss eine JSON-Liste sein.")

    def save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps(self.entries, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        tmp.replace(self.path)

    def add(self, entry: dict) -> None:
        self.entries.append(entry)
        self.save()

    def topics(self, niche: str | None = None, limit: int = 60) -> list[str]:
        """Bisherige Themen (neueste zuerst) – für Prompts."""
        rows = [e for e in self.entries if niche is None or e.get("nische") == niche]
        out = []
        for e in reversed(rows):
            label = e.get("titel") or e.get("thema") or ""
            if e.get("thema") and e.get("thema") != label:
                label = f"{label} ({e['thema']})"
            if label:
                out.append(label)
        return out[:limit]

    def find_duplicate(self, topic: str) -> str | None:
        for e in self.entries:
            for field in ("thema", "titel", "hook"):
                old = e.get(field)
                if old and similar(topic, old):
                    return old
        return None

    def used_media_ids(self, last_n: int) -> set[str]:
        ids: set[str] = set()
        for e in self.entries[-last_n:]:
            ids.update(str(i) for i in e.get("media_ids", []))
        return ids

    def recent_music(self, last_n: int = 3) -> set[str]:
        return {e["musik"] for e in self.entries[-last_n:] if e.get("musik")}
