"""Auftragswarteschlange der Desktop-App: ein Arbeiter-Thread, Fortschritt je Auftrag, Protokoll."""
from __future__ import annotations

import logging
import queue
import threading
import time
import uuid
from collections import deque
from collections.abc import Callable
from dataclasses import asdict, dataclass, field
from pathlib import Path

from .. import media
from ..config import Config
from ..errors import Cancelled, ConfigError, FactoryError
from ..history import History
from ..llm import LLM, api_key
from ..pipeline import Job, Options, Pipeline
from ..planner import niche_jobs, script_job, topic_job, trend_jobs
from ..progress import STAGES, Progress
from ..script import Script
from ..trends import refresh_trends
from ..tts import required_keys

log = logging.getLogger(__name__)

WAITING, RUNNING, DONE, FAILED, CANCELLED = "wartet", "laeuft", "fertig", "fehler", "abgebrochen"
MAX_COUNT = 10
_SCRIPT_STAGES = ("thema", "recherche", "skript", "abschluss")


@dataclass
class JobView:
    """Was die Oberfläche von einem Auftrag sieht."""
    id: str
    kind: str                       # video | skript | trends
    mode: str                       # niche | topic | trend | script | trends
    title: str
    niche: str = ""
    niche_name: str = ""
    status: str = WAITING
    stage: str = ""
    detail: str = ""
    percent: float = 0.0
    stages: list[dict] = field(default_factory=list)
    error: str = ""
    output: str | None = None
    created: float = field(default_factory=time.time)
    started: float | None = None
    finished: float | None = None


class _Batch:
    """Mehrere Aufträge teilen sich eine Themenplanung (ein Claude-Aufruf für alle)."""

    def __init__(self, loader: Callable[[], list[Job]]):
        self._loader = loader
        self._jobs: list[Job] | None = None
        self._error: FactoryError | None = None
        self._lock = threading.Lock()

    def get(self, index: int) -> Job:
        with self._lock:
            if self._jobs is None and self._error is None:
                try:
                    self._jobs = self._loader()
                except FactoryError as exc:
                    self._error = exc
            if self._error is not None:
                raise self._error
            if index >= len(self._jobs or []):
                raise ConfigError("Dafür wurde kein weiteres neues Thema gefunden.")
            return self._jobs[index]


@dataclass
class _Entry:
    view: JobView
    options: Options | None = None
    resolve: Callable[[], Job] | None = None
    action: Callable[[Progress], None] | None = None
    plans_topic: bool = False


def _stage_list(keys: tuple[str, ...] | None = None, skip: tuple[str, ...] = ()) -> list[dict]:
    return [{"key": k, "label": label, "weight": w, "state": "skipped" if k in skip else "pending"}
            for k, label, w in STAGES if keys is None or k in keys]


class _JobProgress(Progress):
    def __init__(self, manager: "JobManager", entry: _Entry):
        self.manager, self.view = manager, entry.view
        self._base = 0.0
        self._weight = 0.0

    def stage(self, key: str, detail: str = "") -> None:
        media.check_cancel()
        with self.manager._lock:
            stages = self.view.stages
            total = sum(s["weight"] for s in stages if s["state"] != "skipped") or 1
            done = 0.0
            for s in stages:
                if s["key"] == key:
                    s["state"] = "active"
                    self._weight = s["weight"] / total * 100
                    break
                if s["state"] in ("pending", "active"):
                    s["state"] = "done"
                if s["state"] == "done":
                    done += s["weight"]
            self._base = done / total * 100
            self.view.stage, self.view.detail = key, detail
            self.view.percent = max(self.view.percent, round(self._base, 1))
            self.manager._touch()

    def step(self, fraction: float, detail: str = "") -> None:
        media.check_cancel()
        with self.manager._lock:
            value = self._base + self._weight * max(0.0, min(1.0, fraction))
            self.view.percent = max(self.view.percent, round(value, 1))
            if detail:
                self.view.detail = detail
            self.manager._touch()


class _LogTap(logging.Handler):
    def __init__(self, manager: "JobManager"):
        super().__init__(logging.INFO)
        self.manager = manager

    def emit(self, record: logging.LogRecord) -> None:
        if record.name.split(".")[0] not in ("factory", "make", "app"):
            return
        try:
            self.manager.add_log(record.levelname, record.getMessage())
        except Exception:  # Protokollieren darf nie die Arbeit stören
            pass


class JobManager:
    def __init__(self, cfg: Config):
        self.cfg = cfg
        self._lock = threading.RLock()
        self._entries: dict[str, _Entry] = {}
        self._queue: queue.Queue[str] = queue.Queue()
        self._log: deque[dict] = deque(maxlen=1500)
        self._seq = 0
        self._rev = 0
        self._current: str | None = None
        self._tap = _LogTap(self)
        logging.getLogger().addHandler(self._tap)
        threading.Thread(target=self._work, daemon=True, name="factory-worker").start()

    # --- Protokoll / Zustand ------------------------------------------------------------
    def _touch(self) -> None:
        self._rev += 1

    def add_log(self, level: str, message: str) -> None:
        with self._lock:
            self._seq += 1
            self._log.append({"seq": self._seq, "t": time.time(), "level": level, "msg": message,
                              "job": self._current})

    def snapshot(self, since: int = 0) -> dict:
        with self._lock:
            return {
                "rev": self._rev,
                "seq": self._seq,
                "running": self._current,
                "jobs": [asdict(e.view) for e in self._entries.values()],
                "log": [line for line in self._log if line["seq"] > since][-400:],
            }

    def busy(self) -> bool:
        with self._lock:
            return any(e.view.status in (WAITING, RUNNING) for e in self._entries.values())

    # --- Aufträge annehmen ---------------------------------------------------------------
    def _preflight(self, options: Options, needs_llm: bool) -> None:
        if not options.script_only:
            media.check_ffmpeg()
        missing = []
        if needs_llm and not api_key(self.cfg):
            missing.append("ANTHROPIC_API_KEY")
        if not options.script_only:
            missing += required_keys(self.cfg, options.voice, options.voice_file)
        if missing:
            raise ConfigError(f"Es fehlen Schlüssel: {', '.join(missing)}. Trage sie unter „Einstellungen“ ein.")

    def _add(self, entry: _Entry) -> str:
        with self._lock:
            self._entries[entry.view.id] = entry
            for old in [k for k, e in self._entries.items()
                        if e.view.status in (DONE, FAILED, CANCELLED)][:-40]:
                del self._entries[old]  # Liste nicht endlos wachsen lassen
            self._touch()
        self._queue.put(entry.view.id)
        return entry.view.id

    def submit(self, req: dict, voice_file: Path | None = None) -> list[str]:
        """Nimmt eine Anfrage der Oberfläche an und stellt einen oder mehrere Aufträge ein."""
        cfg = self.cfg
        mode = req.get("mode")
        if mode not in ("niche", "topic", "trend", "script"):
            raise ConfigError("Unbekannter Modus.")
        lang = req.get("lang") if req.get("lang") in ("de", "en") else "de"
        count = max(1, min(MAX_COUNT, int(req.get("count") or 1)))
        script_only = bool(req.get("script_only")) and mode != "script"
        if voice_file is not None and mode != "script":
            raise ConfigError("Eine eigene Aufnahme passt nur zu einem eigenen Skript.")
        options = Options(
            voice=(req.get("voice") or None) if voice_file is None else None,
            voice_file=voice_file,
            music=bool(req.get("music", True)),
            whisper=bool(req.get("whisper", True)),
            script_only=script_only,
            keep_work=bool(req.get("keep_work")),
            web_search=cfg.env_bool("SCRIPT_WEB_SEARCH", True),
        )
        self._preflight(options, needs_llm=mode != "script")
        kind = "skript" if script_only else "video"
        stage_keys = _SCRIPT_STAGES if script_only else None

        def view(title: str, niche_key: str, skip: tuple[str, ...]) -> JobView:
            niche = cfg.niche(niche_key)
            return JobView(id=uuid.uuid4().hex[:10], kind=kind, mode=mode, title=title, niche=niche.key,
                           niche_name=niche.name, stages=_stage_list(stage_keys, skip))

        def history() -> History:
            return History(cfg.paths.data / "history.json")

        if mode == "script":
            script = Script.from_dict(req.get("script"))
            job = script_job(cfg, script, req.get("niche") or None, lang)
            entry = _Entry(view(script.titel, job.niche.key, ("thema", "recherche", "skript")), options,
                           resolve=lambda: job)
            return [self._add(entry)]

        if mode == "topic":
            topic = " ".join(str(req.get("topic") or "").split())
            if len(topic) < 4:
                raise ConfigError("Bitte ein Thema eingeben.")
            job = topic_job(cfg, history(), topic[:240], req.get("niche") or None, lang)
            return [self._add(_Entry(view(job.topic, job.niche.key, ("thema",)), options, resolve=lambda: job))]

        if mode == "trend":
            numbers = [int(n) for n in (req.get("trend_numbers") or [])][:MAX_COUNT]
            if numbers:
                jobs = trend_jobs(cfg, history(), lambda: LLM(cfg), len(numbers), lang, numbers=numbers)
                return [self._add(_Entry(view(j.topic, j.niche.key, ("thema",)), options, resolve=lambda j=j: j))
                        for j in jobs]
            batch = _Batch(lambda: trend_jobs(cfg, history(), lambda: LLM(cfg), count, lang))
            return [self._add(_Entry(view("Trend-Thema wird gewählt …", "trend", ()), options,
                                     resolve=lambda i=i: batch.get(i), plans_topic=True))
                    for i in range(count)]

        niche = cfg.niche(req.get("niche") or cfg.script.default_niche)
        if niche.key == "trend":
            raise ConfigError("Für Trends bitte den Reiter „Trend“ nutzen.")
        batch = _Batch(lambda: niche_jobs(cfg, history(), LLM(cfg), niche.key, count, lang))
        return [self._add(_Entry(view("Neues Thema wird gesucht …", niche.key, ()), options,
                                 resolve=lambda i=i: batch.get(i), plans_topic=True))
                for i in range(count)]

    def submit_trend_refresh(self) -> str:
        if not api_key(self.cfg):
            raise ConfigError("Für die Trend-Recherche fehlt ANTHROPIC_API_KEY (unter „Einstellungen“).")
        with self._lock:
            for e in self._entries.values():
                if e.view.kind == "trends" and e.view.status in (WAITING, RUNNING):
                    return e.view.id
        view = JobView(id=uuid.uuid4().hex[:10], kind="trends", mode="trends", title="Trends recherchieren",
                       niche="trend", niche_name="Aktuelle Trends Deutschland",
                       stages=[{"key": "thema", "label": "Trend-Recherche", "weight": 100, "state": "pending"}])

        def action(progress: Progress) -> None:
            progress.stage("thema", "Websuche: Google Trends, TikTok, Nachrichten der Woche")
            refresh_trends(LLM(self.cfg), self.cfg, self.cfg.paths.data / "trends.md")

        return self._add(_Entry(view, action=action))

    # --- Abbrechen / Aufräumen -------------------------------------------------------------
    def cancel(self, job_id: str | None = None) -> int:
        """Bricht einen Auftrag ab (ohne job_id: alle). Gibt die Anzahl zurück."""
        hit = 0
        with self._lock:
            for e in self._entries.values():
                if job_id not in (None, e.view.id):
                    continue
                if e.view.status == WAITING:
                    e.view.status, e.view.finished = CANCELLED, time.time()
                    hit += 1
                elif e.view.status == RUNNING:
                    media.request_cancel()
                    e.view.detail = "wird abgebrochen …"
                    hit += 1
            self._touch()
        return hit

    def clear_finished(self) -> None:
        with self._lock:
            for key in [k for k, e in self._entries.items() if e.view.status in (DONE, FAILED, CANCELLED)]:
                del self._entries[key]
            self._touch()

    # --- Arbeiter ---------------------------------------------------------------------------
    def _work(self) -> None:
        while True:
            entry = self._entries.get(self._queue.get())
            if entry is not None:
                self._execute(entry)

    def _execute(self, entry: _Entry) -> None:
        view = entry.view
        with self._lock:
            if view.status != WAITING:
                return
            media.clear_cancel()
            view.status, view.started, self._current = RUNNING, time.time(), view.id
            self._touch()
        progress = _JobProgress(self, entry)
        log.info("━━ %s ━━", view.title)
        try:
            if entry.action is not None:
                entry.action(progress)
            else:
                if entry.plans_topic:
                    progress.stage("thema", "Claude sucht ein neues Thema")
                job = entry.resolve()
                with self._lock:
                    view.title = job.topic or view.title
                    view.niche, view.niche_name = job.niche.key, job.niche.name
                    self._touch()
                history = History(self.cfg.paths.data / "history.json")
                out = Pipeline(self.cfg, history, entry.options, progress).run(job)
                view.output = out.name
            self._finish(view, DONE)
            log.info("✔ Fertig: %s", view.title)
        except Cancelled:
            self._finish(view, CANCELLED)
            log.warning("Abgebrochen: %s", view.title)
        except FactoryError as exc:
            log.error("%s", exc)
            self._finish(view, FAILED, str(exc))
        except Exception:  # unerwartet: vollständiger Traceback ins Protokoll
            log.exception("Unerwarteter Fehler bei „%s“", view.title)
            self._finish(view, FAILED, "Unerwarteter Fehler – Details stehen im Protokoll.")

    def _finish(self, view: JobView, status: str, error: str = "") -> None:
        with self._lock:
            for s in view.stages:
                if status == DONE and s["state"] in ("pending", "active"):
                    s["state"] = "done"
                elif status != DONE and s["state"] == "active":
                    s["state"] = "error" if status == FAILED else "pending"
            view.status, view.error, view.finished = status, error, time.time()
            if status == DONE:
                view.percent, view.detail = 100.0, ""
            self._current = None
            media.clear_cancel()
            self._touch()
