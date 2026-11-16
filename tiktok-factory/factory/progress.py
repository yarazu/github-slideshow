"""Fortschritt der Pipeline – die Desktop-App zeigt ihn an, überall sonst passiert nichts."""
from __future__ import annotations

# (Schlüssel, Anzeigename, Anteil an der Gesamtdauer in %)
STAGES: list[tuple[str, str, int]] = [
    ("thema", "Thema", 2),
    ("recherche", "Recherche", 12),
    ("skript", "Skript", 10),
    ("stimme", "Stimme", 6),
    ("timing", "Wort-Timing", 8),
    ("broll", "B-Roll", 12),
    ("schnitt", "Schnitt", 24),
    ("ton", "Ton", 6),
    ("render", "Endvideo", 18),
    ("abschluss", "Cover & Texte", 2),
]


class Progress:
    """Basisklasse ohne Wirkung. stage() markiert den Beginn eines Schritts, step() den Anteil darin."""

    def stage(self, key: str, detail: str = "") -> None:
        pass

    def step(self, fraction: float, detail: str = "") -> None:
        pass
