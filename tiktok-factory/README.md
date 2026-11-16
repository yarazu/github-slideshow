# tiktok-factory

Desktop-App mit durchscheinender Liquid-Glass-Oberfläche (`python app.py`) und Kommandozeile (`python make.py`), die aus einer Nische oder einem Thema ein **upload-fertiges TikTok-Video** bauen:

- 1080 × 1920 (9:16), 30 fps, H.264 + AAC, MP4, **61–90 s** (Ziel 65–75 s – TikTok vergütet erst ab 1 Minute)
- deutsche KI-Stimme (Azure, optional ElevenLabs) oder deine eigene Aufnahme
- große animierte Untertitel (1–3 Wörter, aktives Wort gelb) im mittleren Drittel; der Hook erscheint in Sekunde 0–2 auf einer Milchglas-Karte
- B-Roll von Pexels (hochkant, kommerziell nutzbar), Bildwechsel alle 2–4 s, leichter Zoom; Fallback: Ken-Burns auf Pexels-Fotos
- leise Hintergrundmusik aus `assets/music/` (18 dB unter der Stimme), Lautheit auf −14 LUFS normalisiert
- dazu `cover.jpg`, `beschreibung.txt` (Text + 3–5 Hashtags + KI-Label-Hinweis) und `meta.json` (Quellen, Clips mit Urheber, Dauer …)

Es gibt **keinen automatischen Upload** – du lädst selbst hoch.

---

## 1. Einrichtung

### Voraussetzungen

| | |
|---|---|
| Python | 3.11 oder neuer (`python3 --version`) |
| ffmpeg | mit libass und libx264 (`ffmpeg -version`) |

ffmpeg installieren, falls es fehlt:

```bash
# macOS (Homebrew)
brew install ffmpeg
# Windows (PowerShell, danach Terminal neu öffnen)
winget install --id Gyan.FFmpeg
# Ubuntu/Debian
sudo apt install ffmpeg
```

Die Pipeline prüft beim Start selbst, ob ffmpeg alle nötigen Filter hat, und sagt dir, was fehlt.

### Projekt installieren

**Am einfachsten (Windows):** ZIP von GitHub laden, entpacken und im Ordner `tiktok-factory` die Datei **`start-windows.bat`** doppelklicken. Beim ersten Mal richtet sie alles ein: Sie bietet an, Python und ffmpeg zu installieren (über winget), legt die Python-Umgebung an und installiert die Pakete – das dauert einige Minuten. Danach startet derselbe Doppelklick direkt die App. Das schwarze Fenster dabei offen lassen; bei einem Fehler bleibt es mit der Meldung stehen. Unter macOS macht `start-mac.command` dasselbe, unter Linux `start-linux.sh`.

Python selbst ist nötig – die App ist ein Python-Programm; eine fertige `.exe` gibt es nicht.

**Von Hand:**

```bash
cd tiktok-factory
python3 -m venv .venv
source .venv/bin/activate            # Windows: .venv\Scripts\activate
pip install -r requirements.txt
cp .env.example .env                 # Windows: copy .env.example .env
```

Dann die App starten und die Keys unter **Einstellungen** eintragen (Abschnitt 3 erklärt, woher sie kommen):

```bash
python app.py
```

Beim **ersten Video** lädt faster-whisper einmalig das Spracherkennungsmodell (`small`, ca. 500 MB) von huggingface.co nach `cache/whisper/`.

### Musik ablegen

Nur Tracks, die du **kommerziell auf Social Media** nutzen darfst (Lizenz selbst prüfen). Ablage nach Stimmung:

```
assets/music/nachdenklich/   psychologie
assets/music/mystisch/       geschichte
assets/music/episch/         weltraum
assets/music/leicht/         tiere
assets/music/ruhig/          stoizismus
assets/music/modern/         wusstestdu, geld, technik, trend
```

mp3, wav, m4a, ogg oder flac. Ist ein Ordner leer, nimmt die Pipeline irgendeinen Track aus `assets/music/`; gibt es gar keinen, entsteht das Video ohne Musik (mit Warnung). Musikdateien werden nicht eingecheckt.

---

## 2. Desktop-App

```bash
python app.py            # oder Doppelklick: start-mac.command / start-windows.bat / start-linux.sh
```

Ein rahmenloses, durchscheinendes Fenster mit vier Bereichen:

| Bereich | Was du dort machst |
|---|---|
| **Studio** | Quelle wählen (Nische, Thema, Trend, eigenes Skript), Sprache, Stimme und Musik einstellen, „Video erzeugen“. Rechts zeigt ein Handy den Fortschritt je Schritt und danach das fertige Video. Mehrere Aufträge laufen nacheinander; Abbrechen geht jederzeit. |
| **Trends** | Die 10 Ideen aus `data/trends.md` mit Quelle und Datum, „Neu recherchieren“ und „Produzieren“ je Idee. Darunter **Neue Nischen**: Claude recherchiert, welche Wissens-Nischen gerade wachsen; „Übernehmen“ macht einen Vorschlag sofort im Studio wählbar (gespeichert in `config/niches_eigene.yaml`). |
| **Bibliothek** | Alle fertigen Videos mit Cover. Ein Klick zeigt Video, Beschreibung und Hashtags zum Kopieren, Hinweise, Quellen mit Erreichbarkeit und die Urheber des Bildmaterials. |
| **Einstellungen** | API-Keys (landen in `.env`, werden nie im Klartext angezeigt), Stimmen-Anbieter, Modell, Darstellung (Glas-Stärke, Farbschema, Akzentfarbe) und ein Systemcheck (ffmpeg, Schrift, Whisper-Modell, Musik). |

**Automatik:** Mit Anthropic-Schlüssel hält die App Trends (älter als 24 h) und Nischen-Vorschläge (älter als 7 Tage) von selbst aktuell – beim Start und alle 30 Minuten, solange sie offen ist. Jede Recherche kostet etwas API-Guthaben (grob 0,10–0,30 $); abschaltbar unter *Einstellungen → System → Automatik*. Unter *Einstellungen → Schlüssel* prüft „Verbindung testen“ jeden Dienst mit einem echten, kostenlosen Probeaufruf.

In der Titelleiste: Protokoll, „Immer im Vordergrund“ und das **Mini-Overlay** – eine kleine schwebende Leiste, in die du nur ein Thema tippst und Enter drückst. `Strg/Cmd + 1–4` wechselt die Bereiche, `Esc` schließt Blätter.

### Transparenz je System

| System | Fenster |
|---|---|
| macOS | echtes System-Glas: Der Desktop hinter dem Fenster wird unscharf (Vibrancy). |
| Windows 10/11 | durchscheinendes Fenster über WebView2 (bei Windows 11 vorinstalliert). Der Desktop dahinter wird per Acrylic unscharf gestellt; lehnt Windows das ab, scheint er klar durch und die App tönt selbst ab. Die Lichtbrechung an den Glaskanten gibt es nur hier und unter Linux (Chromium-Technik). |
| Linux | durchscheinend, wenn ein Compositor läuft (GNOME, KDE … haben einen). `requirements.txt` installiert dafür die Qt-Variante von pywebview. |

Wie viel durchscheint, regelst du unter *Einstellungen → Darstellung → Glas-Stärke*.

| Option | Bedeutung |
|---|---|
| `python app.py --opaque` | deckendes Fenster mit eigenem Farbhintergrund – falls dein System die Transparenz nicht sauber darstellt (schwarze oder weiße Fläche statt Desktop) |
| `python app.py --no-blur` | Windows: ohne Acrylic-Unschärfe (z. B. wenn das Fenster beim Verschieben ruckelt) |
| `python app.py --browser` | Oberfläche im Standardbrowser statt im App-Fenster (auch automatisch, wenn kein Fenster geöffnet werden kann) |
| `python app.py --gui qt` | Fenster-Technik von pywebview erzwingen (`qt`, `gtk`, `edgechromium`) |
| `python app.py --debug` | Entwicklerwerkzeuge und ausführliches Protokoll |

Die App startet einen kleinen Server nur auf `127.0.0.1` mit einem Sitzungs-Token; von außen ist er nicht erreichbar. Fenstergröße unter Windows/Linux: am Griff unten rechts ziehen.

---

## 3. API-Keys – wo du sie bekommst

Am einfachsten in der App unter **Einstellungen** eintragen; sie stehen danach in der Datei `.env`.

| Key in `.env` | Wofür | Wo |
|---|---|---|
| `ANTHROPIC_API_KEY` | Themen, Recherche, Skripte, Trends | [console.anthropic.com](https://console.anthropic.com) → *Settings → API Keys*. Guthaben/Abrechnung einrichten. Für die Faktenrecherche muss die **Websuche** in der Console für deine Organisation erlaubt sein (sonst `SCRIPT_WEB_SEARCH=false`). |
| `AZURE_SPEECH_KEY` + `AZURE_SPEECH_REGION` | Standard-Stimme | [portal.azure.com](https://portal.azure.com) → *Ressource erstellen* → **Speech** (Azure AI Speech) → Region z. B. *West Europe* → Tarif **F0** (kostenlos, 0,5 Mio. Zeichen/Monat ≈ 400 Videos) oder S0 → *Schlüssel und Endpunkt* → „Schlüssel 1“ und Region (z. B. `westeurope`) kopieren. Stimmen anhören: [Speech Studio → Voice Gallery](https://speech.microsoft.com/portal/voicegallery). |
| `ELEVENLABS_API_KEY` + `ELEVENLABS_VOICE_ID` | optionale Stimme | [elevenlabs.io](https://elevenlabs.io) → Profil → *API Keys*; Voice-ID in der Voice Library („ID kopieren“). Kommerzielle Nutzung erst mit bezahltem Abo – aktuelle Bedingungen prüfen. |
| `PEXELS_API_KEY` | B-Roll-Videos und -Fotos | [pexels.com/api](https://www.pexels.com/api/) → kostenloses Konto → *Your API Key*. Limit: 200 Anfragen/Stunde, 20.000/Monat (Suchergebnisse werden 7 Tage gecacht). |

Weitere Einstellungen in `.env`: `ANTHROPIC_MODEL` (Standard `claude-sonnet-5-5`), `ANTHROPIC_EFFORT` (low/medium/high), `TTS_PROVIDER` (azure/elevenlabs), `AZURE_SPEECH_RATE` (Sprechtempo, Standard `+5%`).

Grobe Kosten pro Video: Claude ca. 0,10–0,40 $ (inkl. ca. 6 Websuchen à 0,01 $), Azure im Free-Tier 0 €, Pexels kostenlos.

---

## 4. Kommandozeile

Alles, was die App kann, geht auch ohne Fenster:

```bash
# 3 Videos aus einer Nische (Claude schlägt neue Themen vor – nichts wiederholt sich)
python make.py --niche psychologie --count 3

# ein konkretes Thema (Stil der Nische optional, Standard: wusstestdu)
python make.py --topic "Warum wir Träume sofort vergessen"
python make.py --topic "Warum wir Träume sofort vergessen" --niche psychologie

# aktuelle Trends (nutzt data/trends.md, recherchiert neu, wenn älter als 24 h)
python make.py --niche trend --count 2
python make.py --refresh-trends          # nur Trends neu recherchieren

# eigenes Skript ohne API (Beispiel liegt bei)
python make.py --script-file beispiele/oktopus.json --niche tiere
```

| Option | Bedeutung |
|---|---|
| `--voice de-DE-KatjaNeural` | andere Azure-Stimme; auch `azure`, `elevenlabs`, `elevenlabs:<voice_id>` |
| `--voice-file aufnahme.mp3` | deine eigene Aufnahme statt KI-Stimme (zusammen mit `--script-file`) |
| `--lang de` / `--lang en` | Sprache von Skript, Stimme und Untertiteln |
| `--no-music` | ohne Hintergrundmusik |
| `--script-only` | nur Skript erzeugen (zum Selbst-Einsprechen) |
| `--keep-work` | Zwischendateien in `work/` behalten (Fehlersuche) |
| `--no-whisper` | Wortzeiten nur schätzen – Notlösung für Tests ohne Whisper-Modell |
| `-v` | ausführliche Ausgabe |

**Mit eigener Stimme** (zwei Schritte):

```bash
python make.py --topic "Warum Oktopusse drei Herzen haben" --niche tiere --script-only
# -> output/JJJJ-MM-TT_<slug>/sprechertext.txt vorlesen und aufnehmen
python make.py --script-file output/JJJJ-MM-TT_<slug>/skript.json --voice-file aufnahme.mp3 --niche tiere
```

Die Aufnahme muss 61–90 s lang sein (sie lässt sich nicht automatisch verlängern). Weicht sie stark vom Skript ab, zeigen die Untertitel den tatsächlich gesprochenen Text.

### Eigenes Skript (`--script-file`)

JSON mit diesen Feldern (nur `hook` und `szenen` sind Pflicht):

```json
{
  "titel": "Drei Herzen, blaues Blut",
  "hook": "Ein Oktopus hat drei Herzen. Und eins davon bleibt beim Schwimmen stehen.",
  "hook_overlay": "3 Herzen. Blaues Blut.",
  "hook_pexels_suchbegriffe": ["octopus underwater"],
  "szenen": [{"text": "Zwei kleine Herzen pumpen das Blut nur durch die Kiemen.",
              "pexels_suchbegriffe": ["octopus swimming", "underwater reef"]}],
  "schluss_typ": "loop",
  "beschreibung": "…",
  "hashtags": ["#tierfakten", "#oktopus", "#wusstestdu"],
  "quellen": [{"fakt": "…", "quelle": "Live Science", "url": "https://…"}]
}
```

Vollständiges Beispiel: [`beispiele/oktopus.json`](beispiele/oktopus.json). Ohne Anthropic-Key passt die Pipeline bei falscher Länge nur das Sprechtempo an (max. ±15 %).

---

## 5. Ausgabe

```
output/2026-10-27_drei-herzen-blaues-blut/
├── video.mp4          upload-fertig
├── cover.jpg          Titelbild (Titel auf einer Glas-Karte, im 3:4-sicheren Bereich des Profilrasters)
├── beschreibung.txt   Beschreibung + Hashtags + Hinweis „KI-Label beim Upload aktivieren“
└── meta.json          Nische, Hook, Quellen (+ Erreichbarkeitsprüfung), Dauer, Lautheit,
                       Stimme, Musik, alle Clips mit Pexels-Link und Urheber, Hinweise
```

**Vor dem Upload:** `meta.json → hinweise` lesen (z. B. nicht erreichbare Quellen, Shots ohne passendes Bild) und die Quellen kurz gegenprüfen. Beim Upload in TikTok unter *Weitere Optionen* **„KI-generierte Inhalte“** einschalten.

---

## 6. So funktioniert es

1. **Thema** – aus der Nische (Claude schlägt vor, `data/history.json` verhindert Wiederholungen), aus `data/trends.md` oder per `--topic`.
2. **Recherche** – Claude sucht per Websuche 6–9 belegbare Fakten mit Quellen-URL.
3. **Skript** – Claude schreibt JSON nach festen Regeln (160–185 Wörter, Hook in 2 s ohne Begrüßung, 3–5 Punkte mit Mini-Cliffhangern, stärkster Fakt zuletzt, Loop oder Teil 2, nur belegte Fakten, keine Gesundheits-/Finanzratschläge). Verstöße werden automatisch nachgebessert.
4. **Stimme** – Azure/ElevenLabs/Aufnahme → Dauer messen. Unter 61 s wird das Skript verlängert, über 90 s gekürzt, dann neu vertont.
5. **Wortzeiten** – faster-whisper hört die fertige Tonspur ab; die Wörter werden mit dem Skript abgeglichen (richtige Schreibweise, Szenenzuordnung).
6. **B-Roll** – pro Szene Shots à 2–4 s; Suche: eigene Clips in `assets/broll/` → Pexels-Video hochkant → quer (zugeschnitten) → Pexels-Foto (Ken Burns) → Farbfläche.
7. **Render** – Shots auf 9:16 zuschneiden + leichter Zoom, Hook-Karte aus Milchglas einblenden (das Video dahinter wird unscharf), Untertitel (`.ass`) einbrennen, Musik mischen, 2-Pass-Loudnorm auf −14 LUFS, Endkontrolle mit ffprobe.
8. **Texte** – Cover, Beschreibung, `meta.json`; Eintrag in `data/history.json`.

### Trends

`data/trends.md` enthält 10 Themenideen mit Datum und Quelle. Vor jeder Trend-Charge prüft die Pipeline das Alter (Standard 24 h) und lässt Claude per Websuche neu recherchieren (Google Trends DE, TikTok-Trends, Nachrichten der Woche) – ohne Tragödien, Unglücke oder politische Polarisierung. Du kannst die Datei auch von Hand bearbeiten; produzierte Ideen werden auf „produziert“ gesetzt.

### Eigene Clips (optional)

Lege eigene Videos/Fotos in `assets/broll/` ab und benenne sie mit englischen Stichworten, z. B. `octopus_reef_closeup.mp4`. Passt ein Suchbegriff, haben sie Vorrang vor Pexels.

---

## 7. Anpassen

- `config/niches.yaml` – Nischen: Tonalität, Stimme, Musik-Stimmung, Hashtag-Pool, Pexels-Stil, Themenfelder, Regeln
- `config/settings.yaml` – Untertitel (Schrift, Größe, Farben, Position), Schnitt (2–4 s, Zoom), Lautheit, Musikabstand, Whisper-Modell, Längengrenzen
- Hook-Einblendung: `subtitles.hook_style: glass` (Milchglas-Karte, Standard) oder `box` (weiße Box); Aussehen der Karte im Abschnitt `glass` (Unschärfe, Tönung, Radius, Schriftgröße)
- Oberfläche der App: `ui/` (HTML, CSS, JS ohne Build-Schritt)
- Schrift: Poppins Black (SIL Open Font License, liegt in `assets/fonts/`)

---

## 8. Fehlerbehebung

| Meldung | Lösung |
|---|---|
| Fenster zeigt eine schwarze/weiße Fläche statt des Desktops | `python app.py --opaque` oder in den Einstellungen „Fenster: durchscheinend“ ausschalten |
| `Das App-Fenster konnte nicht geöffnet werden` | Die App läuft dann im Browser weiter. Linux: `pip install "pywebview[qt]"`; Windows 10: WebView2-Runtime von Microsoft installieren |
| `Fehlende Keys in .env: …` / `Es fehlen Schlüssel: …` | Keys eintragen (Abschnitt 3) |
| `ffmpeg/ffprobe wurde nicht gefunden` | ffmpeg installieren, Terminal neu öffnen |
| `faster-whisper-Modell … konnte nicht geladen werden` | Internet beim ersten Lauf nötig (huggingface.co); kleineres Modell in `settings.yaml` (`whisper.model: base`) |
| `Azure Speech: Key ungültig oder Region falsch` | Region muss zur Ressource passen, z. B. `westeurope` |
| `Pexels-Limit erreicht` | eine Stunde warten; Suchen werden gecacht |
| `Die Aufnahme dauert … s` | eigene Aufnahme muss 61–90 s lang sein |
| `x von y Shots ohne passendes Bildmaterial` | Pexels-Key prüfen oder Suchbegriffe im Skript konkreter machen |

Logs: `logs/factory_JJJJ-MM-TT.log`. Zwischendateien mit `--keep-work` in `work/`. Den Ordner `cache/` (Downloads, Whisper-Modell) kannst du jederzeit löschen.

Tests (ohne Netz, ohne Keys):

```bash
python -m pytest
```

---

## 9. Grenzen

- Kein automatischer Upload, kein Login bei TikTok.
- Keine geschützte Musik, keine fremden Videos oder Reddit-Posts, keine KI-Nachbildung echter Personen.
- Jedes Video entsteht aus eigener Recherche und eigenem Skript; `history.json` verhindert Wiederholungen.
- Die Quellenprüfung testet Erreichbarkeit und ob eine URL aus der Websuche stammt – den Inhalt prüfst du selbst.
