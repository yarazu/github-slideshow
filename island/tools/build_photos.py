#!/usr/bin/env python3
"""Bereitet Reisefotos für die Island-Karte auf.

Liest alle Fotos aus einem Ordner, holt Standort und Aufnahmezeit aus den
EXIF-Daten, fasst nahe beieinander liegende Fotos zu Orten zusammen und schreibt
  photos/img/*.jpg      (max. 1600 px, für die Story-Ansicht)
  photos/thumbs/*.jpg   (200 x 260 px, für Bubbles und Orte-Leiste)
  photos/photos.json    (wird von index.html geladen)

Fotos ohne GPS lassen sich über eine CSV-Datei zuordnen (Trennzeichen ; ):
  datei;ort;text
  IMG_2041.jpg;Skógafoss;Regenbogen am Wasserfall
  IMG_2050.jpg;63.4044,-19.0450;
In der Spalte "ort" steht ein bekannter Ortsname (siehe GAZETTEER) oder
"Breite,Länge". "text" wird als Bildunterschrift angezeigt.

Aufruf:
  python3 build_photos.py ORDNER [--titel "Island 2025"] [--orte orte.csv]
"""
import argparse
import csv
import json
import math
import os
import re
import sys
from datetime import datetime

from PIL import Image, ImageOps

try:  # iPhone-Fotos (HEIC), falls pillow-heif installiert ist
    from pillow_heif import register_heif_opener
    register_heif_opener()
except ImportError:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "photos")
EXTS = (".jpg", ".jpeg", ".png", ".webp", ".heic", ".heif")
GROUP_KM = 1.5
BOUNDS = (63.1, 66.75, -24.9, -13.0)  # lat_min, lat_max, lon_min, lon_max

GAZETTEER = {
    "Reykjavík": (64.1466, -21.9426, "Hauptstadtregion"),
    "Hallgrímskirkja": (64.1417, -21.9266, "Reykjavík"),
    "Harpa": (64.1504, -21.9325, "Reykjavík"),
    "Bláa Lónið": (63.8804, -22.4495, "Reykjanes"),
    "Keflavík": (64.0049, -22.5624, "Reykjanes"),
    "Reykjanesviti": (63.8156, -22.7044, "Reykjanes"),
    "Fagradalsfjall": (63.8936, -22.2700, "Reykjanes"),
    "Kleifarvatn": (63.9264, -21.9886, "Reykjanes"),
    "Þingvellir": (64.2559, -21.1299, "Golden Circle"),
    "Geysir": (64.3104, -20.3024, "Golden Circle"),
    "Gullfoss": (64.3271, -20.1199, "Golden Circle"),
    "Kerið": (64.0413, -20.8851, "Golden Circle"),
    "Selfoss": (63.9331, -20.9971, "Süden"),
    "Hveragerði": (64.0003, -21.1866, "Süden"),
    "Reykjadalur": (64.0228, -21.2116, "Süden"),
    "Seljalandsfoss": (63.6156, -19.9886, "Südküste"),
    "Gljúfrabúi": (63.6206, -19.9861, "Südküste"),
    "Skógafoss": (63.5321, -19.5114, "Südküste"),
    "Sólheimajökull": (63.5297, -19.3702, "Südküste"),
    "Sólheimasandur Flugzeugwrack": (63.4591, -19.3647, "Südküste"),
    "Dyrhólaey": (63.4027, -19.1300, "Südküste"),
    "Reynisfjara": (63.4044, -19.0450, "bei Vík"),
    "Vík": (63.4186, -19.0060, "Südküste"),
    "Fjaðrárgljúfur": (63.7712, -18.1719, "Süden"),
    "Kirkjubæjarklaustur": (63.7894, -18.0533, "Süden"),
    "Landmannalaugar": (63.9917, -19.0603, "Hochland"),
    "Þórsmörk": (63.6833, -19.5167, "Hochland"),
    "Skaftafell": (64.0167, -16.9667, "Vatnajökull"),
    "Svartifoss": (64.0275, -16.9753, "Vatnajökull"),
    "Fjallsárlón": (64.0158, -16.3700, "Vatnajökull"),
    "Jökulsárlón": (64.0784, -16.2306, "Vatnajökull"),
    "Diamond Beach": (64.0444, -16.1781, "Vatnajökull"),
    "Höfn": (64.2539, -15.2082, "Südosten"),
    "Vestrahorn": (64.2516, -14.9989, "bei Höfn"),
    "Djúpivogur": (64.6566, -14.2836, "Ostfjorde"),
    "Egilsstaðir": (65.2653, -14.3948, "Osten"),
    "Seyðisfjörður": (65.2597, -14.0103, "Ostfjorde"),
    "Hengifoss": (65.0731, -14.8789, "Osten"),
    "Stuðlagil": (65.1635, -15.3050, "Osten"),
    "Dettifoss": (65.8147, -16.3846, "Nordosten"),
    "Ásbyrgi": (66.0167, -16.5000, "Nordosten"),
    "Húsavík": (66.0449, -17.3389, "Norden"),
    "Mývatn": (65.6039, -16.9961, "Norden"),
    "Hverir": (65.6406, -16.8100, "Mývatn"),
    "Grjótagjá": (65.6261, -16.8828, "Mývatn"),
    "Goðafoss": (65.6828, -17.5502, "Norden"),
    "Akureyri": (65.6835, -18.0878, "Norden"),
    "Siglufjörður": (66.1522, -18.9086, "Norden"),
    "Hvítserkur": (65.6064, -20.6372, "Nordwesten"),
    "Ísafjörður": (66.0749, -23.1240, "Westfjorde"),
    "Dynjandi": (65.7329, -23.1999, "Westfjorde"),
    "Látrabjarg": (65.5034, -24.5300, "Westfjorde"),
    "Rauðasandur": (65.4667, -23.9500, "Westfjorde"),
    "Kirkjufell": (64.9419, -23.3051, "Snæfellsnes"),
    "Arnarstapi": (64.7667, -23.6167, "Snæfellsnes"),
    "Búðakirkja": (64.8217, -23.3842, "Snæfellsnes"),
    "Djúpalónssandur": (64.7525, -23.8961, "Snæfellsnes"),
    "Stykkishólmur": (65.0752, -22.7297, "Snæfellsnes"),
    "Borgarnes": (64.5383, -21.9206, "Westen"),
    "Hraunfossar": (64.7028, -20.9775, "Westen"),
    "Deildartunguhver": (64.6636, -21.4111, "Westen"),
    "Glymur": (64.3833, -21.2500, "Westen"),
}


def km(a, b):
    dx = (a[1] - b[1]) * math.cos(math.radians((a[0] + b[0]) / 2)) * 111.32
    return math.hypot(dx, (a[0] - b[0]) * 111.32)


def nearest_name(lat, lon):
    name, (glat, glon, region) = min(GAZETTEER.items(), key=lambda kv: km((lat, lon), kv[1][:2]))
    d = km((lat, lon), (glat, glon))
    if d < 3:
        return name, region
    if d < 30:
        return f"bei {name}", region
    return f"{lat:.3f}° N, {abs(lon):.3f}° W", ""


def exif_info(img):
    exif = img.getexif()
    info = {}
    date = exif.get_ifd(0x8769).get(0x9003) or exif.get(0x0132)
    if date:
        try:
            info["date"] = datetime.strptime(str(date).strip("\x00 "), "%Y:%m:%d %H:%M:%S").isoformat(timespec="minutes")
        except ValueError:
            pass
    gps = exif.get_ifd(0x8825)
    if 2 in gps and 4 in gps:
        def dms(v):
            return float(v[0]) + float(v[1]) / 60 + float(v[2]) / 3600
        try:
            lat = dms(gps[2]) * (-1 if gps.get(1) == "S" else 1)
            lon = dms(gps[4]) * (-1 if gps.get(3) == "W" else 1)
            if math.isfinite(lat) and math.isfinite(lon):
                info["lat"], info["lon"] = lat, lon
        except (TypeError, ZeroDivisionError, IndexError):
            pass
    return info


def parse_place(value):
    value = value.strip()
    m = re.match(r"^\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*$", value)
    if m:
        return float(m.group(1)), float(m.group(2)), None
    for name, (lat, lon, _region) in GAZETTEER.items():
        if name.casefold() == value.casefold():
            return lat, lon, name
    raise SystemExit(f"Unbekannter Ort in der CSV: {value!r} (Name aus GAZETTEER oder 'Breite,Länge')")


def read_overrides(path):
    if not path:
        return {}
    out = {}
    with open(path, encoding="utf-8-sig", newline="") as f:
        for row in csv.DictReader(f, delimiter=";"):
            datei = (row.get("datei") or "").strip()
            if not datei:
                continue
            entry = {"text": (row.get("text") or "").strip()}
            if (row.get("ort") or "").strip():
                entry["lat"], entry["lon"], entry["name"] = parse_place(row["ort"])
            out[datei.casefold()] = entry
    return out


def slug(name, used):
    base = re.sub(r"[^a-z0-9]+", "-", os.path.splitext(name)[0].lower()).strip("-") or "foto"
    s, i = base, 2
    while s in used:
        s, i = f"{base}-{i}", i + 1
    used.add(s)
    return s


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("ordner")
    ap.add_argument("--titel", default="Island")
    ap.add_argument("--orte", help="CSV mit Zuordnungen für Fotos ohne GPS")
    args = ap.parse_args()

    overrides = read_overrides(args.orte)
    os.makedirs(os.path.join(OUT, "img"), exist_ok=True)
    os.makedirs(os.path.join(OUT, "thumbs"), exist_ok=True)

    files = sorted(f for f in os.listdir(args.ordner) if f.lower().endswith(EXTS))
    photos, missing, used = [], [], set()
    for name in files:
        try:
            img = Image.open(os.path.join(args.ordner, name))
            info = exif_info(img)
            img = ImageOps.exif_transpose(img).convert("RGB")
        except Exception as e:  # defekte oder unbekannte Datei
            print(f"  übersprungen: {name} ({e})", file=sys.stderr)
            continue
        ov = overrides.get(name.casefold(), {})
        if "lat" in ov:
            info["lat"], info["lon"] = ov["lat"], ov["lon"]
        if "lat" not in info or not (BOUNDS[0] < info["lat"] < BOUNDS[1] and BOUNDS[2] < info["lon"] < BOUNDS[3]):
            missing.append(name)
            continue
        s = slug(name, used)
        big = img.copy()
        big.thumbnail((1600, 1600), Image.LANCZOS)
        big.save(os.path.join(OUT, "img", s + ".jpg"), quality=82, optimize=True, progressive=True)
        ImageOps.fit(img, (200, 260), Image.LANCZOS).save(os.path.join(OUT, "thumbs", s + ".jpg"), quality=80)
        photos.append({
            "src": f"photos/img/{s}.jpg", "thumb": f"photos/thumbs/{s}.jpg",
            "date": info.get("date", ""), "caption": ov.get("text", ""),
            "lat": round(info["lat"], 5), "lon": round(info["lon"], 5),
            "_name": ov.get("name"), "_file": name,
        })

    # Chronologisch sortieren und nahe Fotos zu Orten zusammenfassen
    photos.sort(key=lambda p: (p["date"] or "9999", p["_file"]))
    places = []
    for p in photos:
        place = next((pl for pl in places if km((p["lat"], p["lon"]), (pl["lat"], pl["lon"])) < GROUP_KM), None)
        if place is None:
            place = {"lat": p["lat"], "lon": p["lon"], "photos": [], "_names": []}
            places.append(place)
        place["photos"].append(p)
        if p["_name"]:
            place["_names"].append(p["_name"])
        n = len(place["photos"])
        place["lat"] = round(sum(q["lat"] for q in place["photos"]) / n, 5)
        place["lon"] = round(sum(q["lon"] for q in place["photos"]) / n, 5)

    for pl in places:
        name, region = nearest_name(pl["lat"], pl["lon"])
        if pl["_names"]:
            name = max(set(pl["_names"]), key=pl["_names"].count)
            region = GAZETTEER[name][2]
        pl["name"], pl["region"] = name, region
        del pl["_names"]
        for p in pl["photos"]:
            del p["_name"], p["_file"]

    data = {"title": args.titel, "places": [
        {k: pl[k] for k in ("name", "region", "lat", "lon", "photos")} for pl in places]}
    with open(os.path.join(OUT, "photos.json"), "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)

    print(f"{len(photos)} Fotos an {len(places)} Orten -> photos/photos.json")
    for pl in places:
        print(f"  {pl['name']:<34} {len(pl['photos'])} Foto(s)")
    if missing:
        print(f"\n{len(missing)} Foto(s) ohne Standort in Island (per --orte zuordnen):")
        for name in missing:
            print("  " + name)


if __name__ == "__main__":
    main()
