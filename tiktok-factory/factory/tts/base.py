"""Gemeinsames Interface aller Stimmen-Anbieter."""
from __future__ import annotations

from abc import ABC, abstractmethod
from pathlib import Path

from ..media import run_ffmpeg

# Stille am Anfang/Ende kappen: der Hook soll in Sekunde 0 beginnen.
_TRIM = ("silenceremove=start_periods=1:start_threshold=-50dB:start_silence=0.05,"
         "areverse,silenceremove=start_periods=1:start_threshold=-50dB:start_silence=0.1,areverse")


def normalize_voice(src: Path, dst: Path) -> Path:
    """Beliebige Audiodatei -> 48 kHz Mono-WAV ohne Stille an den Rändern."""
    run_ffmpeg(["-i", src, "-vn", "-af", _TRIM, "-ac", "1", "-ar", "48000", "-c:a", "pcm_s16le", dst],
               "Stimme aufbereiten")
    return dst


class VoiceProvider(ABC):
    """Erzeugt die Sprecherspur für einen Text.

    can_resynthesize=False bedeutet: die Länge lässt sich nicht durch Neuvertonung ändern
    (eigene Aufnahme).
    """

    name = "?"
    can_resynthesize = True

    def __init__(self, voice: str | None):
        self.voice = voice

    @abstractmethod
    def _synthesize_raw(self, text: str, work_dir: Path, lang: str, rate_pct: int) -> Path:
        """Rohaudio erzeugen und Pfad zurückgeben."""

    def synthesize(self, text: str, work_dir: Path, lang: str = "de", rate_pct: int = 0) -> Path:
        """Vertont text und liefert work_dir/voice.wav (48 kHz, mono, Ränder ohne Stille).

        rate_pct: zusätzliche Tempoänderung in Prozent (z. B. -6 = langsamer).
        """
        work_dir.mkdir(parents=True, exist_ok=True)
        raw = self._synthesize_raw(text, work_dir, lang, rate_pct)
        return normalize_voice(raw, work_dir / "voice.wav")

    def describe(self) -> str:
        return f"{self.name}:{self.voice}" if self.voice else self.name
