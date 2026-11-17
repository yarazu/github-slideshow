"""B-Roll: Shots planen (Bildwechsel alle 2–4 s) und passendes Material finden.

Reihenfolge je Shot: eigene Clips (assets/broll) -> Pexels-Video hochkant -> Pexels-Video quer
(wird auf 9:16 zugeschnitten) -> Pexels-Foto (Ken-Burns-Zoom) -> Stil-Stichworte der Nische ->
animierte Farbfläche als letzte Rückfallebene.
"""
from __future__ import annotations

import hashlib
import json
import logging
import re
import time
from collections.abc import Callable
from dataclasses import asdict, dataclass
from pathlib import Path

from . import media
from .config import Config, Niche
from .errors import BrollError, FactoryError
from .script import Script
from .utils import HttpError, download, http_request

log = logging.getLogger(__name__)

VIDEO_EXT = {".mp4", ".mov", ".m4v", ".webm"}
PHOTO_EXT = {".jpg", ".jpeg", ".png", ".webp"}


@dataclass
class MediaAsset:
    kind: str                     # video | photo | color
    source: str                   # pexels | lokal | generiert
    path: Path | None = None
    media_id: str | None = None
    page_url: str | None = None
    author: str | None = None
    author_url: str | None = None
    query: str | None = None
    duration: float | None = None
    width: int | None = None
    height: int | None = None

    def meta(self) -> dict:
        data = asdict(self)
        data["path"] = self.path.name if self.path else None
        return {k: v for k, v in data.items() if v is not None}


@dataclass
class Shot:
    index: int
    start: float
    end: float
    scene: int
    terms: list[str]
    frames: int = 0
    media: MediaAsset | None = None

    @property
    def duration(self) -> float:
        return self.end - self.start


# --------------------------------------------------------------------------------------
# Shot-Planung
# --------------------------------------------------------------------------------------
def scene_terms(script: Script, niche: Niche, scene: int) -> list[str]:
    if scene < 0:
        terms = script.hook_pexels_suchbegriffe or (script.szenen[0].pexels_suchbegriffe if script.szenen else [])
    else:
        terms = script.szenen[scene].pexels_suchbegriffe
    return [t.strip() for t in terms if t.strip()] or list(niche.pexels_stil)


def plan_shots(spans: list[tuple[int, float, float]], script: Script, niche: Niche, cfg: Config) -> list[Shot]:
    """Zerlegt die Szenen-Zeitfenster in Shots von shot_min–shot_max Sekunden."""
    v = cfg.video
    segments: list[dict] = []
    for scene, start, end in spans:
        terms = scene_terms(script, niche, scene)
        if segments and segments[-1]["end"] - segments[-1]["start"] < v.shot_min:
            seg = segments[-1]  # zu kurze Szene mit der nächsten zusammenlegen
            seg["end"] = end
            seg["terms"] += [t for t in terms if t not in seg["terms"]]
        else:
            segments.append({"scene": scene, "start": start, "end": end, "terms": list(terms)})
    if len(segments) > 1 and segments[-1]["end"] - segments[-1]["start"] < v.shot_min:
        last = segments.pop()
        segments[-1]["end"] = last["end"]
        segments[-1]["terms"] += [t for t in last["terms"] if t not in segments[-1]["terms"]]

    shots: list[Shot] = []
    for seg in segments:
        dur = seg["end"] - seg["start"]
        n = max(1, round(dur / v.shot_target))
        while dur / n > v.shot_max:
            n += 1
        while n > 1 and dur / n < v.shot_min:
            n -= 1
        terms = seg["terms"]
        for k in range(n):
            rotated = terms[k % len(terms):] + terms[:k % len(terms)] if terms else []
            shots.append(Shot(index=len(shots), start=seg["start"] + dur * k / n,
                              end=seg["start"] + dur * (k + 1) / n, scene=seg["scene"], terms=rotated))
    for shot in shots:  # Frame-genau, ohne Rundungsdrift
        shot.frames = round(shot.end * v.fps) - round(shot.start * v.fps)
    return shots


# --------------------------------------------------------------------------------------
# Quellen
# --------------------------------------------------------------------------------------
def pick_video_file(video: dict, width: int, height: int) -> dict | None:
    """Kleinste MP4-Datei, die 9:16 ohne Hochskalieren füllt – sonst die größte verfügbare."""
    files = [f for f in video.get("video_files", [])
             if f.get("file_type") == "video/mp4" and f.get("width") and f.get("height") and f.get("link")]
    if not files:
        return None
    covering = [f for f in files if max(width / f["width"], height / f["height"]) <= 1.0]
    if covering:
        return min(covering, key=lambda f: f["width"] * f["height"])
    return max(files, key=lambda f: f["width"] * f["height"])


class PexelsClient:
    API = "https://api.pexels.com"
    name = "pexels"

    def __init__(self, key: str, cache_dir: Path, per_page: int = 15, cache_days: float = 7):
        self.key = key
        self.cache_dir = cache_dir
        self.per_page = per_page
        self.cache_seconds = cache_days * 86400

    def _get(self, path: str, params: dict) -> dict:
        ident = hashlib.sha1(json.dumps([path, sorted(params.items())]).encode()).hexdigest()[:16]
        cache_file = self.cache_dir / "search" / f"{ident}.json"
        if cache_file.exists() and time.time() - cache_file.stat().st_mtime < self.cache_seconds:
            return json.loads(cache_file.read_text(encoding="utf-8"))
        try:
            resp = http_request("GET", f"{self.API}{path}", params=params, headers={"Authorization": self.key},
                                timeout=20)
        except HttpError as exc:
            raise BrollError(f"Pexels nicht erreichbar: {exc}") from exc
        if resp.status_code == 401:
            raise BrollError("Pexels-API-Key ungültig (PEXELS_API_KEY).")
        if resp.status_code == 429:
            raise BrollError("Pexels-Limit erreicht (200 Anfragen/Stunde) – bitte später erneut starten.")
        if resp.status_code != 200:
            raise BrollError(f"Pexels: HTTP {resp.status_code} {resp.text[:200]}")
        data = resp.json()
        cache_file.parent.mkdir(parents=True, exist_ok=True)
        cache_file.write_text(json.dumps(data), encoding="utf-8")
        return data

    def search_videos(self, query: str, orientation: str | None) -> list[dict]:
        params = {"query": query, "per_page": self.per_page, "size": "medium"}
        if orientation:
            params["orientation"] = orientation
        return self._get("/videos/search", params).get("videos", [])

    def search_photos(self, query: str) -> list[dict]:
        params = {"query": query, "per_page": self.per_page, "orientation": "portrait", "size": "large"}
        return self._get("/v1/search", params).get("photos", [])

    def download_video(self, video: dict, file: dict) -> Path:
        return download(file["link"], self.cache_dir / "videos" / f"{video['id']}_{file.get('id', 'x')}.mp4")

    def download_photo(self, photo: dict, width: int, height: int) -> Path:
        # 9:16-Ausschnitt in doppelter Auflösung (für ruckelfreien Ken-Burns-Zoom)
        url = f"{photo['src']['original']}?auto=compress&cs=tinysrgb&fit=crop&w={width}&h={height}"
        return download(url, self.cache_dir / "photos" / f"{photo['id']}_{width}x{height}.jpg")


class PixabayClient:
    """Pixabay (Pixabay Content License: kommerziell nutzbar, keine Namensnennung nötig).

    Liefert Treffer im selben Format wie PexelsClient, damit die Auswahl-Logik für beide gilt.
    Kostenloser Schlüssel: pixabay.com/api/docs (nach Anmeldung steht er direkt auf der Seite).
    """
    API = "https://pixabay.com/api"
    name = "pixabay"

    def __init__(self, key: str, cache_dir: Path, per_page: int = 15, cache_days: float = 7):
        self.key = key
        self.cache_dir = cache_dir
        self.per_page = max(3, min(200, per_page))
        self.cache_seconds = max(1.0, cache_days) * 86400   # Pixabay verlangt mind. 24 h Cache

    def _get(self, path: str, params: dict) -> dict:
        params = {**params, "safesearch": "true", "per_page": self.per_page}
        ident = hashlib.sha1(json.dumps([path, sorted(params.items())]).encode()).hexdigest()[:16]
        cache_file = self.cache_dir / "search" / f"{ident}.json"
        if cache_file.exists() and time.time() - cache_file.stat().st_mtime < self.cache_seconds:
            return json.loads(cache_file.read_text(encoding="utf-8"))
        try:
            resp = http_request("GET", f"{self.API}{path}", params={**params, "key": self.key}, timeout=20)
        except HttpError as exc:
            raise BrollError(f"Pixabay nicht erreichbar: {exc}") from exc
        if resp.status_code in (400, 401, 403) and "key" in resp.text.lower():
            raise BrollError("Pixabay-API-Key ungültig (PIXABAY_API_KEY).")
        if resp.status_code == 429:
            raise BrollError("Pixabay-Limit erreicht (100 Anfragen/Minute) – kurz warten und erneut starten.")
        if resp.status_code != 200:
            raise BrollError(f"Pixabay: HTTP {resp.status_code} {resp.text[:200]}")
        data = resp.json()
        cache_file.parent.mkdir(parents=True, exist_ok=True)
        cache_file.write_text(json.dumps(data), encoding="utf-8")
        return data

    @staticmethod
    def _user(hit: dict) -> dict:
        name, uid = hit.get("user") or "", hit.get("user_id")
        return {"name": name, "url": f"https://pixabay.com/users/{name}-{uid}/" if name and uid else None}

    def search_videos(self, query: str, orientation: str | None) -> list[dict]:
        hits = self._get("/videos/", {"q": query[:100], "video_type": "film"}).get("hits", [])
        out = []
        for hit in hits:
            files = [{"id": size, "file_type": "video/mp4", "width": v.get("width"), "height": v.get("height"),
                      "link": v.get("url")}
                     for size, v in (hit.get("videos") or {}).items() if isinstance(v, dict) and v.get("url")]
            video = {"id": hit["id"], "url": hit.get("pageURL"), "duration": hit.get("duration") or 0,
                     "user": self._user(hit), "video_files": files}
            portrait = any((f["height"] or 0) > (f["width"] or 0) for f in files)
            if orientation == "portrait" and not portrait:
                continue   # die API kennt keinen Hochkant-Filter – hier nachholen
            out.append(video)
        return out

    def search_photos(self, query: str) -> list[dict]:
        hits = self._get("/", {"q": query[:100], "image_type": "photo", "orientation": "vertical"}).get("hits", [])
        return [{"id": h["id"], "url": h.get("pageURL"), "photographer": self._user(h)["name"],
                 "photographer_url": self._user(h)["url"], "src": {"original": h.get("largeImageURL")}}
                for h in hits if h.get("largeImageURL")]

    def download_video(self, video: dict, file: dict) -> Path:
        return download(file["link"], self.cache_dir / "videos" / f"{video['id']}_{file.get('id', 'x')}.mp4")

    def download_photo(self, photo: dict, width: int, height: int) -> Path:
        return download(photo["src"]["original"], self.cache_dir / "photos" / f"{photo['id']}.jpg")


class LocalLibrary:
    """Eigene Clips/Fotos in assets/broll/ – Dateiname = Stichworte (z. B. gehirn_brain_scan.mp4)."""

    def __init__(self, folder: Path):
        self.items: list[tuple[Path, set[str]]] = []
        if folder.is_dir():
            for path in sorted(folder.rglob("*")):
                if path.suffix.lower() in VIDEO_EXT | PHOTO_EXT:
                    self.items.append((path, _tokens(path.stem)))
        self._durations: dict[Path, float] = {}

    def find(self, term: str, used: set[str], need: float) -> MediaAsset | None:
        wanted = _tokens(term)
        best, best_score = None, 0
        for path, tokens in self.items:
            media_id = f"lokal:{path.name}"
            score = len(wanted & tokens)
            if score > best_score and media_id not in used:
                best, best_score = path, score
        if best is None:
            return None
        if best.suffix.lower() in PHOTO_EXT:
            return MediaAsset("photo", "lokal", best, f"lokal:{best.name}", query=term)
        if best not in self._durations:
            self._durations[best] = media.duration(best)
        return MediaAsset("video", "lokal", best, f"lokal:{best.name}", query=term, duration=self._durations[best])


def _tokens(text: str) -> set[str]:
    return {t for t in re.split(r"[^a-z0-9äöüß]+", text.lower()) if len(t) >= 3}


# --------------------------------------------------------------------------------------
# Zuweisung
# --------------------------------------------------------------------------------------
class BrollFinder:
    def __init__(self, cfg: Config, niche: Niche, recent_ids: set[str]):
        self.cfg = cfg
        self.niche = niche
        self.recent = recent_ids
        self.used: set[str] = set()
        self.local = LocalLibrary(cfg.paths.broll)
        self.providers = stock_providers(cfg)
        if not self.providers:
            log.warning("Weder PEXELS_API_KEY noch PIXABAY_API_KEY – nur eigene Clips aus assets/broll/ und Farbflächen.")
        self.missing: list[int] = []

    def fill(self, shots: list[Shot], on_step: Callable[[float, str], None] | None = None) -> None:
        for n, shot in enumerate(shots, 1):
            shot.media = self._find(shot)
            if on_step:
                on_step(n / len(shots), f"Clip {n} von {len(shots)}")
            if shot.media.media_id:
                self.used.add(shot.media.media_id)
            if shot.media.kind == "color":
                self.missing.append(shot.index)
            log.debug("Shot %02d (%.1f s, Szene %d): %s %s „%s“", shot.index, shot.duration, shot.scene,
                      shot.media.source, shot.media.kind, shot.media.query or "")
        if self.missing:
            log.warning("%d von %d Shots ohne passendes Bildmaterial (Farbfläche): %s",
                        len(self.missing), len(shots), ", ".join(map(str, self.missing)))

    def _find(self, shot: Shot) -> MediaAsset:
        need = shot.duration + 0.5
        for term in shot.terms:
            asset = self.local.find(term, self.used, need)
            if asset:
                return asset
        steps = [(src, "video", term, o) for o in ("portrait", None) for term in shot.terms for src in self.providers]
        steps += [(src, "photo", term, None) for term in shot.terms for src in self.providers]
        steps += [(src, kind, term, "portrait") for term in self.niche.pexels_stil for src in self.providers
                  for kind in ("video", "photo")]
        for src, kind, term, orientation in steps:
            try:
                asset = self._video(src, term, need, orientation) if kind == "video" else self._photo(src, term)
            except BrollError as exc:
                if len(self.providers) == 1:
                    raise
                log.warning("%s – weiter mit der anderen Quelle", exc)
                self.providers = [p for p in self.providers if p is not src]
                return self._find(shot)
            if asset:
                return asset
        return MediaAsset("color", "generiert", query=shot.terms[0] if shot.terms else None)

    def _fresh(self, items: list[dict], prefix: str) -> list[dict]:
        unused = [i for i in items if f"{prefix}{i['id']}" not in self.used]
        return [i for i in unused if f"{prefix}{i['id']}" not in self.recent] or unused

    def _video(self, src, term: str, need: float, orientation: str | None) -> MediaAsset | None:
        videos = [v for v in src.search_videos(term, orientation) if (v.get("duration") or 0) >= need]
        for video in self._fresh(videos, f"{src.name}-video-"):
            file = pick_video_file(video, self.cfg.video.width, self.cfg.video.height)
            if not file:
                continue
            try:
                path = src.download_video(video, file)
            except (HttpError, OSError) as exc:
                log.warning("Download fehlgeschlagen (%s) – nächster Clip", exc)
                continue
            user = video.get("user") or {}
            return MediaAsset("video", src.name, path, f"{src.name}-video-{video['id']}", video.get("url"),
                              user.get("name"), user.get("url"), term, float(video.get("duration") or 0),
                              file["width"], file["height"])
        return None

    def _photo(self, src, term: str) -> MediaAsset | None:
        w, h = self.cfg.video.width * 2, self.cfg.video.height * 2
        for photo in self._fresh(src.search_photos(term), f"{src.name}-photo-"):
            try:
                path = src.download_photo(photo, w, h)
            except (HttpError, OSError, KeyError) as exc:
                log.warning("Foto-Download fehlgeschlagen (%s) – nächstes Foto", exc)
                continue
            return MediaAsset("photo", src.name, path, f"{src.name}-photo-{photo['id']}", photo.get("url"),
                              photo.get("photographer"), photo.get("photographer_url"), term,
                              width=w, height=h)
        return None


def stock_providers(cfg: Config) -> list:
    """Stock-Quellen mit Schlüssel, in Such-Reihenfolge: Pexels (falls vorhanden), dann Pixabay."""
    providers = []
    for env, cls, folder in (("PEXELS_API_KEY", PexelsClient, "pexels"), ("PIXABAY_API_KEY", PixabayClient, "pixabay")):
        key = cfg.env(env)
        if key:
            providers.append(cls(key, cfg.paths.cache / folder, cfg.broll.search_per_page, cfg.broll.search_cache_days))
    return providers


def find_broll(shots: list[Shot], cfg: Config, niche: Niche, recent_ids: set[str],
               on_step: Callable[[float, str], None] | None = None) -> list[int]:
    """Füllt shot.media für alle Shots. Gibt die Indizes ohne passendes Material zurück."""
    finder = BrollFinder(cfg, niche, recent_ids)
    try:
        finder.fill(shots, on_step)
    except FactoryError:
        raise
    except Exception as exc:  # unerwartete API-Antworten
        raise BrollError(f"B-Roll-Suche fehlgeschlagen: {exc}") from exc
    return finder.missing
