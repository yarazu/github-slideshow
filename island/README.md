# Island Fotokarte

Eine interaktive 3D-Karte von Island. Auf der Karte sitzen deine Reisefotos als runde Bubbles,
ähnlich wie bei der Snapchat-Karte. Tippst du auf eine Bubble, öffnet sich eine Story mit allen
Fotos von diesem Ort.

- **Gelände:** echte Höhendaten (AWS Terrain Tiles) mit 4-facher Überhöhung und die Gletscher
  aus Natural Earth, eingebettet in `index.html`.
- **Bedienung:** ziehen = verschieben, rechte Maustaste oder zwei Finger = drehen und neigen,
  Mausrad oder Pinch = zoomen.
- **Stories:** rechts tippen = weiter, links tippen = zurück, gedrückt halten = Pause,
  nach unten wischen oder `Esc` = schließen.
- **„Eigene Fotos“:** Fotos direkt im Browser hinzufügen. Fotos mit GPS-Daten landen automatisch
  am richtigen Ort, die anderen platzierst du per Tipp auf die Karte. Diese Fotos bleiben nur im
  geöffneten Browser-Tab.

Solange `photos/photos.json` keine Orte enthält, zeigt die Karte eine Beispielreise mit
gezeichneten Platzhalterbildern.

## Eigene Fotos fest einbauen

```bash
python3 island/tools/build_photos.py ~/Bilder/Island --titel "Island 2025"
```

Das Skript liest Standort und Aufnahmezeit aus den EXIF-Daten, verkleinert die Bilder und fasst
Fotos, die näher als 1,5 km beieinander liegen, zu einem Ort zusammen. Den Namen nimmt es von der
nächstgelegenen bekannten Sehenswürdigkeit. Fotos ohne GPS ordnest du über eine CSV-Datei zu:

```
datei;ort;text
IMG_2041.jpg;Skógafoss;Regenbogen am Wasserfall
IMG_2050.jpg;63.4044,-19.0450;
```

```bash
python3 island/tools/build_photos.py ~/Bilder/Island --orte orte.csv
```

iPhone-Fotos im HEIC-Format brauchen `pip install pillow-heif`.

## Ansehen

Die Seite lädt `photos/photos.json` per `fetch`. Sie muss daher über einen Webserver laufen,
zum Beispiel über GitHub Pages oder lokal:

```bash
cd island && python3 -m http.server 8000
# dann http://localhost:8000 öffnen
```

## Gelände neu erzeugen

```bash
python3 island/tools/build_terrain.py
```

Das Skript lädt die Kacheln (zwischengespeichert in `tools/.cache/`) und bettet das Ergebnis
in `index.html` ein. Braucht `numpy` und `Pillow`.
