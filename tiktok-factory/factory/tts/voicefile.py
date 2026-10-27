"""Eigene Aufnahme (--voice-file aufnahme.mp3)."""
from __future__ import annotations

from pathlib import Path

from ..errors import TTSError
from .base import VoiceProvider


class VoiceFile(VoiceProvider):
    name = "eigene-aufnahme"
    can_resynthesize = False

    def __init__(self, path: Path):
        path = path.expanduser().resolve()
        if not path.is_file():
            raise TTSError(f"Aufnahme nicht gefunden: {path}")
        super().__init__(path.name)
        self.path = path

    def _synthesize_raw(self, text: str, work_dir: Path, lang: str, rate_pct: int) -> Path:
        return self.path
