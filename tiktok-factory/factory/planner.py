"""Aus einer Anfrage (Nische, Thema, Trend, eigenes Skript) werden Jobs – gemeinsam für CLI und App."""
from __future__ import annotations

import logging
from collections.abc import Callable

from .config import Config
from .errors import ConfigError
from .history import History
from .llm import LLM
from .pipeline import Job, niche_for_trend
from .script import Script, propose_topics
from .trends import is_stale, parse_trends, pick_trends, refresh_trends

log = logging.getLogger(__name__)


def script_job(cfg: Config, script: Script, niche_key: str | None, lang: str) -> Job:
    niche = cfg.niche(niche_key or cfg.script.default_niche)
    return Job(niche=niche, topic=script.titel, script=script, lang=lang)


def topic_job(cfg: Config, history: History, topic: str, niche_key: str | None, lang: str) -> Job:
    niche = cfg.niche(niche_key or cfg.script.default_niche)
    dup = history.find_duplicate(topic)
    if dup:
        log.warning("Ähnliches Thema gab es schon: „%s“ – wird trotzdem produziert (neuer Winkel).", dup)
    return Job(niche=niche, topic=topic, lang=lang)


def niche_jobs(cfg: Config, history: History, llm: LLM, niche_key: str, count: int, lang: str) -> list[Job]:
    """Claude schlägt count neue Themen der Nische vor (ohne Wiederholungen)."""
    niche = cfg.niche(niche_key)
    ideas = propose_topics(llm, cfg, niche, history, count, lang)
    for idea in ideas:
        log.info("Thema: %s – %s", idea["thema"], idea["winkel"])
    return [Job(niche=niche, topic=i["thema"], angle=i["winkel"], lang=lang) for i in ideas]


def trend_jobs(cfg: Config, history: History, llm_factory: Callable[[], LLM], count: int, lang: str, *,
               numbers: list[int] | None = None) -> list[Job]:
    """Trend-Ideen aus data/trends.md. Mit numbers: genau diese Ideen; sonst die obersten offenen.

    Ohne numbers wird die Datei vorher neu recherchiert, wenn sie älter als trends.max_age_hours ist.
    """
    trends_md = cfg.paths.data / "trends.md"
    if numbers:
        _, all_ideas = parse_trends(trends_md)
        by_nr = {i.nr: i for i in all_ideas}
        missing = [n for n in numbers if n not in by_nr]
        if missing:
            raise ConfigError(f"Trend-Idee(n) {', '.join(map(str, missing))} stehen nicht in data/trends.md.")
        ideas = [by_nr[n] for n in numbers]
    else:
        if is_stale(trends_md, cfg.trends.max_age_hours):
            log.info("data/trends.md ist älter als %s h – neue Trend-Recherche …", cfg.trends.max_age_hours)
            refresh_trends(llm_factory(), cfg, trends_md)
        ideas = pick_trends(trends_md, history, count)
        if not ideas:
            raise ConfigError("Keine offenen Trend-Ideen in data/trends.md – bitte Trends neu recherchieren.")
        if len(ideas) < count:
            log.warning("Nur %d offene Trend-Ideen verfügbar.", len(ideas))
    return [Job(niche=niche_for_trend(cfg, i), topic=i.thema, angle=i.warum_jetzt, trend=i, lang=lang)
            for i in ideas]
