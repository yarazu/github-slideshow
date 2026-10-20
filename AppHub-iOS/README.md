# App-Hub für iPhone

Eine native SwiftUI-App, entstanden aus dem Design-Entwurf „App-Hub“. Der Hub bündelt deine Konnektoren an einem Ort:

| Konnektor | Was funktioniert | Wie |
|---|---|---|
| **Google Kalender** | Nächster Termin, die nächsten 7 Tage, Kalender ein-/ausblenden, neue Termine anlegen, Teilnehmende anschreiben, Route planen | EventKit, also die Kalender deines iPhones (inkl. Google-Konto aus den iOS-Einstellungen) – keine Einrichtung nötig |
| **Gmail** | Ungelesene Mails, Posteingang mit Absender, Betreff und Vorschau, neue Mail in der Gmail-App verfassen | Offizielle Gmail-API mit OAuth + PKCE, nur Lesezugriff |
| **Spotify** | Aktueller Titel mit Cover und Fortschritt, Play/Pause/Vor/Zurück, Playlists starten, zuletzt gehört | Offizielle Spotify-Web-API mit OAuth + PKCE |

**Design:** Glas-Karten (Liquid Glass ab iOS 26, Material davor) über einem Hintergrund deiner Wahl:

- **Eigenes Hintergrundbild** aus der Fotos-App (wird verkleinert lokal gespeichert)
- fünf Verläufe (Polarlicht, Abendrot, Ozean, Wald, Graphit)
- Regler für Unschärfe und Abdunklung, damit Text auf jedem Foto lesbar bleibt
- fünf Akzentfarben (Limette aus dem Entwurf, Himmel, Aprikose, Flieder, Rosé)

Alle Änderungen sieht man live im Bildschirm „Design“ (Pinsel-Symbol oben rechts).

## Installieren

### Mit einem Mac (empfohlen)

1. Xcode 16 oder neuer installieren.
2. `AppHub-iOS/AppHub.xcodeproj` öffnen.
3. Target **AppHub** › *Signing & Capabilities* › bei *Team* deine Apple-ID wählen. Falls Xcode meldet, dass die Bundle-ID vergeben ist, ändere `com.yarazu.AppHub` in etwas Eigenes.
4. iPhone per Kabel verbinden, oben als Ziel auswählen und ▶︎ drücken.
5. Auf dem iPhone beim ersten Start: *Einstellungen › Allgemein › VPN & Geräteverwaltung* › Entwickler-App vertrauen.

Mit einer kostenlosen Apple-ID läuft die App 7 Tage, danach einfach erneut aus Xcode installieren. Mit einem bezahlten Entwickler-Account (99 €/Jahr) geht auch TestFlight.

### Ohne Mac

Bei jedem Push baut GitHub Actions die App (Workflow „iOS-App bauen“). Unter *Actions* › letzter Lauf › *Artifacts* liegt `AppHub-unsigned-ipa`. Diese Datei kannst du mit [Sideloadly](https://sideloadly.io) oder [AltStore](https://altstore.io) mit deiner Apple-ID signieren und installieren.

Dieselbe Aktion legt im Artefakt `screenshots` Bilder aus dem Simulator ab.

## Konnektoren einrichten

Gmail und Spotify verbinden sich über deine eigenen, kostenlosen Entwickler-Zugänge – es gibt keinen fremden Server dazwischen, Tokens liegen im iOS-Schlüsselbund. Die Anleitung steht auch in der App (Regler-Symbol oben rechts › *Konnektoren einrichten*), inklusive Kopier-Buttons.

**Gmail**

1. In der [Google Cloud Console](https://console.cloud.google.com/projectcreate) ein Projekt anlegen.
2. Die [Gmail API](https://console.cloud.google.com/apis/library/gmail.googleapis.com) aktivieren.
3. OAuth-Zustimmungsbildschirm einrichten (Zielgruppe „Extern“), dich selbst als Testnutzer eintragen.
4. Unter *Anmeldedaten* eine OAuth-Client-ID vom Typ **iOS** mit der Bundle-ID der App anlegen.
5. Client-ID (endet auf `.apps.googleusercontent.com`) in der App einfügen und *Mit Google anmelden*.

**Spotify**

1. Im [Spotify Developer Dashboard](https://developer.spotify.com/dashboard) *Create app* wählen.
2. Redirect-URI `apphub://spotify-callback` eintragen und *Web API* auswählen.
3. Client-ID in der App einfügen und *Mit Spotify anmelden*. Die Steuerung der Wiedergabe braucht Spotify Premium.

**Kalender**

Google-Konto unter *Einstellungen › Apps › Kalender › Kalender-Accounts* hinzufügen, dann im Hub auf *Kalender* tippen und den Zugriff erlauben.

## Unterschiede zum Entwurf

- **Overlay über anderen Apps:** iOS erlaubt keine Fenster über fremden Apps. Der Schnellzugriff aus dem Overlay (nächster Termin, laufende Musik, Mail-Aktionen) sitzt deshalb direkt auf der Startseite des Hubs.
- **Automationen** („Wenn ein Termin beginnt, Spotify pausieren“) brauchen Hintergrundausführung, die iOS Apps nicht dauerhaft erlaubt. Die Aktionen gibt es stattdessen als Ein-Tipp-Buttons. Kurzbefehle-Automationen oder ein Widget wären der nächste Schritt.

## Aufbau

```
AppHub/
├── AppHubApp.swift            App-Einstieg, Navigation, Toast
├── Model/
│   ├── Appearance.swift       Hintergrundbild, Verläufe, Unschärfe, Akzent
│   ├── Connector.swift        Kalender, Gmail, Spotify
│   └── HubStore.swift         Zentraler Zustand
├── Services/
│   ├── OAuth.swift            OAuth 2.0 + PKCE, Schlüsselbund
│   ├── CalendarService.swift  EventKit + nativer Termin-Editor
│   ├── GmailService.swift     Gmail-API
│   └── SpotifyService.swift   Spotify-Web-API
└── Views/                     Hub, Detailseiten, Verbinden-Sheet, Design, Einrichtung
```

Voraussetzungen: iOS 17 oder neuer, Xcode 16 oder neuer.
