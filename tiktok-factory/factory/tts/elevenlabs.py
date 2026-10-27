"""ElevenLabs (optional) – benötigt ELEVENLABS_API_KEY und eine Voice-ID."""
from __future__ import annotations

import logging
from pathlib import Path

from ..errors import TTSError
from ..utils import HttpError, http_request
from .base import VoiceProvider

log = logging.getLogger(__name__)

# Nur diese Modelle akzeptieren language_code (sonst lehnt die API ab).
_LANGUAGE_CODE_MODELS = ("eleven_turbo_v2_5", "eleven_flash_v2_5")


class ElevenLabsVoice(VoiceProvider):
    name = "elevenlabs"

    def __init__(self, voice_id: str, key: str, model: str = "eleven_multilingual_v2"):
        super().__init__(voice_id)
        self.key = key
        self.model = model

    def _synthesize_raw(self, text: str, work_dir: Path, lang: str, rate_pct: int) -> Path:
        speed = max(0.7, min(1.2, 1.0 + rate_pct / 100))
        body = {
            "text": text,
            "model_id": self.model,
            "voice_settings": {"stability": 0.45, "similarity_boost": 0.8, "style": 0.15,
                               "use_speaker_boost": True, "speed": round(speed, 2)},
        }
        if self.model in _LANGUAGE_CODE_MODELS:
            body["language_code"] = lang
        url = f"https://api.elevenlabs.io/v1/text-to-speech/{self.voice}?output_format=mp3_44100_128"
        headers = {"xi-api-key": self.key, "Accept": "audio/mpeg"}
        log.info("ElevenLabs TTS: Voice %s, Modell %s, Tempo %.2f", self.voice, self.model, speed)
        try:
            resp = http_request("POST", url, json=body, headers=headers, timeout=180)
        except HttpError as exc:
            raise TTSError(f"ElevenLabs nicht erreichbar: {exc}") from exc
        if resp.status_code == 401:
            raise TTSError("ElevenLabs: API-Key ungültig (ELEVENLABS_API_KEY).")
        if resp.status_code == 404:
            raise TTSError(f"ElevenLabs: Voice-ID „{self.voice}“ nicht gefunden (ELEVENLABS_VOICE_ID / --voice).")
        if resp.status_code == 429:
            raise TTSError("ElevenLabs: Kontingent oder Rate-Limit erreicht.")
        if resp.status_code != 200 or not resp.content:
            raise TTSError(f"ElevenLabs: HTTP {resp.status_code} {resp.text[:300]}")
        out = work_dir / "voice_raw.mp3"
        out.write_bytes(resp.content)
        return out
