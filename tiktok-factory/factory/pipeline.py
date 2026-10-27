"""Ein Video von A bis Z: Skript → Stimme → Länge prüfen → Timing → B-Roll → Render → Texte."""
from __future__ import annotations

import json
import logging
import random
import shutil
from dataclasses import asdict, dataclass, field, replace
from datetime import date, datetime
from pathlib import Path

from . import media
from .broll import find_broll, plan_shots
from .config import Config, Niche
from .cover import make_cover
from .errors import ConfigError, ScriptError
from .history import History
from .llm import LLM, Research, api_key
from .render import build_audio, choose_music, extract_frame, final_render, render_shots, verify_video
from .script import (Script, check_sources, ensure_hashtags, research_topic, revise_for_duration, validate,
                     write_script)
from .subtitles import build_ass, scene_spans, word_timings
from .trends import TrendIdea, mark_produced
from .tts import VoiceProvider, get_voice
from .utils import slugify

log = logging.getLogger(__name__)

KI_HINWEIS = ("⚠ KI-Label beim Upload aktivieren: In TikTok unter „Weitere Optionen“ → "
              "„KI-generierte Inhalte“ einschalten.")


@dataclass
class Job:
    niche: Niche
    topic: str = ""
    angle: str = ""
    script: Script | None = None        # vorgegeben per --script-file
    trend: TrendIdea | None = None
    lang: str = "de"


@dataclass
class Options:
    voice: str | None = None
    voice_file: Path | None = None
    music: bool = True
    whisper: bool = True
    script_only: bool = False
    keep_work: bool = False
    web_search: bool = True
    notes: list[str] = field(default_factory=list)


class Pipeline:
    def __init__(self, cfg: Config, history: History, options: Options):
        self.cfg = cfg
        self.history = history
        self.opt = options
        self._llm: LLM | None = None

    @property
    def has_llm(self) -> bool:
        return bool(api_key(self.cfg))

    @property
    def llm(self) -> LLM:
        if self._llm is None:
            self._llm = LLM(self.cfg)
        return self._llm

    # ------------------------------------------------------------------------------
    def make_script(self, job: Job) -> tuple[Script, Research | None]:
        if job.script is not None:
            problems = validate(job.script, self.cfg, check_length=False)
            for p in problems:
                log.warning("Skriptdatei: %s", p)
            ensure_hashtags(job.script, job.niche)
            return job.script, None
        research = None
        if self.opt.web_search:
            log.info("Recherche per Websuche: %s", job.topic)
            research = research_topic(self.llm, self.cfg, job.topic, job.angle, job.niche)
        trend_note = ""
        if job.trend:
            trend_note = (f"Aktueller Anlass: {job.trend.warum_jetzt} (Quelle: {job.trend.quelle}, {job.trend.datum}). "
                          "Greife den Anlass im Hook oder im ersten Satz auf; der Kern sind zeitlose, "
                          "überprüfbare Fakten.")
        log.info("Skript schreiben: %s", job.topic)
        script = write_script(self.llm, self.cfg, topic=job.topic, angle=job.angle, niche=job.niche,
                              research=research, history=self.history, lang=job.lang, trend_note=trend_note)
        log.info("Skript: „%s“ – %d Wörter, %d Szenen", script.titel, script.word_count(), len(script.szenen))
        return script, research

    def _output_dir(self, slug: str) -> Path:
        base = self.cfg.paths.output / f"{date.today():%Y-%m-%d}_{slug}"
        out, n = base, 2
        while (out / "video.mp4").exists():
            out = base.with_name(f"{base.name}-{n}")
            n += 1
        out.mkdir(parents=True, exist_ok=True)
        return out

    def _voice(self, job: Job, script: Script, voice: VoiceProvider, research: Research | None,
               work: Path) -> tuple[Script, Path, float]:
        """Vertonen und Dauer erzwingen: <61 s verlängern, >90 s kürzen, dann neu vertonen."""
        d, pad = self.cfg.duration, self.cfg.video.end_padding
        rate = 0
        for round_no in range(d.max_rounds + 1):
            wav = voice.synthesize(script.narration, work, job.lang, rate)
            spoken = media.duration(wav)
            total = spoken + pad
            log.info("Vertonung: %.1f s (%d Wörter)", spoken, script.word_count())
            if d.min_hard <= total <= d.max_hard:
                if not 65 <= total <= 75:
                    log.info("Dauer %.1f s liegt außerhalb des Zielkorridors 65–75 s, aber innerhalb der Grenzen.", total)
                return script, wav, spoken
            if not voice.can_resynthesize:
                raise ScriptError(f"Die Aufnahme dauert {spoken:.1f} s – nötig sind {d.min_hard}–{d.max_hard} s "
                                  "(TikTok vergütet erst Videos über 1 Minute). Bitte Text anpassen und neu aufnehmen.")
            if round_no == d.max_rounds:
                break
            if self.has_llm:
                script = revise_for_duration(self.llm, self.cfg, script, research, spoken_seconds=total,
                                             lang=job.lang)
            else:  # eigenes Skript ohne API: nur das Sprechtempo anpassen
                new_rate = round(((1 + rate / 100) * total / d.target - 1) * 100)
                if abs(new_rate) > 15:
                    words = round(script.word_count() * d.target / total)
                    raise ScriptError(f"Skript ergibt {total:.1f} s – nötig sind {d.min_hard}–{d.max_hard} s. "
                                      f"Ohne Anthropic-Key ist nur ±15 % Tempo möglich; bitte auf etwa {words} "
                                      "Wörter anpassen.")
                rate = new_rate
                log.info("Sprechtempo wird um %+d %% angepasst", rate)
        raise ScriptError(f"Videolänge nach {d.max_rounds} Anpassungen noch {total:.1f} s – bitte Thema/Skript prüfen.")

    # ------------------------------------------------------------------------------
    def run(self, job: Job) -> Path:
        script, research = self.make_script(job)
        out_dir = self._output_dir(slugify(script.titel or job.topic))
        log.info("Ausgabe: %s", out_dir)
        try:
            if self.opt.script_only:
                return self._write_script_only(out_dir, script, research)
            return self._produce(job, script, research, out_dir)
        except BaseException:
            if out_dir.exists() and not any(out_dir.iterdir()):
                out_dir.rmdir()  # keinen leeren Ordner zurücklassen
            raise

    def _produce(self, job: Job, script: Script, research: Research | None, out_dir: Path) -> Path:
        cfg = self.cfg
        topic = job.topic or script.titel
        slug = slugify(script.titel or topic)
        work = cfg.paths.work / out_dir.name
        if work.exists():
            shutil.rmtree(work)
        work.mkdir(parents=True)

        voice = get_voice(cfg, job.niche, job.lang, self.opt.voice, self.opt.voice_file)
        script, wav, spoken = self._voice(job, script, voice, research, work)
        total = min(spoken + cfg.video.end_padding, cfg.duration.max_hard)

        display_words, timed_words, timing = word_timings(wav, script, cfg, job.lang, use_whisper=self.opt.whisper)
        spans = scene_spans(timed_words, total)
        shots = plan_shots(spans, script, job.niche, cfg)
        log.info("%d Szenen → %d Shots (Ø %.1f s)", len(spans), len(shots), total / len(shots))

        missing = find_broll(shots, cfg, job.niche, self.history.used_media_ids(cfg.broll.avoid_recent_videos))
        concat = render_shots(shots, work, cfg)

        rng = random.Random(slug)
        music = None
        if self.opt.music:
            music = choose_music(cfg, job.niche.musik_stimmung, self.history.recent_music(), rng)
        audio = build_audio(wav, music, total, work, cfg, rng)

        ass = work / "untertitel.ass"
        ass.write_text(build_ass(display_words, cfg, hook_text=script.hook_overlay or script.hook, total=total),
                       encoding="utf-8")
        video = final_render(concat, audio["datei"], ass, out_dir / "video.mp4", total, cfg)
        check = verify_video(video, cfg)
        log.info("Video fertig: %.1f s, %s MB", check["dauer_s"], check["groesse_mb"])

        frame = extract_frame(work / "shot_000.mp4", min(shots[0].duration * 0.5, 1.0), work / "cover_frame.jpg")
        make_cover(frame, script.titel, out_dir / "cover.jpg", cfg)
        (out_dir / "beschreibung.txt").write_text(self._description(script), encoding="utf-8")

        notes = list(self.opt.notes)
        if missing:
            notes.append(f"{len(missing)} von {len(shots)} Shots ohne passendes Bildmaterial (Farbfläche): "
                         f"Shots {', '.join(map(str, missing))}")
        source_check = check_sources(script, research.urls if research else None)
        notes += [f"Quelle nicht erreichbar ({s['status']}), bitte prüfen: {s['url']}"
                  for s in source_check if s["erreichbar"] is False]
        notes += [f"Quelle stammt nicht aus der Websuche, bitte prüfen: {s['url']}"
                  for s in source_check if s["erreichbar"] and s["in_recherche"] is False]
        if timing["methode"] != "faster-whisper":
            notes.append("Untertitel-Timing nur geschätzt (ohne faster-whisper)")
        meta = self._meta(job, script, research, voice, check, spoken, audio, timing, shots, source_check, notes)
        (out_dir / "meta.json").write_text(json.dumps(meta, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

        self.history.add({
            "datum": date.today().isoformat(),
            "ordner": out_dir.name,
            "nische": job.niche.key,
            "gruppe": "trend" if job.trend else job.niche.gruppe,
            "thema": topic,
            "titel": script.titel,
            "hook": script.hook,
            "dauer_s": check["dauer_s"],
            "musik": audio.get("musik"),
            "media_ids": [s.media.media_id for s in shots if s.media and s.media.media_id],
        })
        if job.trend:
            mark_produced(cfg.paths.data / "trends.md", job.trend, out_dir.name)
        for note in notes:
            log.warning("Hinweis: %s", note)
        if not self.opt.keep_work:
            shutil.rmtree(work, ignore_errors=True)
        return out_dir

    # ------------------------------------------------------------------------------
    @staticmethod
    def _description(script: Script) -> str:
        return (f"{script.beschreibung}\n\n{' '.join(script.hashtags)}\n\n---\n{KI_HINWEIS}\n")

    def _write_script_only(self, out_dir: Path, script: Script, research: Research | None) -> Path:
        (out_dir / "skript.json").write_text(json.dumps(script.to_dict(), ensure_ascii=False, indent=2) + "\n",
                                            encoding="utf-8")
        lines = [script.hook, ""] + [s.text for s in script.szenen]
        (out_dir / "sprechertext.txt").write_text(
            "\n".join(lines) + f"\n\n({script.word_count()} Wörter – Ziel: 65–75 Sekunden)\n", encoding="utf-8")
        if research:
            (out_dir / "recherche.md").write_text(research.text + "\n", encoding="utf-8")
        log.info("Nur Skript erzeugt. Aufnahme machen und dann:\n  python make.py --script-file %s "
                 "--voice-file aufnahme.mp3", out_dir / "skript.json")
        return out_dir

    def _meta(self, job, script, research, voice, check, spoken, audio, timing, shots, source_check, notes) -> dict:
        return {
            "erstellt": datetime.now().isoformat(timespec="seconds"),
            "nische": job.niche.key,
            "nische_name": job.niche.name,
            "gruppe": "trend" if job.trend else job.niche.gruppe,
            "thema": job.topic or script.titel,
            "winkel": job.angle,
            "titel": script.titel,
            "hook": script.hook,
            "hook_overlay": script.hook_overlay,
            "schluss_typ": script.schluss_typ,
            "sprache": job.lang,
            "woerter": script.word_count(),
            "dauer_s": check["dauer_s"],
            "gesprochen_s": round(spoken, 2),
            "video": check,
            "stimme": {"anbieter": voice.name, "stimme": voice.voice},
            "audio": {k: v for k, v in audio.items() if k != "datei"},
            "untertitel": timing,
            "quellen": [asdict(q) for q in script.quellen],
            "quellen_pruefung": source_check,
            "recherche_per_websuche": research is not None,
            "trend": asdict(job.trend) if job.trend else None,
            "clips": [{"shot": s.index, "start_s": round(s.start, 2), "ende_s": round(s.end, 2),
                       "szene": "hook" if s.scene < 0 else s.scene + 1, **(s.media.meta() if s.media else {})}
                      for s in shots],
            "hinweise": notes,
            "ki_label_aktivieren": True,
            "skript": script.to_dict(),
        }


def niche_for_trend(cfg: Config, idea: TrendIdea) -> Niche:
    """Stil der passenden Nische + Trend-Hashtags."""
    trend = cfg.niches.get("trend")
    try:
        style = cfg.niche(idea.nische)
    except ConfigError:
        style = trend
    if style is None:
        raise ConfigError("niches.yaml braucht die Nische 'trend'.")
    if trend is None or style.key == trend.key:
        return style
    extra = [t for t in trend.hashtags[:2] if t not in style.hashtags]
    return replace(style, hashtags=style.hashtags + extra)
