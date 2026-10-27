# PolDash

**Alpha** · Dashcam und Geschwindigkeitsmessung für Polizei-Roleplay auf FiveM. Auf Englisch **PoliceDash**.

[English version](README.md)

> **Alpha:** Alle Funktionen sind fertig und laufen auf einem Test-Server (ESX Legacy). Rechne mit Ecken und
> Kanten, vor allem im Bild-im-Bild-Modus. Nutze PolDash auf Test- oder Community-Servern und melde Fehler.
> Einstellungen und Datenformate können sich bis 1.0 noch ändern.
>
> Fehler und Feedback: [GitHub Issues](https://github.com/Kargobob1/policedash/issues) oder Discord: Excurse (`execurse2`).

Nachfahren (MAN) und Weg-Zeit-Messung (VASCAR) mit Toleranzabzug, Messprotokoll, Beweisfoto und -video
sowie MDT-Anbindung. Keine Pflicht-Abhängigkeiten.

## Funktionen

- Dashcam an der Frontscheibe mit Einblendung (Datum, Uhrzeit, Eigengeschwindigkeit, Modus, Messwert, Laufzeit, Ziel, REC)
- **Bild-im-Bild:** normal weiterfahren, ein kleiner Monitor zeigt die Dashcam live
- Zielerfassung im Sichtkegel vor dem Fahrzeug, übernimmt Kennzeichen und Modell
- **MAN (Nachfahren):** Durchschnittsgeschwindigkeit über ein Intervall, der Abstand zum Ziel wird geprüft
- **Weg-Zeit (VASCAR):** Start- und Endpunkt setzen, Geschwindigkeit = Strecke / Zeit
- Toleranzabzug (konfigurierbar, km/h und mph), Ergebnis-Karte mit Grund bei ungültigen Messungen
- **Beifahrer-Bedienung:** Wer das Gerät einschaltet, bedient es. Die anderen Insassen sehen dieselbe Anzeige.
- Bedienteil mit Maus: Tasten, Status, Historie mit Mini-Karte, persönliche Einstellungen
- **Beweisvideo** nur der Dashcam mit eingebrannter Einblendung, ohne zusätzliche Resource
- Messvideos im Spiel abspielen, allein oder für alle im Umkreis
- Serverseitige Prüfung, Messnummern `PV-2026-000123`, Speicherung in oxmysql oder KVP
- Discord-Webhook, HTTP-Export an MDT-Systeme, Exports und Events
- Uploads ausschließlich serverseitig, kein API-Key landet beim Client
- Idle 0,00 ms: Frame-Schleifen laufen nur bei aktiver Kamera oder Messung

## Installation

1. Ordner nach `resources/policedash` kopieren. Den Ordnernamen `policedash` beibehalten, Exports und gespeicherte Daten hängen daran.
2. In der `server.cfg` **nach** den optionalen Abhängigkeiten starten:

```cfg
ensure oxmysql        # optional - Messprotokolle in der Datenbank
ensure ox_lib         # optional - Benachrichtigungen
ensure screencapture  # optional - Beweisfotos (alternativ screenshot-basic)
ensure [framework]    # optional - es_extended, qb-core oder qbx_core
ensure policedash

# Secrets nur hier, nie in der config.lua
set policedash_fivemanage_key ""
set policedash_discord_webhook ""
set policedash_upload_key ""     # nur provider 'custom'
set policedash_export_key ""     # nur Config.Export

# Standalone bzw. zusätzlich für Admins
add_ace group.admin policedash.use allow
```

3. Mit oxmysql wird die Tabelle beim Start automatisch angelegt (`sql/install.sql` für manuelle Installation).
4. Im Spiel `/poldash debug` aufrufen. Die Ausgabe in F8 zeigt Framework, erkannte Resources und Berechtigung.
   Die Serverkonsole warnt beim Start vor ungültigen Werten in der `config.lua`.

**Pflicht-Abhängigkeiten: keine.** Alles Optionale wird zur Laufzeit erkannt.
OneSync wird empfohlen (nötig für Beifahrer-Bedienung und Positionsprüfung).
Spiel-Build **2189 oder neuer** für die ruhige Kamerabefestigung (`Config.CamAttach = 'hard'`).

## Bedienung

| Taste (Standard) | Funktion |
|---|---|
| F7 | Vollbild-Dashcam ein/aus |
| F9 | Bedienteil (Maus), ESC schließt |
| NUMPAD9 | Ziel erfassen / freigeben |
| NUMPAD5 | MAN: Start/Stop · Weg-Zeit: Start-, dann Endpunkt |
| NUMPAD8 | Modus wechseln |
| NUMPAD2 | Zurücksetzen / Messung abbrechen |
| NUMPAD0 | Beweisfoto zur letzten Messung |
| NUMPAD7 | Bild-im-Bild-Monitor manuell live |
| RÜCKTASTE | Videofenster schließen |

Alle Tasten lassen sich unter *Einstellungen → Tastenbelegung → FiveM* ändern.

## Befehle

`/poldash` und `/policedash` funktionieren beide, unabhängig von der Sprache.

| Befehl | Funktion |
|---|---|
| `/poldash pip` | Bild-im-Bild ein/aus |
| `/poldash pip live` | Monitor live / Standby |
| `/poldash pip fps <10-24>` | Dashcam-FPS (Monitor und Video), pro Spieler gespeichert |
| `/poldash play <Nr>` | Messvideo selbst ansehen (z.B. Richter, Anwalt) |
| `/poldash show [Nr]` | Video allen im Umkreis vorführen (ohne Nummer: letzte eigene Messung) |
| `/poldash debug` | Diagnose in F8 (Serverkonsole: `poldash debug`) |

Mit `Config.Debug = true` gibt es zusätzliche Befehle zum Feinabstimmen (`/poldash pip raw|log|hud|cam|…`, `/poldash offset`), siehe `client/pip.lua`.

**Nachfahren (MAN):** Ziel erfassen, Messung starten, dem Ziel in möglichst gleichem Abstand folgen (Standard 10–80 m, Schwankung bis 30 %, im FunMode 45 %), nach mindestens 3 s stoppen.

**Weg-Zeit (VASCAR):** Ziel erfassen. Startpunkt setzen, wenn das Ziel ein Merkmal passiert (z.B. eine Kreuzung), Endpunkt beim zweiten Merkmal. Die Strecke muss 100–2000 m lang sein. Der Startpunkt wird am Boden markiert.

## Bild-im-Bild (Alpha)

FiveM kann pro Frame nur eine Kamera rendern. PolDash nimmt deshalb jeden N-ten Frame für die Dashcam (etwa 15 pro Sekunde). Jeder Frame trägt eine winzige Farbmarke, anhand der das NUI die Frames auf dein Bild und den Monitor verteilt. Die fehlenden Frames in deinem Bild überblendet es.

- Standardmäßig ist der Monitor nur während einer Messung live. Sonst siehst du das echte Spielbild, und der Monitor zeigt ein Standbild.
- `liveMode = 'always'` hält ihn dauerhaft live, mit niedriger Rate (`idleFps`).
- Die Dashcam nimmt höchstens `maxSteal` deiner Frames. Bei 120 fps bleiben dir etwa 100–105 fps. Bei niedriger Bildrate sinkt eher die Monitor-FPS als dein Bild.
- Flackern HUD-Elemente, hilft `hideHud = 'off'`. Die Bildränder, an denen das HUD sitzt, schneidet der Monitor ohnehin ab.

## Konfiguration

Alle Optionen stehen kommentiert in der `config.lua`. Die wichtigsten:

| Option | Bedeutung |
|---|---|
| `Config.Locale` | `de` (PolDash) oder `en` (PoliceDash) |
| `Config.Framework` | `auto`, `esx`, `qb`, `qbox`, `standalone` |
| `Config.Jobs` | Job = Mindestrang, z.B. `{ police = 0 }` |
| `Config.AcePermission` | ACE, die immer zusätzlich Zugriff gibt (`policedash.use`) |
| `Config.Vehicles` | Modelle mit Kamera-Offset (und optional `fov`), zusätzlich Klasse 18 bei `AllowEmergencyClass` |
| `Config.CamAttach` | `hard` (ruhig, ab Build 2189) oder `script` |
| `Config.Units` | `kmh` oder `mph` |
| `Config.Tolerance` | Abzug unter 100 km/h (absolut) und ab 100 km/h (Prozent) |
| `Config.FunMode` | großzügigere Prüfungen |
| `Config.PiP` | Bild-im-Bild: `liveMode`, `monitorFps`, `idleFps`, `maxSteal`, `hideHud`, … |
| `Config.Sync` | Beifahrer-Bedienung |
| `Config.Overlay` | Farbe, Uhr (`ingame`/`real`), Größe, Kennung im OSD (`brand`) |
| `Config.Evidence` | Foto/Video, Provider `fivemanage`, `discord`, `custom`, `none` |
| `Config.Playback` | Videos im Spiel abspielen: Umkreis, wer zusehen darf |
| `Config.Storage` | Datenbank `auto`/`true`/`false`, Länge der Historie |
| `Config.Export` | HTTP-Export an ein MDT |
| `Config.Server` | Rate-Limit und Grenzen der Plausibilitätsprüfung |

**Kamera-Offset einstellen:** `Config.Debug = true` setzen, ins Fahrzeug steigen, Dashcam an, dann
`/poldash offset 0.0 0.6 0.65 60` ausprobieren. Die passende Config-Zeile erscheint in F8.

## Beweise

| Provider | Ablauf |
|---|---|
| `fivemanage` | Upload an `api.fivemanage.com/api/v3/file` mit `policedash_fivemanage_key` |
| `discord` | Bild hängt direkt am Webhook-Embed. Discord-Anhang-URLs laufen nach einiger Zeit ab, für dauerhafte Links Fivemanage nutzen. |
| `custom` | multipart-POST (Feld `file`) an `Config.Evidence.customUrl`, Header `X-API-Key` = `policedash_upload_key`. Die Antwort muss `url` oder `data.url` enthalten. |

- **Video (`videoSource = 'nui'`, Standard):** nimmt nur die Dashcam mit Einblendung auf, speichert unter `recordings/` und lädt beim Provider hoch.
- **Video (`videoSource = 'screencapture'`):** ganzer Bildschirm über screencapture, nur `fivemanage` oder `custom`.
- Fotos über screencapture (`remoteUpload`) oder screenshot-basic.

## API

Exports, Events und Datensatz-Aufbau stehen in der [englischen README](README.md#api).

## Sicherheit

- Secrets nur per ConVar, nie im Client oder in der `config.lua`
- Jede Server-Aktion prüft die Berechtigung. Submit, Foto und Wiedergabe haben ein Rate-Limit.
- Der Server prüft jede Messung: Höchstgeschwindigkeit, Strecke/Dauer passt zum Messwert (±15 %), Position des Spielers, Sitz im Fahrzeug.
- Toleranz und vorwerfbarer Wert werden serverseitig neu berechnet.
- SQL nur mit Platzhaltern. Das NUI setzt Texte ausschließlich per `textContent`.

## Bekannte Einschränkungen (Alpha)

- Bild-im-Bild kostet etwas Bildrate im eigenen Bild und bringt etwa einen Frame Verzögerung (`fillGaps`). Bei schneller Bewegung kann es noch leicht ruckeln.
- Videos mit `videoSource = 'nui'` kommen erst nach dem Discord-Embed an. Sie stehen in der Datenbank und in der Wiedergabe, aber nicht im Embed.
- Getestet auf ESX Legacy. QBCore, Qbox und Standalone sind eingebaut, aber noch nicht auf einem Live-Server getestet.

## Update-Check

In der `fxmanifest.lua` ist `policedash_repo` auf `Kargobob1/policedash` gesetzt. Beim Start wird das neueste GitHub-Release mit der installierten Version verglichen (Vorabversionen wie `0.1.0-alpha` gelten als älter als `0.1.0`). Abschalten mit `Config.VersionCheck = false`.

## Lizenz und Nennung

Kostenlos nutzbar, auch auf monetarisierten Servern. Weiterverkauf ist nicht erlaubt. Siehe [LICENSE](LICENSE).

**Nennpflicht:** Wer PolDash einsetzt (verändert oder nicht), nennt es dort, wo der Server seine Credits oder Scripts
aufführt (Credits-Seite, Website, Discord oder Forum-Post):

```
PoliceDash by Kargobob1/Excurse - https://github.com/Kargobob1/policedash
```

Namen und Branding im Spiel dürfen angepasst werden.
