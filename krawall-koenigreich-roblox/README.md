# Krawall-Königreich für Roblox

Rundenbasiertes 3D-Taktikspiel im Stil von Mario + Rabbids Kingdom Battle, als Roblox-Spiel.
Drei Helden gegen die Krawallos in drei Gefechten, mit Deckung, Teamsprung, Sprintangriff,
Super-Effekten, Techniken, Bosskampf und **12 freischaltbaren Helden-Skins**.

## Sofort testen

1. [Roblox Studio](https://create.roblox.com/) öffnen.
2. `KrawallKoenigreich.rbxlx` öffnen (Datei → Aus Datei öffnen, oder Doppelklick auf die Datei).
3. Auf **Spielen** (F5) klicken.

Es wird kein Avatar gespawnt: Du steuerst das Spiel über eine freie Kamera mit Maus, Tastatur oder Touch.

### Fortschritt speichern

Siege und Skin-Auswahl werden per DataStore gespeichert. In Studio funktioniert das erst, wenn das Spiel
veröffentlicht ist (Datei → Bei Roblox veröffentlichen) und unter
**Spieleinstellungen → Sicherheit → „Studio-Zugriff auf API-Dienste aktivieren“** eingeschaltet ist.
Ohne das läuft alles normal, nur ohne Speichern (im Ausgabefenster steht dann ein Hinweis).

## Steuerung

| Aktion | Maus / Tastatur | Touch |
|---|---|---|
| Held wählen | Klick auf Held oder Karte, `1`–`3`, `Tab` | Tippen |
| Laufen, Teamsprung, Angriff | Klick auf Feld oder Gegner | Einmal tippen = Vorschau, nochmal tippen = bestätigen |
| Modus | `L` Laufen · `F` Angriff · `T` Technik (zweimal = einsetzen) · `X` abbrechen | Knöpfe unten rechts |
| Zug beenden | `Enter` oder Knopf | Knopf |
| Kamera | rechte Maustaste ziehen = drehen, Mausrad = Zoom, `Q`/`E` drehen, `WASD` verschieben | wischen = drehen, zwei Finger = Zoom |
| Pause / Regeln | `P` / `H` | Knöpfe oben rechts |

## Spielregeln in Kürze

- **Trefferchance:** 100 % ohne Deckung, 50 % hinter Kisten, 0 % hinter Steinmauern. Von der Seite flankieren!
- **Teamsprung:** Zu einem Verbündeten laufen und sich bis zu 3 Felder weit werfen lassen (goldene Felder).
- **Sprintangriff:** Einmal pro Zug durch einen Gegner rennen (oranger Umriss), danach weiterlaufen.
- **Sprungangriff:** Per Teamsprung auf einen Gegner springen (pinker Umriss).
- **Super-Effekte:** Brand (Leo), Rückstoß (Bruna, ins Wasser = 50 Schaden), Honig (Pip, Gegner klebt fest).
- **Techniken:** Leo – Wachsamkeit (Reaktionsschuss), Bruna – Bollwerk (halber Schaden), Pip – Heilwelle.
- Erst laufen, dann schießen: Nach dem Angriff ist die Bewegung vorbei.

## Helden-Skins

Jeder Sieg schaltet neue Outfits frei. Ausrüsten im Titelmenü unter **Helden-Skins** (Garderobe mit 3D-Vorschau)
oder direkt nach dem Sieg.

| Held | sofort | Sieg in Kampf 1 | Sieg in Kampf 2 | Sieg im Thronhof |
|---|---|---|---|---|
| Leo | Abenteurer | Feuerritter (brennender Helmkamm) | Kapitän Leo (Dreispitz, Augenklappe) | Sternenheld (leuchtende Sternkrone) |
| Bruna | Brecherin | Lavaschmiedin (glühende Hörner, Rauch) | Eiswächterin (Eisrüstung, Eiskrone) | Goldene Bruna (Gold-Folie) |
| Pip | Späherin | Schattenninja (roter Schal) | Astronautin (Glashelm, Rucksack) | Regenbogen-Pip (Neon-Irokese) |

Neue Skins ergänzt du in `src/shared/Skins.luau` (Farben, Material, Kopfbedeckung, Effekt) und, falls du eine neue
Kopfbedeckung willst, in `HATS` in `src/client/Models.luau`.

## Projektaufbau

```
src/shared/   Config.luau (Helden, Gegner, Karten), Skins.luau, Rules.luau (komplette Spiellogik + Gegner-KI)
src/server/   Progress.server.luau (Wasser, Wolken, Speichern per DataStore)
src/client/   init.client.luau (Ablauf, Kamera, Eingabe), Board, Models (Skins), Ui, Fx
tests/        simulate.luau, balance.luau, roblox_mock.luau + client_harness.luau
tools/        build_place.py (baut die .rbxlx ohne Rojo), run_client_test.py
```

`Rules.luau` hat keine Roblox-Abhängigkeiten: Jede Aktion ändert den Zustand sofort und liefert eine Liste von
Ereignissen, die der Client anschließend animiert.

## Mit Rojo weiterentwickeln

```
rojo serve                              # live mit Studio synchronisieren (Rojo-Plugin)
rojo build -o KrawallKoenigreich.rbxlx  # Place-Datei neu bauen
```

Ohne Rojo: `python3 tools/build_place.py`.

## Tests

Mit dem Luau-Interpreter (`luau`, https://github.com/luau-lang/luau):

```
luau tests/simulate.luau                          # 360 Partien, Regel-Invarianten, Deckung, Rückstoß, Skins
luau tests/balance.luau                           # Gewinnquote eines vorsichtigen Bots je Level
python3 tools/run_client_test.py /pfad/zu/luau    # kompletter Client + Server in einer Roblox-Nachbildung
```

Der Client-Test führt Client- und Server-Skript in einer nachgebildeten Roblox-API aus und klickt sich durch Menüs,
Garderobe und alle drei Kämpfe. Er findet Laufzeitfehler in der Spiellogik und Darstellung, ersetzt aber keinen Test in
Roblox Studio (Grafik, Performance und echte Roblox-Eigenschaften prüft er nicht).
