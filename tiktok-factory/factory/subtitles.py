"""Wort-Zeitstempel (faster-whisper) und animierte .ass-Untertitel.

Ablauf: Whisper hört die fertige Tonspur ab -> Zeitstempel je Wort. Die Wörter werden mit dem
bekannten Skripttext abgeglichen (difflib), damit die Untertitel richtig geschrieben sind und
jedes Wort seiner Szene zugeordnet ist (für die Bildschnitte).
"""
from __future__ import annotations

import difflib
import logging
import re
import struct
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

from PIL import ImageFont

from . import media
from .config import Config
from .errors import SubtitleError
from .script import Script
from .utils import balance_lines, hex_to_ass, normalize_token

log = logging.getLogger(__name__)

HOOK_SCENE = -1


@dataclass
class Word:
    text: str
    start: float
    end: float
    scene: int = 0


@dataclass
class Token:
    """Ein Wort aus dem Skript, mit Szenenzuordnung."""
    text: str
    scene: int
    sentence_end: bool = False
    clause_end: bool = False


# --------------------------------------------------------------------------------------
# Skript -> Tokens
# --------------------------------------------------------------------------------------
_QUOTES = "„“”\"»«‚‘’()[]"


def script_tokens(script: Script) -> list[Token]:
    tokens: list[Token] = []
    for scene, text in script.parts():
        for raw in text.split():
            if not re.search(r"\w", raw):  # Gedankenstrich, Ellipse …
                if tokens:
                    tokens[-1].clause_end = True
                continue
            tokens.append(Token(
                text=raw.strip(_QUOTES),
                scene=scene,
                sentence_end=bool(re.search(r"[.!?…][" + re.escape(_QUOTES) + r"]*$", raw)),
                clause_end=bool(re.search(r"[,;:–—][" + re.escape(_QUOTES) + r"]*$", raw)),
            ))
    if not tokens:
        raise SubtitleError("Das Skript enthält keine Wörter.")
    return tokens


def display_text(text: str) -> str:
    """Satzzeichen am Wortende weglassen – außer ? und ! (wirken im Untertitel)."""
    text = text.strip(_QUOTES)
    return re.sub(r"[.,;:…]+$", "", text) or text


# --------------------------------------------------------------------------------------
# Zeitstempel
# --------------------------------------------------------------------------------------
@lru_cache(maxsize=1)
def _whisper_model(model: str, device: str, compute_type: str, download_root: str):
    try:
        from faster_whisper import WhisperModel
    except ImportError as exc:
        raise SubtitleError("faster-whisper ist nicht installiert: pip install -r requirements.txt") from exc
    log.info("Lade faster-whisper-Modell „%s“ (%s, %s) …", model, device, compute_type)
    try:
        return WhisperModel(model, device=device, compute_type=compute_type, download_root=download_root)
    except Exception as exc:  # Netzwerk-/Hugging-Face-Fehler kommen in vielen Varianten
        raise SubtitleError(
            f"faster-whisper-Modell „{model}“ konnte nicht geladen werden: {exc}\n"
            "Beim ersten Lauf wird das Modell von huggingface.co geladen (Internet nötig). "
            "Zum Testen ohne Modell: --no-whisper (Zeiten werden dann nur geschätzt).") from exc


def transcribe(wav: Path, cfg: Config, lang: str) -> list[Word]:
    """Wort-Zeitstempel der Tonspur per faster-whisper (lokal)."""
    model = _whisper_model(cfg.whisper.model, cfg.whisper.device, cfg.whisper.compute_type,
                           str(cfg.paths.cache / "whisper"))
    segments, _info = model.transcribe(str(wav), language=lang, word_timestamps=True, beam_size=5,
                                       condition_on_previous_text=False, vad_filter=False)
    words = [Word(w.word.strip(), float(w.start), float(w.end))
             for seg in segments for w in (seg.words or []) if w.word.strip()]
    if not words:
        raise SubtitleError("Whisper hat in der Tonspur keine Wörter erkannt.")
    log.info("Whisper: %d Wörter erkannt", len(words))
    return words


def estimate(wav: Path, tokens: list[Token]) -> list[Word]:
    """Notlösung ohne Whisper: Wörter proportional zur Länge über die Sprechpassagen verteilen."""
    total = media.duration(wav)
    speech: list[tuple[float, float]] = []
    cursor = 0.0
    for s, e in media.detect_silences(wav, noise_db=-35, min_len=0.12):
        if s > cursor + 0.02:
            speech.append((cursor, s))
        cursor = max(cursor, e)
    if cursor < total - 0.02:
        speech.append((cursor, total))
    if not speech:
        speech = [(0.0, total)]
    speech_len = sum(e - s for s, e in speech)

    def real_time(x: float) -> float:
        for s, e in speech:
            if x <= e - s + 1e-9:
                return s + x
            x -= e - s
        return speech[-1][1]

    weights = [len(normalize_token(t.text)) + 1.5 + (2.0 if t.sentence_end else 0.0) for t in tokens]
    total_w = sum(weights)
    words, acc = [], 0.0
    for tok, w in zip(tokens, weights):
        start = real_time(acc / total_w * speech_len)
        acc += w
        end = real_time(acc / total_w * speech_len)
        words.append(Word(tok.text, start, end, tok.scene))
    return words


def align(tokens: list[Token], heard: list[Word]) -> tuple[list[Word], float]:
    """Überträgt die gehörten Zeitstempel auf die Skript-Wörter.

    Liefert (Skript-Wörter mit Zeiten, Anteil exakt wiedergefundener Wörter).
    """
    a = [normalize_token(t.text) for t in tokens]
    b = [normalize_token(w.text) for w in heard]
    times: list[tuple[float, float] | None] = [None] * len(a)
    matched = 0
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes():
        if tag == "equal":
            for k in range(i2 - i1):
                times[i1 + k] = (heard[j1 + k].start, heard[j1 + k].end)
            matched += i2 - i1
        elif tag == "replace":  # z. B. "70" ↔ "siebzig": Zeitraum nach Wortlänge aufteilen
            t0, t1 = heard[j1].start, heard[j2 - 1].end
            weights = [len(a[i]) + 1 for i in range(i1, i2)]
            total, acc = sum(weights), 0
            for k, i in enumerate(range(i1, i2)):
                s = t0 + (t1 - t0) * acc / total
                acc += weights[k]
                times[i] = (s, t0 + (t1 - t0) * acc / total)
    # Nicht gehörte Skript-Wörter zwischen die Nachbarn legen
    n, i = len(a), 0
    first = heard[0].start if heard else 0.0
    last = heard[-1].end if heard else 0.0
    while i < n:
        if times[i] is not None:
            i += 1
            continue
        j = i
        while j < n and times[j] is None:
            j += 1
        left = times[i - 1][1] if i > 0 else first
        right = times[j][0] if j < n else max(last, left + 0.3 * (j - i))
        right = max(right, left + 0.05 * (j - i))
        step = (right - left) / (j - i)
        for k in range(i, j):
            times[k] = (left + step * (k - i), left + step * (k - i + 1))
        i = j
    starts = [t[0] for t in times]  # type: ignore[index]
    for k in range(1, n):
        starts[k] = max(starts[k], starts[k - 1] + 0.02)
    words = []
    for k, tok in enumerate(tokens):
        end = times[k][1]  # type: ignore[index]
        if k + 1 < n:
            end = min(end, starts[k + 1])
        words.append(Word(tok.text, starts[k], max(end, starts[k] + 0.02), tok.scene))
    return words, matched / max(1, n)


def assign_scenes(heard: list[Word], timed_script: list[Word]) -> list[Word]:
    """Ordnet gehörte Wörter (bei starker Abweichung vom Skript) den Szenen zu."""
    out, k = [], 0
    for w in heard:
        mid = (w.start + w.end) / 2
        while k + 1 < len(timed_script) and timed_script[k + 1].start <= mid:
            k += 1
        out.append(Word(w.text, w.start, w.end, timed_script[k].scene))
    return out


def word_timings(wav: Path, script: Script, cfg: Config, lang: str, *,
                 use_whisper: bool = True) -> tuple[list[Word], list[Word], dict]:
    """Liefert (Wörter für die Untertitel, Skript-Wörter mit Zeiten für den Schnitt, Info)."""
    tokens = script_tokens(script)
    if not use_whisper:
        log.warning("Ohne Whisper: Wortzeiten werden nur geschätzt (--no-whisper).")
        words = estimate(wav, tokens)
        return words, words, {"methode": "geschaetzt"}
    heard = transcribe(wav, cfg, lang)
    timed, ratio = align(tokens, heard)
    info = {"methode": "faster-whisper", "modell": cfg.whisper.model, "uebereinstimmung": round(ratio, 3)}
    log.info("Abgleich Skript ↔ Tonspur: %.0f %% der Wörter exakt wiedergefunden", ratio * 100)
    if ratio < cfg.whisper.min_match:
        log.warning("Die Tonspur weicht stark vom Skript ab – Untertitel zeigen den erkannten Text.")
        info["anzeige"] = "erkannter Text"
        return assign_scenes(heard, timed), timed, info
    info["anzeige"] = "Skripttext"
    return timed, timed, info


def scene_spans(words: list[Word], total: float) -> list[tuple[int, float, float]]:
    """(Szene, Start, Ende) lückenlos von 0 bis total – Grundlage für die Schnitte."""
    spans: list[list] = []
    for w in words:
        if spans and spans[-1][0] == w.scene:
            spans[-1][2] = w.end
        else:
            spans.append([w.scene, w.start, w.end])
    if not spans:
        return [(0, 0.0, total)]
    spans[0][1] = 0.0
    for k in range(len(spans) - 1):
        spans[k][2] = spans[k + 1][1]
    spans[-1][2] = total
    return [(s, a, b) for s, a, b in spans if b > a]


# --------------------------------------------------------------------------------------
# ASS
# --------------------------------------------------------------------------------------
def _win_metrics_factor(font_file: Path) -> float:
    """Geviert pro ASS-Fontsize: libass skaliert wie VSFilter auf usWinAscent+usWinDescent (OS/2)."""
    data = font_file.read_bytes()
    tables = {}
    for i in range(struct.unpack(">H", data[4:6])[0]):
        tag, _checksum, offset, _length = struct.unpack(">4sIII", data[12 + 16 * i:28 + 16 * i])
        tables[tag] = offset
    if b"OS/2" not in tables or b"head" not in tables:
        return 1 / 1.4  # übliche Näherung
    units_per_em = struct.unpack(">H", data[tables[b"head"] + 18:tables[b"head"] + 20])[0]
    win_ascent, win_descent = struct.unpack(">HH", data[tables[b"OS/2"] + 74:tables[b"OS/2"] + 78])
    return units_per_em / max(1, win_ascent + win_descent)


class TextMeter:
    """Misst Textbreiten so, wie libass sie rendert – damit nichts über den Rand läuft."""

    def __init__(self, font_file: Path):
        if not font_file.exists():
            raise SubtitleError(f"Schriftdatei fehlt: {font_file}")
        self.font = ImageFont.truetype(str(font_file), 100)
        self.em_per_size = _win_metrics_factor(font_file)

    def width(self, text: str, ass_size: float) -> float:
        return self.font.getlength(text) / 100 * ass_size * self.em_per_size


def _ts(seconds: float) -> str:
    cs = max(0, int(round(seconds * 100)))
    h, rest = divmod(cs, 360000)
    m, rest = divmod(rest, 6000)
    s, cs = divmod(rest, 100)
    return f"{h}:{m:02d}:{s:02d}.{cs:02d}"


def _esc(text: str) -> str:
    return text.replace("\\", "/").replace("{", "(").replace("}", ")")


def group_words(words: list[Word], max_words: int, max_chars: int, max_gap: float = 0.45) -> list[list[Word]]:
    """1–3 Wörter pro Einblendung; Umbruch an Satzenden, Pausen und Zeichenlimit."""
    groups: list[list[Word]] = []
    current: list[Word] = []
    for w in words:
        if current:
            prev = current[-1]
            text_len = len(" ".join(display_text(x.text) for x in current + [w]))
            if (len(current) >= max_words or text_len > max_chars or w.start - prev.end > max_gap
                    or re.search(r"[.!?…]$", prev.text) or (re.search(r"[,;:]$", prev.text) and len(current) >= 2)
                    or w.scene != prev.scene):
                groups.append(current)
                current = []
        current.append(w)
    if current:
        groups.append(current)
    return groups


def balanced_lines(meter: TextMeter, text: str, size: float, max_width: float,
                   max_lines: int = 3) -> list[str] | None:
    return balance_lines(text, lambda t: meter.width(t, size), max_width, max_lines)


def build_ass(words: list[Word], cfg: Config, *, hook_text: str, total: float) -> str:
    st = cfg.subtitles
    meter = TextMeter(cfg.paths.fonts / st.font_file)
    W, H = cfg.video.width, cfg.video.height
    upper = (lambda t: t.upper()) if st.uppercase else (lambda t: t)
    white, hl = hex_to_ass(st.color), hex_to_ass(st.highlight_color)
    lines = [
        "[Script Info]",
        "; erzeugt von tiktok-factory",
        "ScriptType: v4.00+",
        f"PlayResX: {W}",
        f"PlayResY: {H}",
        "WrapStyle: 2",
        "ScaledBorderAndShadow: yes",
        "",
        "[V4+ Styles]",
        "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, "
        "Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, "
        "Alignment, MarginL, MarginR, MarginV, Encoding",
        f"Style: Caption,{st.font_name},{st.font_size},{white},{white},{hex_to_ass(st.outline_color)},"
        f"&H96000000,0,0,0,0,100,100,0,0,1,{st.outline},{st.shadow},5,40,40,0,1",
        f"Style: Hook,{st.font_name},{st.hook_font_size},{hex_to_ass(st.hook_text_color)},"
        f"{hex_to_ass(st.hook_text_color)},{hex_to_ass(st.hook_box_color)},&H00000000,0,0,0,0,100,100,0,0,"
        "3,20,0,5,40,40,0,1",
        "",
        "[Events]",
        "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text",
    ]

    # Hook groß einblenden (Sekunde 0–2), oberhalb der Untertitel
    hook = upper(" ".join(hook_text.split()))
    if hook:
        size = float(st.hook_font_size)
        wrapped = balanced_lines(meter, hook, size, W - 160)
        while wrapped is None and size > 40:
            size -= 4
            wrapped = balanced_lines(meter, hook, size, W - 160)
        wrapped = wrapped or hook.split()
        hook_end = min(st.hook_duration, total)
        lines.append(f"Dialogue: 1,{_ts(0)},{_ts(hook_end)},Hook,,0,0,0,,"
                     f"{{\\pos({W // 2},{st.hook_position_y})\\fs{size:.0f}\\fad(120,200)}}"
                     + "\\N".join(_esc(l) for l in wrapped))

    groups = group_words(words, st.max_words, st.max_chars)
    for g_idx, group in enumerate(groups):
        texts = [_esc(upper(display_text(w.text))) for w in group]
        width = meter.width(" ".join(texts), st.font_size) + 2 * st.outline
        scale = min(100.0, 100.0 * st.max_width / width) if width else 100.0
        g_start = 0.0 if g_idx == 0 else group[0].start
        nxt = groups[g_idx + 1][0].start if g_idx + 1 < len(groups) else total
        g_end = nxt if nxt - group[-1].end < 0.6 else group[-1].end + 0.25
        for k, w in enumerate(group):
            start = g_start if k == 0 else w.start
            end = group[k + 1].start if k + 1 < len(group) else g_end
            if round(end * 100) <= round(start * 100):
                continue
            parts = [f"{{\\c{_inline(hl)}}}{t}{{\\c{_inline(white)}}}" if i == k else t
                     for i, t in enumerate(texts)]
            anim = (f"\\fscx{scale * 0.85:.0f}\\fscy{scale * 0.85:.0f}\\t(0,90,\\fscx{scale:.0f}\\fscy{scale:.0f})"
                    if k == 0 else f"\\fscx{scale:.0f}\\fscy{scale:.0f}")
            lines.append(f"Dialogue: 0,{_ts(start)},{_ts(end)},Caption,,0,0,0,,"
                         f"{{\\pos({W // 2},{st.position_y}){anim}}}" + " ".join(parts))
    return "\n".join(lines) + "\n"


def _inline(ass_color: str) -> str:
    """'&H0035E1FF' -> '&H35E1FF&' (Format für \\c im Text)."""
    return f"&H{ass_color[-6:]}&"
