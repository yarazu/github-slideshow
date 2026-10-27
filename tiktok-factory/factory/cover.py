"""Cover-Bild: stärkstes Eröffnungsbild + großer Titel (im 3:4-sicheren Bereich des Profilrasters)."""
from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

from .config import Config
from .utils import balance_lines


def make_cover(frame: Path, title: str, out: Path, cfg: Config) -> Path:
    W, H = cfg.video.width, cfg.video.height
    img = Image.open(frame).convert("RGB").resize((W, H))
    img = img.filter(ImageFilter.GaussianBlur(1.2))

    # Abdunkeln zur Mitte hin, damit der Titel immer lesbar ist
    shade = Image.new("L", (W, H), 0)
    sd = ImageDraw.Draw(shade)
    for y in range(H):
        dist = abs(y - H * 0.47) / (H * 0.5)
        sd.line([(0, y), (W, y)], fill=int(150 * max(0.0, 1 - dist ** 1.6)))
    img = Image.composite(Image.new("RGB", (W, H), (0, 0, 0)), img, shade)

    draw = ImageDraw.Draw(img)
    font_file = str(cfg.paths.fonts / cfg.subtitles.font_file)
    text = title.upper() if cfg.subtitles.uppercase else title
    max_width = W - 140
    for size in range(150, 54, -6):
        font = ImageFont.truetype(font_file, size)
        lines = balance_lines(text, lambda t, f=font: draw.textlength(t, font=f), max_width, max_lines=3)
        if lines:
            break
    else:
        lines = text.split()
    ascent, descent = font.getmetrics()
    line_h = int((ascent + descent) * 1.02)
    y = int(H * 0.47 - line_h * len(lines) / 2)
    accent = cfg.subtitles.highlight_color
    for i, line in enumerate(lines):
        fill = accent if i == len(lines) - 1 and len(lines) > 1 else "#FFFFFF"
        draw.text((W / 2, y), line, font=font, fill=fill, anchor="ma", stroke_width=max(6, size // 14),
                  stroke_fill="#000000")
        y += line_h
    out.parent.mkdir(parents=True, exist_ok=True)
    img.save(out, "JPEG", quality=92, optimize=True)
    return out
