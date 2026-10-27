# Changelog

## [0.1.0-alpha] - 2026-10-25

First public test version. Name: **PoliceDash** (English) / **PolDash** (German).
Erste öffentliche Testversion. Name: **PoliceDash** (englisch) / **PolDash** (deutsch).

### Added / Hinzugefügt
- Windshield dashcam with OSD · Dashcam an der Frontscheibe mit Einblendung
- Picture-in-picture monitor (alpha) · Bild-im-Bild-Monitor (Alpha)
- Target acquisition by cone and line of sight · Zielerfassung per Sichtkegel und Sichtstrahl
- MAN (pacing) with distance check, VASCAR with start/end point and ground marker · MAN mit Abstandsprüfung, Weg-Zeit mit Start-/Endpunkt und Bodenmarkierung
- Tolerance deduction (km/h and mph), result card · Toleranzabzug (km/h und mph), Ergebnis-Karte
- Passenger operation with shared display (OneSync) · Beifahrer-Bedienung mit gemeinsamer Anzeige (OneSync)
- Control panel with history, mini map and personal settings · Bedienteil mit Historie, Mini-Karte und persönlichen Einstellungen
- Evidence photos (screencapture / screenshot-basic) and dashcam video with burned-in OSD · Beweisfotos und Dashcam-Video mit eingebrannter Einblendung
- In-game video playback, privately or for everyone nearby · Videos im Spiel abspielen, allein oder für alle im Umkreis
- Server-side validation, measurement IDs `PV-YYYY-NNNNNN` · Serverseitige Prüfung, Messnummern `PV-JJJJ-NNNNNN`
- oxmysql or KVP storage, Discord webhook, HTTP export to MDT · Speicherung in oxmysql oder KVP, Discord-Webhook, HTTP-Export ans MDT
- Framework bridge for ESX, QBCore, Qbox and standalone (ACE) · Framework-Bridge für ESX, QBCore, Qbox und Standalone (ACE)
- Exports and events, update check via GitHub releases · Exports und Events, Update-Check über GitHub-Releases
- Config check on server start · Prüfung der config.lua beim Serverstart
- Commands `/policedash` and `/poldash` · Befehle `/policedash` und `/poldash`

### Notes / Hinweise
- Picture-in-picture tuning commands require `Config.Debug` · Feinabstimmung des Bild-im-Bild nur mit `Config.Debug`
- Existing test installs (working title, folder `provida-fivem`): the table `provida_measurements` is taken over automatically on first start. ConVars, ACE and the folder name must be changed to `policedash` by hand. Per-player history and settings (client KVP) start empty.
  Bestehende Testinstallationen (Arbeitstitel, Ordner `provida-fivem`): Die Tabelle `provida_measurements` wird beim ersten Start automatisch übernommen. ConVars, ACE und Ordnername von Hand auf `policedash` umstellen. Historie und persönliche Einstellungen der Spieler (Client-KVP) beginnen leer.
