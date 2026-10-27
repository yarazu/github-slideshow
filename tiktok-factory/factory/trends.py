"""data/trends.md – aktuelle Trend-Themen für Deutschland: recherchieren, lesen, auswählen."""
from __future__ import annotations

import logging
import re
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

from .config import Config
from .errors import ScriptError
from .history import History
from .llm import LLM

log = logging.getLogger(__name__)

_DATE_LINE = re.compile(r"^Recherchiert am:\s*(\d{4}-\d{2}-\d{2})(?:[ T](\d{2}:\d{2}))?", re.M)
_IDEA = re.compile(r"^##\s+(\d+)\.\s+(.+?)\s*$")
_FIELD = re.compile(r"^-\s+(Stil-Nische|Warum jetzt|Quelle|Datum|Status):\s*(.*?)\s*$")
_KEYS = {"Stil-Nische": "nische", "Warum jetzt": "warum_jetzt", "Quelle": "quelle", "Datum": "datum",
         "Status": "status"}

EXCLUDED = ("Tragödien, Unglücke, Verbrechen, Krieg, Todesfälle, Krankheitsausbrüche, politische Polarisierung, "
            "Wahlkampf, Gerüchte über reale Personen")


@dataclass
class TrendIdea:
    nr: int
    thema: str
    nische: str = "trend"
    warum_jetzt: str = ""
    quelle: str = ""
    datum: str = ""
    status: str = "offen"

    @property
    def is_open(self) -> bool:
        return self.status.lower().startswith("offen")


def parse_trends(path: Path) -> tuple[datetime | None, list[TrendIdea]]:
    if not path.exists():
        return None, []
    text = path.read_text(encoding="utf-8")
    researched = None
    match = _DATE_LINE.search(text)
    if match:
        researched = datetime.fromisoformat(f"{match.group(1)} {match.group(2) or '00:00'}")
    ideas: list[TrendIdea] = []
    for line in text.splitlines():
        head = _IDEA.match(line)
        if head:
            ideas.append(TrendIdea(nr=int(head.group(1)), thema=head.group(2)))
            continue
        field = _FIELD.match(line)
        if field and ideas:
            setattr(ideas[-1], _KEYS[field.group(1)], field.group(2))
    return researched, ideas


def write_trends(path: Path, ideas: list[TrendIdea], researched: datetime, method: str) -> None:
    lines = [
        "# Trend-Themen Deutschland",
        "",
        f"Recherchiert am: {researched:%Y-%m-%d %H:%M}",
        f"Methode: {method}",
        f"Ausgeschlossen: {EXCLUDED}",
        "",
        "Nutzung: `python make.py --niche trend --count 2` nimmt die obersten offenen Ideen; "
        "der Status wird danach automatisch auf „produziert“ gesetzt.",
        "",
    ]
    for idea in ideas:
        lines += [
            f"## {idea.nr}. {idea.thema}",
            f"- Stil-Nische: {idea.nische}",
            f"- Warum jetzt: {idea.warum_jetzt}",
            f"- Quelle: {idea.quelle}",
            f"- Datum: {idea.datum}",
            f"- Status: {idea.status}",
            "",
        ]
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines), encoding="utf-8")


def is_stale(path: Path, max_age_hours: float, now: datetime | None = None) -> bool:
    researched, ideas = parse_trends(path)
    if researched is None or not ideas:
        return True
    return ((now or datetime.now()) - researched).total_seconds() > max_age_hours * 3600


def mark_produced(path: Path, idea: TrendIdea, folder: str) -> None:
    text = path.read_text(encoding="utf-8")
    block = re.compile(rf"(^##\s+{idea.nr}\.\s+.*?^-\s+Status:\s*)([^\n]*)", re.M | re.S)
    path.write_text(block.sub(lambda m: m.group(1) + f"produziert ({folder})", text, count=1), encoding="utf-8")


def pick_trends(path: Path, history: History, count: int) -> list[TrendIdea]:
    _, ideas = parse_trends(path)
    picked = []
    for idea in ideas:
        if not idea.is_open:
            continue
        dup = history.find_duplicate(idea.thema)
        if dup:
            log.info("Trend-Idee übersprungen (schon produziert: „%s“): %s", dup, idea.thema)
            continue
        picked.append(idea)
        if len(picked) == count:
            break
    return picked


TRENDS_SCHEMA_ITEM = {
    "type": "object",
    "properties": {
        "thema": {"type": "string"},
        "nische": {"type": "string"},
        "warum_jetzt": {"type": "string"},
        "quelle_name": {"type": "string"},
        "quelle_url": {"type": "string"},
        "datum": {"type": "string"},
    },
    "required": ["thema", "nische", "warum_jetzt", "quelle_name", "quelle_url", "datum"],
    "additionalProperties": False,
}


def refresh_trends(llm: LLM, cfg: Config, path: Path, now: datetime | None = None) -> list[TrendIdea]:
    """Recherchiert per Websuche, was in Deutschland gerade Aufmerksamkeit bekommt -> 10 Ideen."""
    now = now or datetime.now()
    niche_keys = list(cfg.niches)
    research = llm.research(
        "Du bist Trend-Scout für ein deutschsprachiges Wissensformat auf TikTok. Du arbeitest gründlich und "
        "belegst jeden Trend mit einer Quelle.",
        f"""Heute ist {now:%A, %d.%m.%Y}. Recherchiere per Websuche, welche Themen in Deutschland in den letzten
7 Tagen viel Aufmerksamkeit bekommen. Prüfe mindestens: Google Trends Deutschland (Tages- und Wochentrends),
TikTok Creative Center (Trends für Deutschland) und Nachrichten der Woche (Wissenschaft, Technik, Natur, Kultur,
Sport, Kurioses).

Leite daraus 10 Themenideen für 70-Sekunden-Wissensvideos ab: Der Trend ist nur der Aufhänger, der Kern ist
zeitlos interessantes, überprüfbares Wissen (Beispiel: Trend „Zeitumstellung“ → „Warum die Zeitumstellung deinen
Körper tagelang verwirrt“).
Ausschluss: {EXCLUDED}. Kein Clickbait mit Leid oder Streit.
Für jede Idee: Thema (Arbeitstitel), passende Stil-Nische aus [{", ".join(niche_keys)}], warum das gerade relevant
ist (1 Satz), Quelle (Name + URL, die den Trend belegt), Datum der Quelle (JJJJ-MM-TT).""",
        max_searches=cfg.trends.max_searches)
    data = llm.structured(
        "Du überträgst Recherche-Notizen exakt in das vorgegebene JSON-Format, ohne etwas zu erfinden.",
        f"Übertrage die 10 Themenideen aus diesen Notizen. nische muss einer dieser Werte sein: "
        f"{', '.join(niche_keys)}.\n\n<notizen>\n{research.text}\n</notizen>",
        {"type": "object", "properties": {"ideen": {"type": "array", "items": TRENDS_SCHEMA_ITEM}},
         "required": ["ideen"], "additionalProperties": False},
        effort="low")
    ideas = []
    for i, raw in enumerate(data.get("ideen", [])[:10], 1):
        nische = raw["nische"] if raw["nische"] in cfg.niches else "trend"
        ideas.append(TrendIdea(nr=i, thema=raw["thema"].strip(), nische=nische, warum_jetzt=raw["warum_jetzt"].strip(),
                               quelle=f"{raw['quelle_name'].strip()} – {raw['quelle_url'].strip()}",
                               datum=raw["datum"].strip()))
    if not ideas:
        raise ScriptError("Trend-Recherche lieferte keine Ideen.")
    write_trends(path, ideas, now, "Claude-Websuche (Google Trends DE, TikTok Creative Center, Nachrichten der Woche)")
    log.info("data/trends.md aktualisiert: %d Ideen", len(ideas))
    return ideas
