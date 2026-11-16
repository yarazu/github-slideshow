"""Lädt .env, config/settings.yaml und config/niches.yaml."""
from __future__ import annotations

import os
import unicodedata
from dataclasses import dataclass, field
from pathlib import Path
from types import SimpleNamespace
from typing import Any

import yaml
from dotenv import load_dotenv

from .errors import ConfigError

ROOT = Path(__file__).resolve().parent.parent


def _namespace(value: Any) -> Any:
    if isinstance(value, dict):
        return SimpleNamespace(**{k: _namespace(v) for k, v in value.items()})
    if isinstance(value, list):
        return [_namespace(v) for v in value]
    return value


def _load_yaml(path: Path) -> dict:
    if not path.exists():
        raise ConfigError(f"Konfigurationsdatei fehlt: {path}")
    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    except yaml.YAMLError as exc:
        raise ConfigError(f"{path.name} ist kein gültiges YAML: {exc}") from exc
    if not isinstance(data, dict):
        raise ConfigError(f"{path.name} muss ein YAML-Objekt enthalten.")
    return data


def _fold(text: str) -> str:
    """'Psychologie', 'psychologie ' und 'Wusstest-Du' vergleichbar machen."""
    text = unicodedata.normalize("NFKD", text.strip().lower())
    return "".join(c for c in text if c.isalnum())


@dataclass(frozen=True)
class Paths:
    root: Path
    config: Path
    data: Path
    music: Path
    broll: Path
    fonts: Path
    output: Path
    work: Path
    cache: Path
    logs: Path

    @classmethod
    def from_root(cls, root: Path) -> "Paths":
        return cls(
            root=root,
            config=root / "config",
            data=root / "data",
            music=root / "assets" / "music",
            broll=root / "assets" / "broll",
            fonts=root / "assets" / "fonts",
            output=root / "output",
            work=root / "work",
            cache=root / "cache",
            logs=root / "logs",
        )


@dataclass
class Niche:
    key: str
    gruppe: str  # "evergreen" | "trend"
    name: str
    tonalitaet: str
    stimme: str
    stimme_en: str
    musik_stimmung: str
    hashtags: list[str]
    pexels_stil: list[str]
    themenfelder: list[str] = field(default_factory=list)
    regeln: list[str] = field(default_factory=list)

    def voice_for(self, lang: str) -> str:
        return self.stimme_en if lang == "en" else self.stimme


# Werte, die in älteren settings.yaml fehlen dürfen
_DEFAULTS: dict[str, dict] = {
    "subtitles": {"hook_style": "glass"},
    "glass": {"font_px": 88, "radius": 60, "padding_x": 58, "padding_y": 44, "margin": 70, "blur": 28,
              "tint": "#0E1118", "tint_opacity": 0.34, "text_color": "#FFFFFF"},
}

_NICHE_FIELDS = ("name", "tonalitaet", "stimme", "stimme_en", "musik_stimmung", "hashtags", "pexels_stil")


def _parse_niches(data: dict) -> dict[str, Niche]:
    niches: dict[str, Niche] = {}
    for gruppe in ("evergreen", "trend"):
        for key, raw in (data.get(gruppe) or {}).items():
            missing = [f for f in _NICHE_FIELDS if not raw.get(f)]
            if missing:
                raise ConfigError(f"niches.yaml: Nische '{key}' ohne Feld(er) {', '.join(missing)}")
            niches[key] = Niche(
                key=key,
                gruppe=gruppe,
                name=raw["name"],
                tonalitaet=raw["tonalitaet"],
                stimme=raw["stimme"],
                stimme_en=raw["stimme_en"],
                musik_stimmung=raw["musik_stimmung"],
                hashtags=list(raw["hashtags"]),
                pexels_stil=list(raw["pexels_stil"]),
                themenfelder=list(raw.get("themenfelder") or []),
                regeln=list(raw.get("regeln") or []),
            )
    if not niches:
        raise ConfigError("niches.yaml enthält keine Nischen (Gruppen 'evergreen' und 'trend').")
    return niches


class Config:
    """Alle Einstellungen an einem Ort. Settings-Abschnitte als Attribute: cfg.video.fps"""

    def __init__(self, root: Path = ROOT):
        self.paths = Paths.from_root(root)
        load_dotenv(root / ".env", override=False)
        settings = _load_yaml(self.paths.config / "settings.yaml")
        for section in ("video", "duration", "audio", "subtitles", "whisper", "script", "broll", "trends"):
            if section not in settings:
                raise ConfigError(f"settings.yaml: Abschnitt '{section}' fehlt.")
        for section, defaults in _DEFAULTS.items():  # später hinzugekommene Einstellungen
            settings[section] = {**defaults, **(settings.get(section) or {})}
        for section, values in settings.items():
            if isinstance(values, dict):
                setattr(self, section, _namespace(values))
        self.custom_niches_file = self.paths.config / "niches_eigene.yaml"
        self.custom_niches: set[str] = set()
        self.niches: dict[str, Niche] = {}
        self.load_niches()

    def load_niches(self) -> None:
        """niches.yaml + (falls vorhanden) niches_eigene.yaml; ändert self.niches an Ort und Stelle."""
        data = _load_yaml(self.paths.config / "niches.yaml")
        custom: set[str] = set()
        if self.custom_niches_file.exists():
            extra = _load_yaml(self.custom_niches_file).get("evergreen") or {}
            taken = set(data.get("evergreen") or {}) | set(data.get("trend") or {})
            for key, raw in extra.items():
                if key not in taken:
                    data.setdefault("evergreen", {})[key] = raw
                    custom.add(key)
        parsed = _parse_niches(data)
        self.niches.clear()
        self.niches.update(parsed)
        self.custom_niches = custom

    # --- .env -----------------------------------------------------------------
    @staticmethod
    def env(name: str, default: str | None = None) -> str | None:
        value = os.environ.get(name)
        if value is None or not value.strip():
            return default
        return value.strip()

    def env_bool(self, name: str, default: bool) -> bool:
        value = self.env(name)
        if value is None:
            return default
        return value.lower() in ("1", "true", "yes", "ja", "on")

    # --- Nischen --------------------------------------------------------------
    def niche(self, key: str) -> Niche:
        wanted = _fold(key)
        for niche in self.niches.values():
            if wanted in (_fold(niche.key), _fold(niche.name)):
                return niche
        # Präfix erlauben: "psycho" -> psychologie
        matches = [n for n in self.niches.values() if _fold(n.key).startswith(wanted)]
        if len(matches) == 1:
            return matches[0]
        valid = ", ".join(self.niches)
        raise ConfigError(f"Unbekannte Nische '{key}'. Verfügbar: {valid}")

    def evergreen_niches(self) -> list[Niche]:
        return [n for n in self.niches.values() if n.gruppe == "evergreen"]
