"""Lokaler Server der Desktop-App: liefert die Oberfläche aus und nimmt ihre Befehle entgegen.

Sicherheit: nur an 127.0.0.1 gebunden; die Startseite gibt es nur mit dem Sitzungs-Token, jede
API-Anfrage braucht es als Header, Medien als Query-Parameter. Schlüssel aus der .env werden nie
an die Oberfläche zurückgegeben – nur „gesetzt / nicht gesetzt“ und die letzten 4 Zeichen.
"""
from __future__ import annotations

import hmac
import json
import logging
import mimetypes
import os
import re
import secrets
import shutil
import subprocess
import sys
import threading
from dataclasses import asdict
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

import dotenv

from .. import __version__, media
from ..config import Config
from ..discover import add_niche, ideas_stale, load_ideas, remove_niche
from ..errors import ConfigError, FactoryError
from ..llm import DEFAULT_MODEL, LLM, api_key
from ..trends import is_stale, parse_trends
from ..utils import HttpError, http_request
from .jobs import JobManager

log = logging.getLogger(__name__)

MAX_JSON = 5 * 1024 * 1024
MAX_UPLOAD = 400 * 1024 * 1024
AUDIO_EXT = {".mp3", ".wav", ".m4a", ".aac", ".ogg", ".flac", ".webm"}
MEDIA_FILES = {"video.mp4": "video/mp4", "cover.jpg": "image/jpeg"}
_SAFE_NAME = re.compile(r"[\w.\-]+")

# Felder der .env, die die Oberfläche lesen/schreiben darf
SETTINGS: dict[str, dict] = {
    "ANTHROPIC_API_KEY": {"kind": "secret"},
    "ANTHROPIC_MODEL": {"kind": "text", "default": DEFAULT_MODEL},
    "ANTHROPIC_EFFORT": {"kind": "choice", "choices": ["low", "medium", "high"], "default": "medium"},
    "SCRIPT_WEB_SEARCH": {"kind": "bool", "default": "true"},
    "TTS_PROVIDER": {"kind": "choice", "choices": ["azure", "elevenlabs"], "default": "azure"},
    "AZURE_SPEECH_KEY": {"kind": "secret"},
    "AZURE_SPEECH_REGION": {"kind": "text", "default": "westeurope"},
    "AZURE_SPEECH_RATE": {"kind": "text", "default": "+5%"},
    "ELEVENLABS_API_KEY": {"kind": "secret"},
    "ELEVENLABS_VOICE_ID": {"kind": "text", "default": ""},
    "ELEVENLABS_MODEL": {"kind": "text", "default": "eleven_multilingual_v2"},
    "PEXELS_API_KEY": {"kind": "secret"},
}

AZURE_VOICES = {
    "de": [("de-DE-ConradNeural", "Conrad · männlich"), ("de-DE-KatjaNeural", "Katja · weiblich"),
           ("de-DE-KillianNeural", "Killian · männlich"), ("de-DE-AmalaNeural", "Amala · weiblich"),
           ("de-DE-FlorianMultilingualNeural", "Florian · männlich, mehrsprachig"),
           ("de-DE-SeraphinaMultilingualNeural", "Seraphina · weiblich, mehrsprachig"),
           ("de-DE-BerndNeural", "Bernd · männlich"), ("de-DE-LouisaNeural", "Louisa · weiblich")],
    "en": [("en-US-AndrewNeural", "Andrew · male"), ("en-US-AvaNeural", "Ava · female"),
           ("en-US-BrianNeural", "Brian · male"), ("en-US-EmmaNeural", "Emma · female"),
           ("en-US-GuyNeural", "Guy · male"), ("en-US-JennyNeural", "Jenny · female")],
}

DEFAULT_PREFS = {"theme": "dark", "glass": 60, "accent": "aurora", "motion": True, "on_top": False,
                 "transparent": True, "blur": True, "auto_refresh": True}


class ApiError(Exception):
    def __init__(self, message: str, status: int = 400):
        super().__init__(message)
        self.status = status


# --------------------------------------------------------------------------------------
# Daten für die Oberfläche
# --------------------------------------------------------------------------------------
def load_prefs(cfg: Config) -> dict:
    path = cfg.paths.data / "app.json"
    prefs = dict(DEFAULT_PREFS)
    if path.exists():
        try:
            stored = json.loads(path.read_text(encoding="utf-8"))
            prefs.update({k: v for k, v in stored.items() if k in DEFAULT_PREFS})
        except (OSError, json.JSONDecodeError):
            log.warning("data/app.json ist beschädigt – Standardwerte werden verwendet.")
    return prefs


def save_prefs(cfg: Config, values: dict) -> dict:
    prefs = load_prefs(cfg)
    for key, value in values.items():
        if key not in DEFAULT_PREFS:
            continue
        default = DEFAULT_PREFS[key]
        if isinstance(default, bool):
            prefs[key] = bool(value)
        elif isinstance(default, int):
            prefs[key] = max(0, min(100, int(value)))
        else:
            prefs[key] = str(value)[:40]
    path = cfg.paths.data / "app.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(prefs, indent=2) + "\n", encoding="utf-8")
    return prefs


def settings_view(cfg: Config) -> dict:
    out = {}
    for name, spec in SETTINGS.items():
        value = cfg.env(name)
        if name == "ANTHROPIC_API_KEY":
            value = api_key(cfg)
        if spec["kind"] == "secret":
            out[name] = {"kind": "secret", "set": bool(value), "hint": f"…{value[-4:]}" if value else ""}
        else:
            out[name] = {**spec, "value": value if value is not None else spec.get("default", "")}
    return out


def save_settings(cfg: Config, values: dict, clear: list[str]) -> dict:
    """Schreibt erlaubte Felder in die .env und übernimmt sie sofort in die laufende App."""
    env_file = cfg.paths.root / ".env"
    if not env_file.exists():
        example = cfg.paths.root / ".env.example"
        if example.exists():
            shutil.copyfile(example, env_file)
        else:
            env_file.touch()
    for name, raw in values.items():
        spec = SETTINGS.get(name)
        if spec is None:
            raise ApiError(f"Unbekannte Einstellung: {name}")
        value = str(raw).strip()
        if "\n" in value or "\r" in value or len(value) > 400:
            raise ApiError(f"Ungültiger Wert für {name}.")
        if spec["kind"] == "secret" and not value:
            continue  # leeres Feld = unverändert lassen
        if spec["kind"] == "choice" and value not in spec["choices"]:
            raise ApiError(f"{name}: erlaubt sind {', '.join(spec['choices'])}.")
        if spec["kind"] == "bool":
            value = "true" if value.lower() in ("1", "true", "yes", "ja", "on") else "false"
        dotenv.set_key(str(env_file), name, value, quote_mode="auto")
        os.environ[name] = value
    for name in clear:
        if name not in SETTINGS:
            raise ApiError(f"Unbekannte Einstellung: {name}")
        dotenv.unset_key(str(env_file), name)
        os.environ.pop(name, None)
    if os.name == "posix":
        os.chmod(env_file, 0o600)
    return settings_view(cfg)


def system_status(cfg: Config) -> dict:
    try:
        ffmpeg = {"ok": True, "text": media.check_ffmpeg().split(" Copyright")[0]}
    except ConfigError as exc:
        ffmpeg = {"ok": False, "text": str(exc)}
    provider = (cfg.env("TTS_PROVIDER", "azure") or "azure").lower()
    keys = {"anthropic": bool(api_key(cfg)), "azure": bool(cfg.env("AZURE_SPEECH_KEY")),
            "elevenlabs": bool(cfg.env("ELEVENLABS_API_KEY") and cfg.env("ELEVENLABS_VOICE_ID")),
            "pexels": bool(cfg.env("PEXELS_API_KEY"))}
    moods = sorted({n.musik_stimmung for n in cfg.niches.values()})
    music = {}
    for mood in moods:
        folder = cfg.paths.music / mood
        music[mood] = sum(1 for p in folder.iterdir() if p.suffix.lower() in AUDIO_EXT) if folder.is_dir() else 0
    whisper_dir = cfg.paths.cache / "whisper"
    return {
        "ffmpeg": ffmpeg,
        "keys": keys,
        "tts_provider": provider,
        "voice_ready": keys.get(provider, False),
        "music": music,
        "music_total": sum(music.values()),
        "whisper": {"model": cfg.whisper.model,
                    "cached": whisper_dir.is_dir() and any(whisper_dir.rglob("model.bin"))},
        "font": (cfg.paths.fonts / cfg.subtitles.font_file).exists(),
        "output": str(cfg.paths.output),
    }


def niches_view(cfg: Config) -> dict:
    return {
        "niches": [{"key": n.key, "gruppe": n.gruppe, "name": n.name, "tonalitaet": n.tonalitaet,
                    "stimme": n.stimme, "stimme_en": n.stimme_en, "musik_stimmung": n.musik_stimmung,
                    "themenfelder": n.themenfelder, "eigene": n.key in cfg.custom_niches}
                   for n in cfg.niches.values()],
        "niche_ideas": load_ideas(cfg),
    }


def check_service(cfg: Config, name: str) -> dict:
    """Echter, kostenloser Probeaufruf je Dienst – zeigt, ob der Schlüssel funktioniert."""
    def result(ok: bool, text: str) -> dict:
        return {"ok": ok, "text": text}

    try:
        if name == "anthropic":
            if not api_key(cfg):
                return result(False, "Kein Schlüssel eingetragen.")
            return result(True, f"Verbunden – Modell: {LLM(cfg).check()}")
        if name == "azure":
            key, region = cfg.env("AZURE_SPEECH_KEY"), cfg.env("AZURE_SPEECH_REGION", "westeurope")
            if not key:
                return result(False, "Kein Schlüssel eingetragen.")
            resp = http_request("GET", f"https://{region}.tts.speech.microsoft.com/cognitiveservices/voices/list",
                                headers={"Ocp-Apim-Subscription-Key": key}, retries=1, timeout=15)
            if resp.status_code == 200:
                german = sum(1 for v in resp.json() if str(v.get("Locale", "")).startswith("de-"))
                return result(True, f"Verbunden – {german} deutsche Stimmen in Region {region}")
            if resp.status_code in (401, 403):
                return result(False, f"Schlüssel ungültig oder Region „{region}“ falsch.")
            return result(False, f"Azure antwortet mit HTTP {resp.status_code}.")
        if name == "pexels":
            key = cfg.env("PEXELS_API_KEY")
            if not key:
                return result(False, "Kein Schlüssel eingetragen.")
            resp = http_request("GET", "https://api.pexels.com/videos/search", params={"query": "ocean", "per_page": 1},
                                headers={"Authorization": key}, retries=1, timeout=15)
            if resp.status_code == 200:
                return result(True, f"Verbunden – {resp.json().get('total_results', '?')} Clips zu „ocean“")
            return result(False, "Schlüssel ungültig." if resp.status_code == 401 else f"Pexels: HTTP {resp.status_code}")
        if name == "elevenlabs":
            key, voice = cfg.env("ELEVENLABS_API_KEY"), cfg.env("ELEVENLABS_VOICE_ID")
            if not key:
                return result(False, "Kein Schlüssel eingetragen.")
            url = f"https://api.elevenlabs.io/v1/voices/{voice}" if voice else "https://api.elevenlabs.io/v1/voices"
            resp = http_request("GET", url, headers={"xi-api-key": key}, retries=1, timeout=15)
            if resp.status_code == 200:
                label = resp.json().get("name") if voice else "Schlüssel gültig, aber noch keine Voice-ID eingetragen"
                return result(bool(voice), f"Verbunden – Stimme: {label}" if voice else label)
            return result(False, "Schlüssel ungültig." if resp.status_code == 401 else
                          "Voice-ID nicht gefunden." if resp.status_code in (400, 404) else f"HTTP {resp.status_code}")
    except HttpError as exc:
        return result(False, f"Dienst nicht erreichbar: {exc}")
    except FactoryError as exc:
        return result(False, str(exc))
    raise ApiError("Unbekannter Dienst.")


def trends_view(cfg: Config) -> dict:
    path = cfg.paths.data / "trends.md"
    researched, ideas = parse_trends(path)
    items = []
    for idea in ideas:
        name, _, url = idea.quelle.partition(" – ")
        item = asdict(idea)
        item.update({"quelle_name": name.strip(), "quelle_url": url.strip() if url.startswith("http") else "",
                     "offen": idea.is_open,
                     "nische_name": cfg.niches[idea.nische].name if idea.nische in cfg.niches else idea.nische})
        items.append(item)
    return {"recherchiert": researched.isoformat(timespec="minutes") if researched else None,
            "veraltet": is_stale(path, cfg.trends.max_age_hours), "max_alter_h": cfg.trends.max_age_hours,
            "ideen": items}


def _read_json(path: Path) -> dict | None:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else None
    except (OSError, json.JSONDecodeError):
        return None


def library_list(cfg: Config, limit: int = 150) -> list[dict]:
    if not cfg.paths.output.is_dir():
        return []
    folders = sorted((p for p in cfg.paths.output.iterdir() if p.is_dir()),
                     key=lambda p: p.stat().st_mtime, reverse=True)
    items = []
    for folder in folders:
        meta = _read_json(folder / "meta.json")
        if meta and (folder / "video.mp4").exists():
            items.append({"folder": folder.name, "kind": "video", "titel": meta.get("titel") or folder.name,
                          "thema": meta.get("thema", ""), "nische": meta.get("nische", ""),
                          "nische_name": meta.get("nische_name", ""), "dauer_s": meta.get("dauer_s"),
                          "erstellt": meta.get("erstellt"), "hook": meta.get("hook", ""),
                          "hinweise": len(meta.get("hinweise") or []), "cover": (folder / "cover.jpg").exists()})
        elif (script := _read_json(folder / "skript.json")) is not None:
            items.append({"folder": folder.name, "kind": "skript", "titel": script.get("titel") or folder.name,
                          "thema": "", "nische": "", "nische_name": "", "dauer_s": None, "erstellt": None,
                          "hook": script.get("hook", ""), "hinweise": 0, "cover": False})
        if len(items) >= limit:
            break
    return items


def library_item(cfg: Config, folder_name: str) -> dict:
    folder = _output_folder(cfg, folder_name)
    meta = _read_json(folder / "meta.json")
    if meta:
        text = (folder / "beschreibung.txt")
        return {"folder": folder.name, "kind": "video", "meta": meta,
                "beschreibung": text.read_text(encoding="utf-8") if text.exists() else ""}
    script = _read_json(folder / "skript.json")
    if script is None:
        raise ApiError("In diesem Ordner liegt kein Video und kein Skript.", 404)
    text = folder / "sprechertext.txt"
    return {"folder": folder.name, "kind": "skript", "skript": script,
            "sprechertext": text.read_text(encoding="utf-8") if text.exists() else ""}


def _output_folder(cfg: Config, name: str) -> Path:
    if not _SAFE_NAME.fullmatch(name or "") or name in (".", ".."):
        raise ApiError("Ungültiger Ordnername.", 400)
    folder = cfg.paths.output / name
    if not folder.is_dir():
        raise ApiError("Ordner nicht gefunden.", 404)
    return folder


def open_in_file_manager(path: Path) -> None:
    if sys.platform == "win32":
        os.startfile(str(path))  # noqa: S606 – Pfad ist ein geprüfter Ausgabeordner
    elif sys.platform == "darwin":
        subprocess.Popen(["open", str(path)])
    else:
        subprocess.Popen(["xdg-open", str(path)])


# --------------------------------------------------------------------------------------
# Server
# --------------------------------------------------------------------------------------
class AppServer:
    def __init__(self, cfg: Config, *, port: int = 0, shell: dict | None = None):
        self.cfg = cfg
        self.token = secrets.token_urlsafe(24)
        self.shell = shell or {"mode": "browser", "platform": sys.platform, "backdrop": "opaque"}
        self.jobs = JobManager(cfg)
        self.uploads: dict[str, Path] = {}
        self._stopped = threading.Event()
        self.ui_dir = cfg.paths.root / "ui"
        self.httpd = ThreadingHTTPServer(("127.0.0.1", port), _handler(self))
        self.httpd.daemon_threads = True
        self.port = self.httpd.server_address[1]

    @property
    def url(self) -> str:
        return f"http://127.0.0.1:{self.port}/?t={self.token}"

    def start(self) -> None:
        threading.Thread(target=self.httpd.serve_forever, daemon=True, name="factory-http").start()
        threading.Thread(target=self._auto_loop, daemon=True, name="factory-auto").start()
        log.debug("App-Server läuft auf Port %d", self.port)

    def auto_refresh(self) -> list[str]:
        """Veraltete Trends und Nischen-Vorschläge von selbst neu recherchieren (abschaltbar)."""
        cfg = self.cfg
        if not load_prefs(cfg).get("auto_refresh", True) or not api_key(cfg) or self.jobs.busy():
            return []
        started = []
        if is_stale(cfg.paths.data / "trends.md", cfg.trends.max_age_hours):
            started.append(self.jobs.submit_trend_refresh())
        if ideas_stale(cfg):
            started.append(self.jobs.submit_niche_discovery())
        if started:
            log.info("Automatische Aktualisierung: Trends/Nischen werden neu recherchiert")
        return started

    def _auto_loop(self) -> None:
        delay = 4.0
        while not self._stopped.wait(delay):
            try:
                self.auto_refresh()
            except FactoryError as exc:
                log.warning("Automatische Aktualisierung: %s", exc)
            delay = 1800.0   # danach alle 30 Minuten prüfen, solange die App offen ist

    def stop(self) -> None:
        self._stopped.set()
        self.jobs.cancel()
        self.httpd.shutdown()
        self.httpd.server_close()

    # --- API ------------------------------------------------------------------------------
    def bootstrap(self) -> dict:
        cfg = self.cfg
        return {
            "version": __version__,
            "shell": self.shell,
            **niches_view(cfg),
            "default_niche": cfg.script.default_niche,
            "voices": {lang: [{"id": v, "label": label} for v, label in voices]
                       for lang, voices in AZURE_VOICES.items()},
            "limits": {"min_s": cfg.duration.min_hard, "max_s": cfg.duration.max_hard,
                       "min_words": cfg.script.min_words, "max_words": cfg.script.max_words},
            "prefs": load_prefs(cfg),
            "settings": settings_view(cfg),
            "system": system_status(cfg),
            "trends": trends_view(cfg),
            "library": library_list(cfg),
            "state": self.jobs.snapshot(),
        }

    def api(self, method: str, path: str, query: dict, body: dict) -> dict:
        cfg, jobs = self.cfg, self.jobs
        route = (method, path)
        if route == ("GET", "/api/bootstrap"):
            return self.bootstrap()
        if route == ("GET", "/api/state"):
            return jobs.snapshot(int(query.get("since", ["0"])[0] or 0))
        if route == ("POST", "/api/jobs"):
            voice = None
            if body.get("voice_upload"):
                voice = self.uploads.get(str(body["voice_upload"]))
                if voice is None or not voice.exists():
                    raise ApiError("Die hochgeladene Aufnahme wurde nicht gefunden – bitte erneut auswählen.")
            return {"ids": jobs.submit(body, voice)}
        if route == ("POST", "/api/jobs/cancel"):
            return {"cancelled": jobs.cancel(body.get("id") or None)}
        if route == ("POST", "/api/jobs/clear"):
            jobs.clear_finished()
            return {"ok": True}
        if route == ("GET", "/api/trends"):
            return trends_view(cfg)
        if route == ("POST", "/api/trends/refresh"):
            return {"id": jobs.submit_trend_refresh()}
        if route == ("GET", "/api/niches"):
            return niches_view(cfg)
        if route == ("POST", "/api/niches/discover"):
            return {"id": jobs.submit_niche_discovery()}
        if route == ("POST", "/api/niches/add"):
            add_niche(cfg, str(body.get("key", "")))
            return niches_view(cfg)
        if route == ("POST", "/api/niches/remove"):
            remove_niche(cfg, str(body.get("key", "")))
            return niches_view(cfg)
        if route == ("POST", "/api/check"):
            return check_service(cfg, str(body.get("service", "")))
        if route == ("GET", "/api/library"):
            return {"items": library_list(cfg)}
        if route == ("GET", "/api/library/item"):
            return library_item(cfg, query.get("folder", [""])[0])
        if route == ("GET", "/api/settings"):
            return {"settings": settings_view(cfg), "system": system_status(cfg)}
        if route == ("POST", "/api/settings"):
            settings = save_settings(cfg, dict(body.get("values") or {}), list(body.get("clear") or []))
            return {"settings": settings, "system": system_status(cfg)}
        if route == ("GET", "/api/system"):
            return system_status(cfg)
        if route == ("POST", "/api/prefs"):
            return {"prefs": save_prefs(cfg, body)}
        if route == ("POST", "/api/open"):
            folder = _output_folder(cfg, str(body.get("folder", ""))) if body.get("folder") else cfg.paths.output
            folder.mkdir(parents=True, exist_ok=True)
            open_in_file_manager(folder)
            return {"ok": True}
        raise ApiError("Unbekannte Adresse.", 404)

    def save_upload(self, name: str, stream, length: int) -> dict:
        ext = Path(name).suffix.lower()
        if ext not in AUDIO_EXT:
            raise ApiError(f"Dateityp {ext or '?'} wird nicht unterstützt (erlaubt: mp3, wav, m4a, ogg, flac).")
        if length <= 0 or length > MAX_UPLOAD:
            raise ApiError("Die Datei ist leer oder zu groß (max. 400 MB).")
        folder = self.cfg.paths.work / "uploads"
        folder.mkdir(parents=True, exist_ok=True)
        upload_id = secrets.token_hex(8)
        target = folder / f"{upload_id}{ext}"
        remaining = length
        with open(target, "wb") as fh:
            while remaining > 0:
                chunk = stream.read(min(1 << 20, remaining))
                if not chunk:
                    break
                fh.write(chunk)
                remaining -= len(chunk)
        if remaining:
            target.unlink(missing_ok=True)
            raise ApiError("Upload unvollständig – bitte erneut versuchen.")
        self.uploads[upload_id] = target
        seconds = None
        try:
            seconds = round(media.duration(target), 1)
        except FactoryError:
            target.unlink(missing_ok=True)
            del self.uploads[upload_id]
            raise ApiError("Die Datei ist keine lesbare Audiodatei.") from None
        return {"id": upload_id, "name": Path(name).name[:80], "dauer_s": seconds}


def _handler(app: AppServer) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        server_version = "TikTokFactory"

        def log_message(self, fmt, *args):  # Zugriffe nicht auf die Konsole schreiben
            log.debug("http %s", fmt % args)

        # --- Antworten ----------------------------------------------------------------------
        def _send(self, status: int, body: bytes, content_type: str, headers: dict | None = None) -> None:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            for key, value in (headers or {}).items():
                self.send_header(key, value)
            self.end_headers()
            self.wfile.write(body)

        def _json(self, data: dict, status: int = 200) -> None:
            self._send(status, json.dumps(data, ensure_ascii=False).encode("utf-8"), "application/json; charset=utf-8")

        def _text(self, status: int, text: str) -> None:
            self._send(status, text.encode("utf-8"), "text/plain; charset=utf-8")

        def _file(self, path: Path, content_type: str) -> None:
            size = path.stat().st_size
            start, end, status = 0, size - 1, 200
            match = re.fullmatch(r"bytes=(\d*)-(\d*)", (self.headers.get("Range") or "").strip())
            if match and (match.group(1) or match.group(2)):
                if match.group(1):
                    start = int(match.group(1))
                    end = min(int(match.group(2)), size - 1) if match.group(2) else size - 1
                else:
                    start = max(0, size - int(match.group(2)))
                if start > end or start >= size:
                    self._send(416, b"", content_type, {"Content-Range": f"bytes */{size}"})
                    return
                status = 206
            length = end - start + 1
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(length))
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Cache-Control", "no-store")
            if status == 206:
                self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            self.end_headers()
            try:
                with open(path, "rb") as fh:
                    fh.seek(start)
                    while length > 0:
                        chunk = fh.read(min(1 << 16, length))
                        if not chunk:
                            break
                        self.wfile.write(chunk)
                        length -= len(chunk)
            except (BrokenPipeError, ConnectionResetError):
                self.close_connection = True  # der Player springt – völlig normal

        # --- Prüfungen -----------------------------------------------------------------------
        def _host_ok(self) -> bool:
            host = (self.headers.get("Host") or "").lower()
            return host in (f"127.0.0.1:{app.port}", f"localhost:{app.port}")

        def _token_ok(self, value: str | None) -> bool:
            return bool(value) and hmac.compare_digest(value, app.token)

        # --- Routen ---------------------------------------------------------------------------
        def do_GET(self):  # noqa: N802
            self._handle("GET")

        def do_POST(self):  # noqa: N802
            self._handle("POST")

        def _handle(self, method: str) -> None:
            try:
                if not self._host_ok():
                    return self._text(403, "Ungültiger Host.")
                url = urlsplit(self.path)
                query = parse_qs(url.query)
                path = url.path
                if method == "GET" and path in ("/", "/index.html"):
                    return self._index(query)
                if method == "GET" and path.startswith("/ui/"):
                    return self._static(app.ui_dir, path[4:])
                if method == "GET" and path.startswith("/fonts/"):
                    return self._static(app.cfg.paths.fonts, path[7:], only=(".ttf", ".otf", ".woff2"))
                if method == "GET" and path.startswith("/media/"):
                    if not self._token_ok(query.get("t", [None])[0]):
                        return self._text(403, "Kein Zugriff.")
                    return self._media(path[7:])
                if path.startswith("/api/"):
                    if not self._token_ok(self.headers.get("X-Factory-Token")):
                        return self._json({"error": "Sitzung ungültig – bitte die App neu starten."}, 403)
                    if method == "POST" and path == "/api/upload":
                        name = query.get("name", ["aufnahme"])[0]
                        length = int(self.headers.get("Content-Length") or 0)
                        return self._json(app.save_upload(name, self.rfile, length))
                    body = self._body() if method == "POST" else {}
                    return self._json(app.api(method, path, query, body))
                self._text(404, "Nicht gefunden.")
            except ApiError as exc:
                self._json({"error": str(exc)}, exc.status)
            except FactoryError as exc:
                self._json({"error": str(exc)}, 400)
            except (BrokenPipeError, ConnectionResetError):
                self.close_connection = True
            except Exception:  # unerwartet: ins Protokoll, der Oberfläche eine ruhige Meldung
                log.exception("Fehler in der App-Anfrage %s %s", method, self.path.split("?")[0])
                try:
                    self._json({"error": "Interner Fehler – Details stehen im Protokoll."}, 500)
                except OSError:
                    pass

        def _body(self) -> dict:
            length = int(self.headers.get("Content-Length") or 0)
            if length > MAX_JSON:
                raise ApiError("Anfrage zu groß.", 413)
            raw = self.rfile.read(length) if length else b"{}"
            try:
                data = json.loads(raw.decode("utf-8") or "{}")
            except (UnicodeDecodeError, json.JSONDecodeError):
                raise ApiError("Ungültiges JSON.") from None
            if not isinstance(data, dict):
                raise ApiError("Ungültige Anfrage.")
            return data

        def _index(self, query: dict) -> None:
            if not self._token_ok(query.get("t", [None])[0]):
                return self._text(403, "TikTok Factory: Bitte über die App öffnen (python app.py).")
            html = (app.ui_dir / "index.html").read_text(encoding="utf-8")
            boot = json.dumps({"token": app.token, "shell": app.shell}).replace("<", "\\u003c")
            html = html.replace("__BOOT__", boot)
            self._send(200, html.encode("utf-8"), "text/html; charset=utf-8", {
                "Content-Security-Policy": "default-src 'self' 'unsafe-inline' 'unsafe-eval' data: blob:; "
                                           "connect-src 'self'; frame-ancestors 'none'",
                "Referrer-Policy": "no-referrer",
            })

        def _static(self, root: Path, rel: str, only: tuple[str, ...] | None = None) -> None:
            target = (root / rel).resolve()
            if root.resolve() not in target.parents or not target.is_file():
                return self._text(404, "Nicht gefunden.")
            if only and target.suffix.lower() not in only:
                return self._text(404, "Nicht gefunden.")
            ctype = {".js": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8",
                     ".svg": "image/svg+xml", ".html": "text/html; charset=utf-8", ".ttf": "font/ttf",
                     ".json": "application/json"}.get(target.suffix.lower())
            ctype = ctype or mimetypes.guess_type(target.name)[0] or "application/octet-stream"
            self._send(200, target.read_bytes(), ctype)

        def _media(self, rel: str) -> None:
            folder_name, _, file_name = rel.partition("/")
            if file_name not in MEDIA_FILES:
                return self._text(404, "Nicht gefunden.")
            path = _output_folder(app.cfg, folder_name) / file_name
            if not path.is_file():
                return self._text(404, "Nicht gefunden.")
            self._file(path, MEDIA_FILES[file_name])

    return Handler
