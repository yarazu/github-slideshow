"""Liquid-Glass-Elemente fürs Video: Milchglas-Karte mit Lichtkante für Hook und Cover.

Die Karte besteht aus zwei Teilen:
  * panel – RGBA-Grafik mit Schatten, Tönung, Lichtkante, Glanz und Text
  * mask  – Form der Karte; damit wird das Video dahinter unscharf gestellt (in ffmpeg bzw. Pillow)
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageEnhance, ImageFilter, ImageFont

from .config import Config
from .utils import balance_lines

_EMOJI = re.compile("[\U0001F000-\U0001FAFF☀-➿️‍]")


@dataclass
class GlassCard:
    panel: Image.Image      # RGBA, um `pad` größer als die Karte (Platz für den Schatten)
    mask: Image.Image       # L, exakt Kartengröße
    x: int                  # Position der Karte im Bild
    y: int
    w: int
    h: int
    pad: int

    def save(self, folder: Path, name: str = "hook") -> tuple[Path, Path]:
        panel, mask = folder / f"{name}_panel.png", folder / f"{name}_mask.png"
        self.panel.save(panel)
        self.mask.save(mask)
        return panel, mask


def _even(value: float) -> int:
    return int(round(value / 2)) * 2


def _rgb(color: str) -> tuple[int, int, int]:
    c = color.lstrip("#")
    return int(c[0:2], 16), int(c[2:4], 16), int(c[4:6], 16)


def rounded_mask(w: int, h: int, radius: int, supersample: int = 3) -> Image.Image:
    big = Image.new("L", (w * supersample, h * supersample), 0)
    ImageDraw.Draw(big).rounded_rectangle((0, 0, w * supersample - 1, h * supersample - 1),
                                          radius=radius * supersample, fill=255)
    return big.resize((w, h), Image.LANCZOS)


def _gradient(w: int, h: int, values: list[list[int]]) -> Image.Image:
    """Weicher Verlauf aus einem kleinen Raster von Helligkeitswerten."""
    small = Image.new("L", (len(values[0]), len(values)))
    small.putdata([v for row in values for v in row])
    return small.resize((w, h), Image.BILINEAR)


def _layer(size: tuple[int, int], color: tuple[int, int, int], alpha: Image.Image) -> Image.Image:
    layer = Image.new("RGBA", size, (*color, 0))
    layer.putalpha(alpha)
    return layer


def _scaled(alpha: Image.Image, factor: float) -> Image.Image:
    return alpha.point(lambda v: int(v * factor))


def glass_panel(w: int, h: int, radius: int, *, tint: tuple[int, int, int], tint_opacity: float,
                pad: int) -> tuple[Image.Image, Image.Image]:
    """Glaskörper ohne Text: (panel RGBA in Größe w+2·pad × h+2·pad, mask L in w × h)."""
    size = (w + 2 * pad, h + 2 * pad)
    mask = rounded_mask(w, h, radius)
    on_canvas = Image.new("L", size, 0)
    on_canvas.paste(mask, (pad, pad))
    panel = Image.new("RGBA", size, (0, 0, 0, 0))

    # Schatten – nur außerhalb der Karte, Glas bleibt durchsichtig
    shadow = Image.new("L", size, 0)
    shadow.paste(mask, (pad, pad + 16))
    shadow = ImageChops.multiply(shadow.filter(ImageFilter.GaussianBlur(26)), ImageChops.invert(on_canvas))
    panel = Image.alpha_composite(panel, _layer(size, (0, 0, 0), _scaled(shadow, 0.55)))

    # Tönung: oben etwas heller, unten dichter
    tone = ImageChops.multiply(on_canvas, _gradient(*size, [[int(255 * tint_opacity * 0.82)],
                                                            [int(255 * min(1.0, tint_opacity * 1.12))]]))
    panel = Image.alpha_composite(panel, _layer(size, tint, tone))

    # Glanz von oben
    sheen = ImageChops.multiply(on_canvas, _gradient(*size, [[70], [16], [0], [0]]))
    panel = Image.alpha_composite(panel, _layer(size, (255, 255, 255), sheen))

    # weiches Leuchten am Innenrand
    inner = Image.new("L", size, 0)
    inset = 16
    inner.paste(rounded_mask(w - 2 * inset, h - 2 * inset, max(4, radius - inset)), (pad + inset, pad + inset))
    glow = ImageChops.multiply(ImageChops.subtract(on_canvas, inner).filter(ImageFilter.GaussianBlur(9)), on_canvas)
    panel = Image.alpha_composite(panel, _layer(size, (255, 255, 255), _scaled(glow, 0.16)))

    # Lichtkante: hell oben links, dunkler in der Mitte, zweiter Reflex unten rechts
    edge = 3
    core = Image.new("L", size, 0)
    core.paste(rounded_mask(w - 2 * edge, h - 2 * edge, max(4, radius - edge)), (pad + edge, pad + edge))
    rim = ImageChops.multiply(ImageChops.subtract(on_canvas, core),
                              _gradient(*size, [[255, 190, 70], [170, 60, 80], [60, 90, 150]]))
    panel = Image.alpha_composite(panel, _layer(size, (255, 255, 255), rim))
    return panel, mask


def clean_text(text: str) -> str:
    """Emojis entfernen (die Schrift hat keine) und Leerraum glätten."""
    return " ".join(_EMOJI.sub("", text).split())


def text_card(text: str, cfg: Config, *, center_y: int, font_px: int | None = None, max_lines: int = 3,
              accent_last_line: bool = True) -> GlassCard:
    """Glas-Karte mit zentriertem Text, horizontal mittig im Bild, vertikal um center_y."""
    g, st = cfg.glass, cfg.subtitles
    W = cfg.video.width
    text = clean_text(text.upper() if st.uppercase else text)
    font_file = str(cfg.paths.fonts / st.font_file)
    max_text = W - 2 * g.margin - 2 * g.padding_x
    size = font_px or g.font_px
    probe = ImageDraw.Draw(Image.new("L", (8, 8)))
    while True:
        font = ImageFont.truetype(font_file, size)
        lines = balance_lines(text, lambda t, f=font: probe.textlength(t, font=f), max_text, max_lines=max_lines)
        if lines or size <= 44:
            break
        size -= 4
    lines = lines or text.split() or [""]
    line_h = round(size * 1.16)
    text_w = max(probe.textlength(line, font=font) for line in lines)
    w = _even(text_w + 2 * g.padding_x)
    h = _even(len(lines) * line_h + 2 * g.padding_y - size * 0.18)
    pad = 64
    panel, mask = glass_panel(w, h, min(g.radius, h // 2), tint=_rgb(g.tint), tint_opacity=g.tint_opacity, pad=pad)

    # Text: weicher Schatten + Schrift; letzte Zeile in der Akzentfarbe
    first_y = pad + h / 2 - (len(lines) - 1) * line_h / 2
    shadow = Image.new("L", panel.size, 0)
    sd = ImageDraw.Draw(shadow)
    for i, line in enumerate(lines):
        sd.text((pad + w / 2, first_y + i * line_h + 5), line, font=font, fill=150, anchor="mm")
    panel = Image.alpha_composite(panel, _layer(panel.size, (0, 0, 0), shadow.filter(ImageFilter.GaussianBlur(7))))
    draw = ImageDraw.Draw(panel)
    for i, line in enumerate(lines):
        accent = accent_last_line and len(lines) > 1 and i == len(lines) - 1
        draw.text((pad + w / 2, first_y + i * line_h), line, font=font, anchor="mm",
                  fill=_rgb(st.highlight_color) if accent else _rgb(g.text_color))
    return GlassCard(panel=panel, mask=mask, x=_even((W - w) / 2), y=_even(center_y - h / 2), w=w, h=h, pad=pad)


def composite(image: Image.Image, card: GlassCard, blur: float) -> Image.Image:
    """Legt die Karte auf ein Standbild (für das Cover): Hintergrund unscharf + Glas darüber."""
    box = (card.x, card.y, card.x + card.w, card.y + card.h)
    backdrop = image.crop(box).filter(ImageFilter.GaussianBlur(blur))
    backdrop = ImageEnhance.Color(backdrop).enhance(1.35)
    out = image.convert("RGBA")
    out.paste(backdrop, box[:2], card.mask)
    out.alpha_composite(card.panel, (card.x - card.pad, card.y - card.pad))
    return out.convert("RGB")
