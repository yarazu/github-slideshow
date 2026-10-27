"""Kleine Helfer: Slugs, Wörter zählen, HTTP mit Wiederholungen, Downloads."""
from __future__ import annotations

import logging
import re
import time
import unicodedata
from collections.abc import Callable
from itertools import combinations
from pathlib import Path

import requests

log = logging.getLogger(__name__)

USER_AGENT = "tiktok-factory/1.0 (+lokale Video-Pipeline)"

_TRANSLIT = str.maketrans({"ä": "ae", "ö": "oe", "ü": "ue", "ß": "ss", "Ä": "ae", "Ö": "oe", "Ü": "ue"})


def slugify(text: str, max_len: int = 60) -> str:
    text = text.translate(_TRANSLIT)
    text = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode()
    text = re.sub(r"[^a-zA-Z0-9]+", "-", text).strip("-").lower()
    if len(text) > max_len:
        text = text[:max_len].rsplit("-", 1)[0]
    return text or "video"


def words_of(text: str) -> list[str]:
    """Gesprochene Wörter: alles mit mindestens einem Buchstaben oder einer Ziffer."""
    return [t for t in text.split() if re.search(r"\w", t)]


def count_words(text: str) -> int:
    return len(words_of(text))


def normalize_token(token: str) -> str:
    """Für den Abgleich Skript ↔ Whisper: klein, ohne Satzzeichen, ß→ss."""
    token = token.lower().replace("ß", "ss")
    return re.sub(r"[^\w]", "", token).replace("_", "")


class HttpError(Exception):
    def __init__(self, message: str, status: int | None = None):
        super().__init__(message)
        self.status = status


def http_request(method: str, url: str, *, retries: int = 4, timeout: float = 30,
                 **kwargs) -> requests.Response:
    """HTTP mit Backoff bei 429/5xx/Netzfehlern. Andere 4xx werden sofort zurückgegeben."""
    headers = {"User-Agent": USER_AGENT, **(kwargs.pop("headers", None) or {})}
    delay = 2.0
    for attempt in range(1, retries + 1):
        try:
            resp = requests.request(method, url, headers=headers, timeout=timeout, **kwargs)
        except (requests.ConnectionError, requests.Timeout) as exc:
            if attempt == retries:
                raise HttpError(f"keine Verbindung zu {url.split('/')[2]} ({type(exc).__name__})") from exc
            log.debug("Netzfehler (%s), Versuch %d/%d", exc, attempt, retries)
        else:
            if resp.status_code != 429 and resp.status_code < 500:
                return resp
            if attempt == retries:
                return resp
            retry_after = resp.headers.get("Retry-After", "")
            if retry_after.isdigit():
                delay = max(delay, min(float(retry_after), 60.0))
            log.debug("HTTP %s von %s, neuer Versuch in %.0fs", resp.status_code, url, delay)
        time.sleep(delay)
        delay = min(delay * 2, 30.0)
    raise HttpError(f"Anfrage an {url} fehlgeschlagen")  # pragma: no cover


def download(url: str, dest: Path, *, headers: dict | None = None, timeout: float = 120) -> Path:
    """Lädt url nach dest (atomar). Vorhandene, nicht-leere Dateien werden wiederverwendet."""
    if dest.exists() and dest.stat().st_size > 0:
        return dest
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix(dest.suffix + ".part")
    resp = http_request("GET", url, headers=headers, timeout=timeout, stream=True)
    if resp.status_code != 200:
        raise HttpError(f"Download fehlgeschlagen (HTTP {resp.status_code}): {url}", resp.status_code)
    with open(tmp, "wb") as fh:
        for chunk in resp.iter_content(chunk_size=1 << 20):
            fh.write(chunk)
    tmp.replace(dest)
    return dest


def hex_to_ass(color: str, alpha: int = 0) -> str:
    """'#FFE135' -> '&H0035E1FF' (ASS: &HAABBGGRR)."""
    c = color.lstrip("#")
    if len(c) != 6:
        raise ValueError(f"Farbe '{color}' ist kein #RRGGBB-Wert")
    r, g, b = c[0:2], c[2:4], c[4:6]
    return f"&H{alpha:02X}{b}{g}{r}".upper()


def balance_lines(text: str, width_of: Callable[[str], float], max_width: float,
                  max_lines: int = 3) -> list[str] | None:
    """Teilt text in möglichst gleich breite Zeilen (≤ max_lines). None, wenn es nicht passt."""
    words = text.split()
    if not words:
        return []
    if width_of(text) <= max_width:
        return [text]
    for n in range(2, min(max_lines, len(words)) + 1):
        best, best_width = None, float("inf")
        for cuts in combinations(range(1, len(words)), n - 1):
            bounds = (0, *cuts, len(words))
            lines = [" ".join(words[a:b]) for a, b in zip(bounds, bounds[1:])]
            widest = max(width_of(line) for line in lines)
            if widest <= max_width and widest < best_width:
                best, best_width = lines, widest
        if best:
            return best
    return None
