"""Neue Nischen entdecken: Claude recherchiert Vorschläge, die App übernimmt sie mit einem Klick.

Vorschläge liegen in data/nischen_ideen.json. Übernommene Nischen stehen in config/niches_eigene.yaml
(gleiches Format wie niches.yaml, von Hand editierbar) und erscheinen überall wie die mitgelieferten.
"""
from __future__ import annotations

import json
import logging
import re
from datetime import datetime, timedelta
from pathlib import Path

import yaml

from .config import Config
from .errors import ConfigError, ScriptError
from .llm import LLM
from .script import normalize_hashtags
from .utils import slugify

log = logging.getLogger(__name__)

MOODS = ("nachdenklich", "mystisch", "episch", "leicht", "ruhig", "modern")
VOICES = {"männlich": ("de-DE-ConradNeural", "en-US-AndrewNeural"),
          "weiblich": ("de-DE-KatjaNeural", "en-US-AvaNeural")}
EXCLUDED = ("Tragödien, Unglücke, Verbrechen, politische Polarisierung, Gesundheits-, Rechts- oder Finanzberatung, "
            "Glücksspiel, Erwachsenen-Inhalte, Gerüchte über reale Personen, Inhalte mit fremdem geschütztem Material")

IDEAS_SCHEMA = {
    "type": "object",
    "properties": {"ideen": {"type": "array", "items": {
        "type": "object",
        "properties": {
            "name": {"type": "string"},
            "warum": {"type": "string"},
            "quelle_name": {"type": "string"},
            "quelle_url": {"type": "string"},
            "tonalitaet": {"type": "string"},
            "stimme": {"type": "string", "enum": list(VOICES)},
            "musik_stimmung": {"type": "string", "enum": list(MOODS)},
            "hashtags": {"type": "array", "items": {"type": "string"}},
            "pexels_stil": {"type": "array", "items": {"type": "string"}},
            "themenfelder": {"type": "array", "items": {"type": "string"}},
            "regeln": {"type": "array", "items": {"type": "string"}},
        },
        "required": ["name", "warum", "quelle_name", "quelle_url", "tonalitaet", "stimme", "musik_stimmung",
                     "hashtags", "pexels_stil", "themenfelder", "regeln"],
        "additionalProperties": False,
    }}},
    "required": ["ideen"],
    "additionalProperties": False,
}


def ideas_file(cfg: Config) -> Path:
    return cfg.paths.data / "nischen_ideen.json"


def load_ideas(cfg: Config) -> dict:
    """{'recherchiert': ISO-Zeit oder None, 'ideen': [...]} – jede Idee mit 'key' und 'uebernommen'."""
    path = ideas_file(cfg)
    data = {"recherchiert": None, "ideen": []}
    if path.exists():
        try:
            stored = json.loads(path.read_text(encoding="utf-8"))
            if isinstance(stored, dict) and isinstance(stored.get("ideen"), list):
                data = {"recherchiert": stored.get("recherchiert"), "ideen": stored["ideen"]}
        except (OSError, json.JSONDecodeError):
            log.warning("data/nischen_ideen.json ist beschädigt und wird ignoriert.")
    for idea in data["ideen"]:
        idea["uebernommen"] = idea.get("key") in cfg.custom_niches
    return data


def ideas_stale(cfg: Config, days: float = 7, now: datetime | None = None) -> bool:
    stamp = load_ideas(cfg)["recherchiert"]
    if not stamp:
        return True
    try:
        return (now or datetime.now()) - datetime.fromisoformat(stamp) > timedelta(days=days)
    except ValueError:
        return True


def _unique_key(name: str, taken: set[str]) -> str:
    base = re.sub(r"[^a-z0-9]+", "_", slugify(name, 28)).strip("_") or "nische"
    key, n = base, 2
    while key in taken:
        key, n = f"{base}_{n}", n + 1
    return key


def discover_niches(llm: LLM, cfg: Config, count: int = 6, now: datetime | None = None) -> list[dict]:
    """Recherchiert per Websuche neue Nischen-Vorschläge und speichert sie."""
    now = now or datetime.now()
    known = [n.name for n in cfg.niches.values()]
    research = llm.research(
        "Du bist Stratege für gesichtslose Wissensvideos auf TikTok im deutschsprachigen Raum. Du belegst jede "
        "Einschätzung mit einer Quelle und empfiehlst nur Nischen, die sich mit überprüfbaren Fakten füllen lassen.",
        f"""Heute ist {now:%d.%m.%Y}. Recherchiere per Websuche, welche Themen-Nischen für Wissens- und Faktenvideos
(61–90 Sekunden, Sprecherstimme, Stock-Videos, ohne Gesicht) auf TikTok in Deutschland gerade gut laufen oder wachsen:
TikTok Creative Center, Berichte über erfolgreiche Formate, Suchtrends, Creator-Analysen.

Diese Nischen gibt es schon – schlage nichts vor, was sich damit überschneidet:
{chr(10).join(f"- {n}" for n in known)}

Schlage {count} neue Nischen vor. Jede muss dauerhaft viele Themen hergeben (mindestens 50 Videos), mit
frei nutzbaren Stock-Clips bebilderbar sein und ohne persönliche Ratschläge auskommen.
Ausschluss: {EXCLUDED}.
Für jede Nische: Name, warum sie gerade funktioniert (1–2 Sätze, mit Quelle: Name + URL), Tonalität,
6–8 Themenfelder, 6 Hashtags, 5 englische Stichworte für passende Stock-Videos und 1–2 Regeln, was zu vermeiden ist.""",
        max_searches=cfg.trends.max_searches)
    data = llm.structured(
        "Du überträgst Recherche-Notizen exakt in das vorgegebene JSON-Format, ohne etwas zu erfinden.",
        f"Übertrage die Nischen-Vorschläge aus diesen Notizen. stimme: passende Sprecherstimme; musik_stimmung: "
        f"passende Stimmung aus {', '.join(MOODS)}.\n\n<notizen>\n{research.text}\n</notizen>",
        IDEAS_SCHEMA, effort="low")
    taken = set(cfg.niches)
    ideas = []
    for raw in data.get("ideen", [])[:count]:
        name = " ".join(str(raw["name"]).split())[:60]
        if not name:
            continue
        key = _unique_key(name, taken)
        taken.add(key)
        url = raw["quelle_url"].strip()
        ideas.append({
            "key": key, "name": name, "warum": raw["warum"].strip(),
            "quelle_name": raw["quelle_name"].strip(), "quelle_url": url if url.startswith("http") else "",
            "tonalitaet": raw["tonalitaet"].strip(), "stimme": raw["stimme"], "musik_stimmung": raw["musik_stimmung"],
            "hashtags": normalize_hashtags(raw["hashtags"])[:8],
            "pexels_stil": [s.strip() for s in raw["pexels_stil"] if s.strip()][:6],
            "themenfelder": [s.strip() for s in raw["themenfelder"] if s.strip()][:10],
            "regeln": [s.strip() for s in raw["regeln"] if s.strip()][:4],
        })
    if not ideas:
        raise ScriptError("Die Nischen-Recherche lieferte keine Vorschläge.")
    path = ideas_file(cfg)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"recherchiert": now.isoformat(timespec="minutes"), "ideen": ideas},
                               ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    log.info("%d neue Nischen-Vorschläge gespeichert", len(ideas))
    return ideas


def _write_custom(cfg: Config, niches: dict) -> None:
    path = cfg.custom_niches_file
    header = ("# Eigene und aus der App übernommene Nischen – gleiches Format wie niches.yaml.\n"
              "# Von Hand editierbar; die App schreibt diese Datei neu, wenn du Nischen übernimmst oder entfernst.\n")
    path.write_text(header + yaml.safe_dump({"evergreen": niches}, allow_unicode=True, sort_keys=False, width=110),
                    encoding="utf-8")
    cfg.load_niches()


def _read_custom(cfg: Config) -> dict:
    path = cfg.custom_niches_file
    if not path.exists():
        return {}
    data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    return dict(data.get("evergreen") or {})


def add_niche(cfg: Config, key: str) -> None:
    """Übernimmt einen Vorschlag als echte Nische (sofort im Studio wählbar)."""
    idea = next((i for i in load_ideas(cfg)["ideen"] if i.get("key") == key), None)
    if idea is None:
        raise ConfigError("Dieser Vorschlag ist nicht mehr vorhanden – bitte neu suchen.")
    if key in cfg.niches:
        raise ConfigError("Diese Nische gibt es schon.")
    voice_de, voice_en = VOICES.get(idea.get("stimme"), VOICES["männlich"])
    custom = _read_custom(cfg)
    custom[key] = {
        "name": idea["name"], "tonalitaet": idea["tonalitaet"], "stimme": voice_de, "stimme_en": voice_en,
        "musik_stimmung": idea["musik_stimmung"] if idea.get("musik_stimmung") in MOODS else "modern",
        "hashtags": idea["hashtags"] or ["#wusstestdu", "#fakten", "#lernenmittiktok"],
        "pexels_stil": idea["pexels_stil"] or ["nature", "city", "abstract light"],
        "themenfelder": idea.get("themenfelder", []), "regeln": idea.get("regeln", []),
    }
    _write_custom(cfg, custom)
    log.info("Nische übernommen: %s", idea["name"])


def remove_niche(cfg: Config, key: str) -> None:
    custom = _read_custom(cfg)
    if key not in custom:
        raise ConfigError("Nur selbst übernommene Nischen lassen sich hier entfernen.")
    del custom[key]
    _write_custom(cfg, custom)
