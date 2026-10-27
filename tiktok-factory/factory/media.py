"""ffmpeg/ffprobe-Aufrufe: Prüfung, Ausführung, Dauer, Lautheitsmessung."""
from __future__ import annotations

import json
import logging
import re
import shlex
import shutil
import subprocess
from pathlib import Path

from .errors import ConfigError, RenderError

log = logging.getLogger(__name__)

INSTALL_HINT = """ffmpeg/ffprobe wurde nicht gefunden. So installierst du es:
  macOS:          brew install ffmpeg
  Windows:        winget install --id Gyan.FFmpeg   (danach Terminal neu öffnen)
  Ubuntu/Debian:  sudo apt install ffmpeg
Prüfen mit:       ffmpeg -version"""

REQUIRED_FILTERS = ("ass", "zoompan", "loudnorm", "amix", "gradients")


def check_ffmpeg() -> str:
    """Prüft, ob ffmpeg mit allen benötigten Filtern installiert ist. Gibt die Version zurück."""
    if not shutil.which("ffmpeg") or not shutil.which("ffprobe"):
        raise ConfigError(INSTALL_HINT)
    version = subprocess.run(["ffmpeg", "-version"], capture_output=True, text=True).stdout.split("\n")[0]
    filters = subprocess.run(["ffmpeg", "-hide_banner", "-filters"], capture_output=True, text=True).stdout
    missing = [f for f in REQUIRED_FILTERS if not re.search(rf"^\s*\S+\s+{f}\s", filters, re.M)]
    if missing:
        raise ConfigError(
            f"Dein ffmpeg kann folgende Filter nicht: {', '.join(missing)}. "
            "Bitte ein vollständiges Build installieren (mit libass und libx264).\n" + INSTALL_HINT)
    encoders = subprocess.run(["ffmpeg", "-hide_banner", "-encoders"], capture_output=True, text=True).stdout
    if "libx264" not in encoders:
        raise ConfigError("Dein ffmpeg hat keinen H.264-Encoder (libx264).\n" + INSTALL_HINT)
    return version


def run_ffmpeg(args: list[str], what: str, *, cwd: Path | None = None,
               loglevel: str = "error") -> subprocess.CompletedProcess:
    cmd = ["ffmpeg", "-hide_banner", "-nostdin", "-y", "-loglevel", loglevel, *map(str, args)]
    log.debug("ffmpeg [%s]: %s", what, shlex.join(cmd))
    proc = subprocess.run(cmd, capture_output=True, text=True, cwd=cwd)
    if proc.returncode != 0:
        tail = "\n".join(proc.stderr.strip().splitlines()[-12:])
        raise RenderError(f"ffmpeg-Fehler bei „{what}“:\n{tail}")
    return proc


def probe(path: Path) -> dict:
    cmd = ["ffprobe", "-v", "error", "-print_format", "json", "-show_format", "-show_streams", str(path)]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RenderError(f"ffprobe kann {path.name} nicht lesen: {proc.stderr.strip()[-300:]}")
    return json.loads(proc.stdout)


def duration(path: Path) -> float:
    info = probe(path)
    value = info.get("format", {}).get("duration")
    if value is None:
        raise RenderError(f"Keine Dauer für {path.name} ermittelbar")
    return float(value)


def measure_loudness(path: Path, *, target_lufs: float = -14, true_peak: float = -1.5,
                     lra: float = 11, filter_prefix: str = "") -> dict[str, float]:
    """EBU-R128-Messung via loudnorm (1. Pass). Liefert input_i, input_tp, input_lra, ..."""
    af = f"{filter_prefix}loudnorm=I={target_lufs}:TP={true_peak}:LRA={lra}:print_format=json"
    proc = run_ffmpeg(["-i", path, "-af", af, "-f", "null", "-"], f"Lautheit messen ({path.name})",
                      loglevel="info")
    match = re.search(r"\{[^{}]*\"input_i\"[^{}]*\}", proc.stderr, re.S)
    if not match:
        raise RenderError(f"Lautheitsmessung lieferte kein Ergebnis für {path.name}")
    data = json.loads(match.group(0))
    result = {}
    for key, value in data.items():
        try:
            result[key] = float(value)
        except (TypeError, ValueError):
            continue
    return result


def detect_silences(path: Path, noise_db: float = -35, min_len: float = 0.15) -> list[tuple[float, float]]:
    """Liste von (start, ende) aller Pausen."""
    proc = run_ffmpeg(["-i", path, "-af", f"silencedetect=noise={noise_db}dB:d={min_len}", "-f", "null", "-"],
                      "Pausen erkennen", loglevel="info")
    starts = [float(x) for x in re.findall(r"silence_start: ([\d.]+)", proc.stderr)]
    ends = [float(x) for x in re.findall(r"silence_end: ([\d.]+)", proc.stderr)]
    return list(zip(starts, ends))
