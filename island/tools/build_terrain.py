#!/usr/bin/env python3
"""Baut die Gelände-Textur für die Island-Karte.

Lädt Höhendaten (AWS Terrain Tiles, Terrarium-Format) und die Gletscherflächen
von Natural Earth und schreibt eine RGB-PNG:
  R = Höhe (0..63 Meer -400..0 m, 64..255 Land 0..2120 m)
  G = Gletschermaske (0..255, kantengeglättet)
  B = Schummerung (Hillshade, 128 = flach)

Das Bild wird als Base64 direkt in ../index.html eingebettet (Tag
<script id="terrain-data">), damit die Seite ohne weitere Dateien läuft.

Aufruf:  python3 build_terrain.py  [--png terrain.png]
"""
import argparse
import base64
import io
import json
import math
import os
import re
import urllib.request

import numpy as np
from PIL import Image, ImageDraw

LON_MIN, LON_MAX = -24.9, -13.0
LAT_MIN, LAT_MAX = 63.1, 66.75
WIDTH = 1600
ZOOM = 8
TILE_URL = "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png"
GLACIER_URL = ("https://raw.githubusercontent.com/nvkelso/natural-earth-vector/"
               "master/geojson/ne_10m_glaciated_areas.geojson")
CACHE = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".cache")

KM_PER_DEG = 111.32
LAT0 = (LAT_MIN + LAT_MAX) / 2
KM_PER_PX = (LON_MAX - LON_MIN) * math.cos(math.radians(LAT0)) * KM_PER_DEG / WIDTH
HEIGHT = round((LAT_MAX - LAT_MIN) * KM_PER_DEG / KM_PER_PX)


def fetch(url, name):
    os.makedirs(CACHE, exist_ok=True)
    path = os.path.join(CACHE, name)
    if not os.path.exists(path):
        with urllib.request.urlopen(url) as r, open(path, "wb") as f:
            f.write(r.read())
    with open(path, "rb") as f:
        return f.read()


def tile_xy(lon, lat, z):
    n = 2 ** z
    x = (lon + 180) / 360 * n
    y = (1 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2 * n
    return x, y


def elevation_grid():
    x0, y0 = tile_xy(LON_MIN, LAT_MAX, ZOOM)
    x1, y1 = tile_xy(LON_MAX, LAT_MIN, ZOOM)
    tx0, ty0, tx1, ty1 = int(x0), int(y0), int(x1), int(y1)
    mosaic = np.zeros(((ty1 - ty0 + 1) * 256, (tx1 - tx0 + 1) * 256), np.float32)
    for ty in range(ty0, ty1 + 1):
        for tx in range(tx0, tx1 + 1):
            png = fetch(TILE_URL.format(z=ZOOM, x=tx, y=ty), f"t{ZOOM}_{tx}_{ty}.png")
            a = np.asarray(Image.open(io.BytesIO(png)).convert("RGB"), np.float32)
            e = a[..., 0] * 256 + a[..., 1] + a[..., 2] / 256 - 32768
            mosaic[(ty - ty0) * 256:(ty - ty0 + 1) * 256,
                   (tx - tx0) * 256:(tx - tx0 + 1) * 256] = e

    # Zielraster (gleichabständig in km) -> Mercator-Pixel des Mosaiks
    lons = LON_MIN + (np.arange(WIDTH) + 0.5) / WIDTH * (LON_MAX - LON_MIN)
    lats = LAT_MAX - (np.arange(HEIGHT) + 0.5) / HEIGHT * (LAT_MAX - LAT_MIN)
    n = 2 ** ZOOM
    px = ((lons + 180) / 360 * n - tx0) * 256 - 0.5
    py = ((1 - np.arcsinh(np.tan(np.radians(lats))) / np.pi) / 2 * n - ty0) * 256 - 0.5
    gx, gy = np.meshgrid(px, py)
    ix, iy = np.floor(gx).astype(int), np.floor(gy).astype(int)
    fx, fy = gx - ix, gy - iy
    m = mosaic
    return ((m[iy, ix] * (1 - fx) + m[iy, ix + 1] * fx) * (1 - fy)
            + (m[iy + 1, ix] * (1 - fx) + m[iy + 1, ix + 1] * fx) * fy)


def glacier_mask():
    data = json.loads(fetch(GLACIER_URL, "glaciers.geojson"))
    scale = 4
    img = Image.new("L", (WIDTH * scale, HEIGHT * scale), 0)
    draw = ImageDraw.Draw(img)

    def to_px(c):
        return ((c[0] - LON_MIN) / (LON_MAX - LON_MIN) * WIDTH * scale,
                (LAT_MAX - c[1]) / (LAT_MAX - LAT_MIN) * HEIGHT * scale)

    for feat in data["features"]:
        geom = feat["geometry"]
        polys = geom["coordinates"] if geom["type"] == "MultiPolygon" else [geom["coordinates"]]
        for poly in polys:
            ring = poly[0]
            if not any(LON_MIN < c[0] < LON_MAX and LAT_MIN < c[1] < LAT_MAX for c in ring):
                continue
            draw.polygon([to_px(c) for c in ring], fill=255)
            for hole in poly[1:]:
                draw.polygon([to_px(c) for c in hole], fill=0)
    return np.asarray(img.resize((WIDTH, HEIGHT), Image.LANCZOS), np.float32)


def hillshade(elev, exaggeration=3.0):
    land = np.maximum(elev, 0)
    for axis in (0, 1):  # leichte Glättung gegen Treppeneffekte
        land = (np.roll(land, 1, axis) + 2 * land + np.roll(land, -1, axis)) / 4
    cell = KM_PER_PX * 1000
    dzdx = np.gradient(land, axis=1) / cell * exaggeration
    dzdy = -np.gradient(land, axis=0) / cell * exaggeration
    az, alt = math.radians(315), math.radians(42)
    lx, ly, lz = math.cos(alt) * math.sin(az), math.cos(alt) * math.cos(az), math.sin(alt)
    nz = 1 / np.sqrt(1 + dzdx ** 2 + dzdy ** 2)
    shade = (-dzdx * lx - dzdy * ly + lz) * nz
    flat = lz
    return np.clip(128 + (shade - flat) * 220, 0, 255)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser()
    ap.add_argument("--html", default=os.path.join(here, "..", "index.html"))
    ap.add_argument("--png", help="zusätzlich als PNG speichern")
    args = ap.parse_args()

    elev = elevation_grid()
    r = np.where(elev < 0,
                 np.clip((elev + 400) / 400 * 63, 0, 63),
                 64 + np.clip(elev / 2120 * 191, 0, 191))
    g = glacier_mask()
    b = hillshade(elev)
    rgb = np.stack([r, g, b], -1).round().astype(np.uint8)
    buf = io.BytesIO()
    Image.fromarray(rgb, "RGB").save(buf, "PNG", optimize=True)
    png = buf.getvalue()
    if args.png:
        with open(args.png, "wb") as f:
            f.write(png)

    with open(args.html, encoding="utf-8") as f:
        html = f.read()
    tag = re.compile(r'(<script id="terrain-data" type="text/plain">).*?(</script>)', re.S)
    if not tag.search(html):
        raise SystemExit("Tag <script id=\"terrain-data\"> nicht gefunden")
    b64 = base64.b64encode(png).decode()
    html = tag.sub(lambda m: m.group(1) + "\n" + b64 + "\n" + m.group(2), html)
    with open(args.html, "w", encoding="utf-8") as f:
        f.write(html)
    print(f"{WIDTH}x{HEIGHT} px, {KM_PER_PX:.3f} km/px, höchster Punkt {elev.max():.0f} m, "
          f"{len(png) / 1024:.0f} KB -> {os.path.relpath(args.html)}")


if __name__ == "__main__":
    main()
