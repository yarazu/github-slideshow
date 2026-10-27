#!/usr/bin/env python3
"""tiktok-factory – erzeugt upload-fertige TikTok-Videos aus einer Nische oder einem Thema.

Beispiele:
  python make.py --niche psychologie --count 3
  python make.py --topic "Warum wir Träume sofort vergessen"
  python make.py --niche trend --count 2
  python make.py --script-file mein_skript.json
"""
from __future__ import annotations

import argparse
import logging
import sys
import time
from pathlib import Path

from factory.config import Config
from factory.errors import ConfigError, FactoryError
from factory.history import History
from factory.llm import api_key
from factory.log import setup_logging
from factory.media import check_ffmpeg
from factory.pipeline import Job, Options, Pipeline, niche_for_trend
from factory.script import load_script_file, propose_topics
from factory.trends import is_stale, parse_trends, pick_trends, refresh_trends
from factory.tts import required_keys

log = logging.getLogger("make")


def parse_args(argv: list[str] | None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        prog="make.py",
        description="Erzeugt upload-fertige TikTok-Videos (1080×1920, 61–90 s) mit Stimme, Untertiteln, "
                    "B-Roll und Musik.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Beispiele:" + __doc__.split("Beispiele:", 1)[1])
    source = p.add_mutually_exclusive_group()
    source.add_argument("--topic", help="konkretes Thema (eine Nische als Stil ist optional)")
    source.add_argument("--script-file", type=Path, help="eigenes Skript als JSON – ohne Anthropic-API")
    p.add_argument("--niche", help="Nische aus config/niches.yaml, z. B. psychologie oder trend")
    p.add_argument("--count", type=int, default=1, help="Anzahl Videos (nur mit --niche)")
    p.add_argument("--voice", help="Stimme: z. B. de-DE-KatjaNeural, azure, elevenlabs oder elevenlabs:<voice_id>")
    p.add_argument("--voice-file", type=Path, help="eigene Aufnahme statt KI-Stimme (mit --script-file)")
    p.add_argument("--lang", choices=["de", "en"], default="de", help="Sprache (Standard: de)")
    p.add_argument("--no-music", action="store_true", help="ohne Hintergrundmusik")
    p.add_argument("--script-only", action="store_true",
                   help="nur Skript erzeugen (zum Selbst-Einsprechen), kein Video")
    p.add_argument("--refresh-trends", action="store_true", help="data/trends.md jetzt neu recherchieren")
    p.add_argument("--no-whisper", action="store_true",
                   help="Wortzeiten schätzen statt faster-whisper (nur für Tests/offline)")
    p.add_argument("--keep-work", action="store_true", help="Zwischendateien in work/ behalten")
    p.add_argument("--list-niches", action="store_true", help="verfügbare Nischen anzeigen")
    p.add_argument("-v", "--verbose", action="store_true", help="ausführliche Ausgabe")
    args = p.parse_args(argv)

    if not (args.niche or args.topic or args.script_file or args.refresh_trends or args.list_niches):
        p.error("Bitte --niche, --topic, --script-file, --refresh-trends oder --list-niches angeben.")
    if args.count < 1:
        p.error("--count muss mindestens 1 sein.")
    if args.count > 1 and not args.niche:
        p.error("--count geht nur zusammen mit --niche.")
    if args.count > 1 and (args.topic or args.script_file):
        p.error("--count geht nicht mit --topic oder --script-file.")
    if args.voice_file and not args.script_file:
        p.error("--voice-file braucht das passende Skript: erst `--topic … --script-only`, einsprechen, dann "
                "`--script-file output/…/skript.json --voice-file aufnahme.mp3`.")
    if args.voice_file and args.voice:
        p.error("--voice und --voice-file schließen sich aus.")
    if args.script_only and args.script_file:
        p.error("--script-only erzeugt ein Skript – mit --script-file gibt es schon eins.")
    return args


def preflight(cfg: Config, args: argparse.Namespace, needs_llm: bool) -> None:
    """Prüft vor dem Start alles, was fehlen kann – mit einer einzigen, klaren Meldung."""
    if not args.script_only:
        log.info("ffmpeg: %s", check_ffmpeg())
    missing = []
    if needs_llm and not api_key(cfg):
        missing.append("ANTHROPIC_API_KEY")
    if not args.script_only:
        missing += required_keys(cfg, args.voice, args.voice_file)
        if not cfg.env("PEXELS_API_KEY"):
            log.warning("PEXELS_API_KEY fehlt – B-Roll nur aus assets/broll/ bzw. Farbflächen.")
    if missing:
        raise ConfigError(f"Fehlende Keys in .env: {', '.join(missing)}\n"
                          f"Vorlage: .env.example – woher die Keys kommen, steht in der README.")


def build_jobs(cfg: Config, args: argparse.Namespace, pipeline: Pipeline, history: History) -> list[Job]:
    if args.script_file:
        script = load_script_file(args.script_file)
        niche = cfg.niche(args.niche or cfg.script.default_niche)
        return [Job(niche=niche, topic=script.titel, script=script, lang=args.lang)]
    if args.topic:
        niche = cfg.niche(args.niche or cfg.script.default_niche)
        dup = history.find_duplicate(args.topic)
        if dup:
            log.warning("Ähnliches Thema gab es schon: „%s“ – wird trotzdem produziert (neuer Winkel).", dup)
        return [Job(niche=niche, topic=args.topic, lang=args.lang)]

    niche = cfg.niche(args.niche)
    if niche.key == "trend":
        trends_md = cfg.paths.data / "trends.md"
        if is_stale(trends_md, cfg.trends.max_age_hours):
            log.info("data/trends.md ist älter als %s h – neue Trend-Recherche …", cfg.trends.max_age_hours)
            refresh_trends(pipeline.llm, cfg, trends_md)
        ideas = pick_trends(trends_md, history, args.count)
        if not ideas:
            raise ConfigError("Keine offenen Trend-Ideen in data/trends.md – `python make.py --refresh-trends`.")
        if len(ideas) < args.count:
            log.warning("Nur %d offene Trend-Ideen verfügbar.", len(ideas))
        return [Job(niche=niche_for_trend(cfg, i), topic=i.thema, angle=i.warum_jetzt, trend=i, lang=args.lang)
                for i in ideas]

    ideas = propose_topics(pipeline.llm, cfg, niche, history, args.count, args.lang)
    for i in ideas:
        log.info("Thema: %s – %s", i["thema"], i["winkel"])
    return [Job(niche=niche, topic=i["thema"], angle=i["winkel"], lang=args.lang) for i in ideas]


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    cfg = Config()
    log_file = setup_logging(cfg.paths.logs, args.verbose)

    if args.list_niches:
        for niche in cfg.niches.values():
            print(f"{niche.key:<12} [{niche.gruppe}] {niche.name}")
        return 0

    history = History(cfg.paths.data / "history.json")
    options = Options(voice=args.voice, voice_file=args.voice_file, music=not args.no_music,
                      whisper=not args.no_whisper, script_only=args.script_only, keep_work=args.keep_work,
                      web_search=cfg.env_bool("SCRIPT_WEB_SEARCH", True))
    pipeline = Pipeline(cfg, history, options)
    try:
        if args.niche:
            cfg.niche(args.niche)  # Tippfehler sofort melden
        trends_md = cfg.paths.data / "trends.md"
        if args.refresh_trends:
            refresh_trends(pipeline.llm, cfg, trends_md)
            _, ideas = parse_trends(trends_md)
            for idea in ideas:
                print(f"{idea.nr:>2}. {idea.thema}  [{idea.nische}]")
            if not (args.niche or args.topic or args.script_file):
                return 0
        preflight(cfg, args, needs_llm=not args.script_file)
        jobs = build_jobs(cfg, args, pipeline, history)
    except FactoryError as exc:
        log.error("%s", exc)
        return 2

    done, failed = [], []
    for n, job in enumerate(jobs, 1):
        started = time.time()
        log.info("━━ Video %d/%d: %s ━━", n, len(jobs), job.topic or "(Skriptdatei)")
        try:
            out = pipeline.run(job)
        except FactoryError as exc:
            log.error("Video %d fehlgeschlagen: %s", n, exc)
            failed.append(job.topic)
            continue
        except KeyboardInterrupt:
            log.error("Abgebrochen.")
            return 130
        except Exception:  # unerwartet: Traceback ins Log, weiter mit dem nächsten Video
            log.exception("Unerwarteter Fehler bei Video %d – Details in %s", n, log_file)
            failed.append(job.topic)
            continue
        done.append(out)
        log.info("✔ %s (%.0f s)", out, time.time() - started)

    print()
    for out in done:
        print(f"Fertig: {out}")
    for topic in failed:
        print(f"Fehlgeschlagen: {topic}")
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
