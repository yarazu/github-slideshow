"""Stimmen-Auswahl: Azure (Standard), ElevenLabs oder eigene Aufnahme."""
from __future__ import annotations

from pathlib import Path

from ..config import Config, Niche
from ..errors import ConfigError
from .azure import AzureVoice
from .base import VoiceProvider
from .elevenlabs import ElevenLabsVoice
from .voicefile import VoiceFile

PROVIDERS = ("azure", "elevenlabs")

__all__ = ["VoiceProvider", "get_voice", "required_keys"]


def _split_voice_arg(cfg: Config, voice_arg: str | None) -> tuple[str, str | None]:
    """--voice akzeptiert: 'de-DE-KatjaNeural', 'azure', 'elevenlabs', 'elevenlabs:<voice_id>'."""
    provider = (cfg.env("TTS_PROVIDER", "azure") or "azure").lower()
    if not voice_arg:
        return provider, None
    if ":" in voice_arg:
        provider, voice = voice_arg.split(":", 1)
        return provider.lower(), voice or None
    if voice_arg.lower() in PROVIDERS:
        return voice_arg.lower(), None
    if voice_arg.endswith("Neural"):
        return "azure", voice_arg
    return provider, voice_arg


def required_keys(cfg: Config, voice_arg: str | None, voice_file: Path | None) -> list[str]:
    """Welche .env-Keys die gewählte Stimme braucht (für die Prüfung vor dem Start)."""
    if voice_file:
        return []
    provider, voice = _split_voice_arg(cfg, voice_arg)
    if provider == "azure":
        return [k for k in ("AZURE_SPEECH_KEY",) if not cfg.env(k)]
    if provider == "elevenlabs":
        missing = [k for k in ("ELEVENLABS_API_KEY",) if not cfg.env(k)]
        if not voice and not cfg.env("ELEVENLABS_VOICE_ID"):
            missing.append("ELEVENLABS_VOICE_ID")
        return missing
    raise ConfigError(f"Unbekannter Stimmen-Anbieter „{provider}“ (TTS_PROVIDER/--voice): {', '.join(PROVIDERS)}")


def get_voice(cfg: Config, niche: Niche, lang: str, voice_arg: str | None = None,
              voice_file: Path | None = None) -> VoiceProvider:
    if voice_file:
        return VoiceFile(voice_file)
    provider, voice = _split_voice_arg(cfg, voice_arg)
    missing = required_keys(cfg, voice_arg, None)
    if missing:
        raise ConfigError(f"Für die Stimme „{provider}“ fehlt in .env: {', '.join(missing)}")
    if provider == "azure":
        return AzureVoice(voice=voice or niche.voice_for(lang), key=cfg.env("AZURE_SPEECH_KEY"),
                          region=cfg.env("AZURE_SPEECH_REGION", "westeurope"),
                          base_rate=cfg.env("AZURE_SPEECH_RATE", "+0%"))
    return ElevenLabsVoice(voice_id=voice or cfg.env("ELEVENLABS_VOICE_ID"), key=cfg.env("ELEVENLABS_API_KEY"),
                           model=cfg.env("ELEVENLABS_MODEL", "eleven_multilingual_v2"))
