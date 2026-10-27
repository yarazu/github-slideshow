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
        key = cfg.env("PEXELS_API_KEY")
        self.pexels = (PexelsClient(key, cfg.paths.cache / "pexels", cfg.broll.search_per_page,
                                    cfg.broll.search_cache_days) if key else None)
        if not self.pexels:
            log.warning("PEXELS_API_KEY fehlt – nur eigene Clips aus assets/broll/ und Farbflächen.")
        self.missing: list[int] = []

    def fill(self, shots: list[Shot]) -> None:
        for shot in shots:
            shot.media = self._find(shot)
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
        if self.pexels:
            for orientation in ("portrait", None):
                for term in shot.terms:
                    asset = self._pexels_video(term, need, orientation)
                    if asset:
                        return asset
            for term in shot.terms:
                asset = self._pexels_photo(term)
                if asset:
                    return asset
            for term in self.niche.pexels_stil:
                asset = self._pexels_video(term, need, "portrait") or self._pexels_photo(term)
                if asset:
                    return asset
        return MediaAsset("color", "generiert", query=shot.terms[0] if shot.terms else None)

    def _fresh(self, items: list[dict], prefix: str) -> list[dict]:
        unused = [i for i in items if f"{prefix}{i['id']}" not in self.used]
        return [i for i in unused if f"{prefix}{i['id']}" not in self.recent] or unused

    def _pexels_video(self, term: str, need: float, orientation: str | None) -> MediaAsset | None:
        videos = [v for v in self.pexels.search_videos(term, orientation) if (v.get("duration") or 0) >= need]
        for video in self._fresh(videos, "pexels-video-"):
            file = pick_video_file(video, self.cfg.video.width, self.cfg.video.height)
            if not file:
                continue
            try:
                path = self.pexels.download_video(video, file)
            except (HttpError, OSError) as exc:
                log.warning("Download fehlgeschlagen (%s) – nächster Clip", exc)
                continue
            user = video.get("user") or {}
            return MediaAsset("video", "pexels", path, f"pexels-video-{video['id']}", video.get("url"),
                              user.get("name"), user.get("url"), term, float(video.get("duration") or 0),
                              file["width"], file["height"])
        return None

    def _pexels_photo(self, term: str) -> MediaAsset | None:
        w, h = self.cfg.video.width * 2, self.cfg.video.height * 2
        for photo in self._fresh(self.pexels.search_photos(term), "pexels-photo-"):
            try:
                path = self.pexels.download_photo(photo, w, h)
            except (HttpError, OSError, KeyError) as exc:
                log.warning("Foto-Download fehlgeschlagen (%s) – nächstes Foto", exc)
                continue
            return MediaAsset("photo", "pexels", path, f"pexels-photo-{photo['id']}", photo.get("url"),
                              photo.get("photographer"), photo.get("photographer_url"), term,
                              width=w, height=h)
        return None


def find_broll(shots: list[Shot], cfg: Config, niche: Niche, recent_ids: set[str]) -> list[int]:
    """Füllt shot.media für alle Shots. Gibt die Indizes ohne passendes Material zurück."""
    finder = BrollFinder(cfg, niche, recent_ids)
    try:
        finder.fill(shots)
    except FactoryError:
        raise
    except Exception as exc:  # unerwartete API-Antworten
        raise BrollError(f"B-Roll-Suche fehlgeschlagen: {exc}") from exc
    return finder.missing
