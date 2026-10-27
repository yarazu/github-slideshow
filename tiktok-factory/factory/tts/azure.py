"""Azure AI Speech (REST, ohne SDK) – Standardstimme, kommerziell nutzbar."""
from __future__ import annotations

import logging
import re
from pathlib import Path
from xml.sax.saxutils import escape

from ..errors import TTSError
from ..utils import HttpError, http_request
from .base import VoiceProvider

log = logging.getLogger(__name__)


def _parse_rate(rate: str) -> int:
    match = re.fullmatch(r"\s*([+-]?\d+)\s*%?\s*", rate or "0")
    if not match:
        raise TTSError(f"AZURE_SPEECH_RATE „{rate}“ ungültig – Format z. B. +5%")
    return int(match.group(1))


class AzureVoice(VoiceProvider):
    name = "azure"

    def __init__(self, voice: str, key: str, region: str, base_rate: str = "+0%"):
        super().__init__(voice)
        self.key = key
        self.region = region
        self.base_rate = _parse_rate(base_rate)

    def ssml(self, text: str, rate_pct: int = 0) -> str:
        lang_match = re.match(r"^([a-z]{2}-[A-Z]{2})-", self.voice or "")
        xml_lang = lang_match.group(1) if lang_match else "de-DE"
        rate = self.base_rate + rate_pct
        return (f'<speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" xml:lang="{xml_lang}">'
                f'<voice name="{escape(self.voice)}"><prosody rate="{rate:+d}%">{escape(text)}</prosody>'
                "</voice></speak>")

    def _synthesize_raw(self, text: str, work_dir: Path, lang: str, rate_pct: int) -> Path:
        url = f"https://{self.region}.tts.speech.microsoft.com/cognitiveservices/v1"
        headers = {
            "Ocp-Apim-Subscription-Key": self.key,
            "Content-Type": "application/ssml+xml",
            "X-Microsoft-OutputFormat": "riff-48khz-16bit-mono-pcm",
        }
        log.info("Azure TTS: %s, Tempo %+d%%", self.voice, self.base_rate + rate_pct)
        try:
            resp = http_request("POST", url, data=self.ssml(text, rate_pct).encode("utf-8"), headers=headers,
                                timeout=180)
        except HttpError as exc:
            raise TTSError(f"Azure Speech nicht erreichbar ({self.region}): {exc}") from exc
        if resp.status_code == 401:
            raise TTSError("Azure Speech: Key ungültig oder Region falsch (AZURE_SPEECH_KEY / AZURE_SPEECH_REGION).")
        if resp.status_code == 400:
            raise TTSError(f"Azure Speech lehnt die Anfrage ab – gibt es die Stimme „{self.voice}“ in Region "
                           f"„{self.region}“? Antwort: {resp.text[:300]}")
        if resp.status_code == 429:
            raise TTSError("Azure Speech: Kontingent/Rate-Limit erreicht (Free-Tier: 0,5 Mio. Zeichen/Monat).")
        if resp.status_code != 200 or not resp.content:
            raise TTSError(f"Azure Speech: HTTP {resp.status_code} {resp.text[:300]}")
        out = work_dir / "voice_raw.wav"
        out.write_bytes(resp.content)
        return out
