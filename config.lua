Config = {}

Config.Locale    = 'de'         -- de | en
Config.Debug     = false
Config.Framework = 'auto'       -- auto | esx | qb | qbox | standalone
Config.Units     = 'kmh'        -- kmh | mph

-- Optionale Integrationen: true = nutzen, falls die Resource gestartet ist
Config.Integrations = {
    oxLib = true,               -- Notifications ueber ox_lib statt NUI
}

-- Berechtigung
Config.Jobs          = { police = 0, sheriff = 0 }   -- job = Mindestrang
Config.RequireOnDuty = false                         -- nur qb/qbox: Dienststatus pruefen
Config.AcePermission = 'policedash.use'              -- gilt immer zusaetzlich (z.B. Admins, Standalone)
Config.AccessCacheSeconds = 60                       -- Client-Cache fuer die Server-Pruefung
Config.AllowedSeats  = { -1, 0 }                     -- Fahrer und Beifahrer

-- Fahrzeuge: Modell = Kamera-Offset und optional fov.
-- Zusaetzlich alle Emergency-Fahrzeuge (Klasse 18), wenn AllowEmergencyClass = true.
-- Offsets einstellen: Config.Debug = true, dann im Fahrzeug /policedash offset x y z [fov]
Config.Vehicles = {
    police  = { offset = vec3(0.0, 0.6, 0.65) },
    police2 = { offset = vec3(0.0, 0.6, 0.60) },
}
Config.AllowEmergencyClass = true
Config.DefaultCamOffset    = vec3(0.0, 0.6, 0.65)
Config.CamFov              = 60.0
Config.CamAttach           = 'hard'   -- hard: Drehung haengt am Fahrzeug (ruhig) | script: alte Methode (live: /policedash pip cam)
Config.CamTimecycle         = false   -- z.B. 'CAMERA_secuirity' fuer einen Kamera-Look, false = aus
Config.CamTimecycleStrength = 0.4

-- Keybinds (ueber RegisterKeyMapping, vom Spieler in den GTA-Einstellungen aenderbar)
Config.Keys = {
    toggleCam   = 'F7',
    togglePanel = 'F9',
    start       = 'NUMPAD5',
    stop        = 'NUMPAD5',      -- gleiche Taste = Start/Stop toggeln
    mode        = 'NUMPAD8',
    lock        = 'NUMPAD9',
    reset       = 'NUMPAD2',
    photo       = 'NUMPAD0',
    closeVideo  = 'BACK',         -- Videofenster schliessen (Ruecktaste)
    pipLive     = 'NUMPAD7',      -- Bild-im-Bild-Monitor manuell live schalten
}

-- Bild-im-Bild (ALPHA: funktioniert, wird noch verfeinert; /policedash pip)
-- Die 'live:'-Befehle zum Feinabstimmen gehen nur mit Config.Debug = true.
Config.PiP = {
    liveMode     = 'measure', -- measure: Dashcam nur waehrend Messung live (sonst ruckelfrei) | always: dauerhaft live (idleFps, volle FPS bei Messung)
    method       = 'mirror',  -- mirror (zwei Skript-Kameras, empfohlen) | toggle (RenderScriptCams an/aus)
    mirrorAttach = 'prev',    -- mirror: Kamera ans Fahrzeug haengen: prev (empfohlen) | current | off  (live: /policedash pip attach)
    monitorFps   = 15,        -- Standard-Dashcam-FPS (10-24; Monitor + Video). Jeder Spieler kann es im Bedienteil aendern.
    idleFps      = 4,         -- liveMode 'always': Dashcam-FPS ausserhalb einer Messung (sparsam, kaum spuerbar)
    -- Hoechstens dieser Anteil der Spielframes geht an die Dashcam. Reicht das nicht fuer die Ziel-FPS,
    -- sinkt die Monitor-FPS statt des eigenen Bildes (verhindert das Halbieren bei niedriger Bildrate).
    maxSteal     = { idle = 0.08, measure = 0.25 },
    fillGaps     = true,      -- fehlende Frames im Hauptbild ueberblenden statt Stehbild + Sprung, +1 Frame Verzoegerung (live: /policedash pip fill)
    -- Frames, die ein Kamerawechsel verzoegert sichtbar wird, je Methode (live testen: /policedash pip delay N)
    markerDelay  = { mirror = 0, toggle = 1 },
    mirrorPredict = 0.0,      -- mirror: Drehung der Spielerkamera vorausschaetzen, 0 = aus. Mit Maus ruckelt es (getestet); live: /policedash pip predict X
    dashMotionBlur = 0.0,     -- Bewegungsunschaerfe der Dashcam 0-1, TEST (live: /policedash pip blur X)
    audioFix     = 'pin',     -- pin: Audio-Hoerer fest an der Spielerkamera | freeze | off (live: /policedash pip audio X)
    hideHud      = 'dash',    -- dash: HUD nur im Dashcam-Bild aus | off: nie ausblenden (kein HUD-Flackern, Rand wird im
                              -- Monitor ohnehin abgeschnitten) | always: HUD waehrend PiP ganz aus (live: /policedash pip hud X)
    showStats    = false,     -- Diagnosezeile unter dem Monitor (kostet etwas Leistung)
}

-- Beifahrer-Bedienung: Wer das Geraet einschaltet, bedient es; andere Insassen auf erlaubten Sitzen
-- (Config.AllowedSeats) sehen dieselbe Anzeige. Braucht OneSync.
Config.Sync = {
    enabled    = true,
    viewerLive = false,   -- Monitor des Zuschauers waehrend der Messung auch live (ruckelt dann bei ihm, z.B. beim Fahrer)
}

-- Overlay / NUI
Config.Overlay = {
    theme    = 'white',         -- white (weiss/schwarz) | green (gruen/schwarz)
    clock    = 'ingame',        -- ingame | real
    scale    = 1.0,
    brand    = nil,             -- Kennung unten rechts im OSD (z.B. Servername), nil = PoliceDash / PolDash je nach Sprache
    zoom     = '01',            -- Zoomkennzahl oben rechts im OSD
    resultSeconds = 8,          -- Ergebnis-Karte nach der Messung einblenden
}
-- theme und scale kann jeder Spieler im Bedienteil fuer sich aendern.

-- Bedienteil
Config.Panel = {
    sounds = true,              -- Klickgeraeusche (per Spieler abschaltbar)
    volume = 0.4,
}

-- Toleranz
Config.Tolerance = {
    under100Kmh = 3,     -- km/h Abzug unter 100
    overPercent = 3,     -- % Abzug ab 100
    roundDown   = true,
}
Config.FunMode = true    -- grosszuegigere Pruefungen

-- Modus Nachfahren
Config.MAN = {
    minDuration   = 3.0,    -- Sekunden
    maxDuration   = 120.0,
    minDistance   = 10.0,   -- Meter zum Ziel
    maxDistance   = 80.0,
    maxVariance   = 0.30,   -- erlaubte Abstandsschwankung (30 %)
    sampleRate    = 100,    -- ms
    requireTarget = true,   -- false = reine Eigengeschwindigkeitsmessung
}

-- Modus Weg-Zeit
Config.VASCAR = {
    minTrackLength = 100.0,  -- Meter
    maxTrackLength = 2000.0,
    maxDuration    = 120.0,
    showMarker     = true,   -- Startpunkt als Bodenmarkierung anzeigen
}

-- Zielerfassung
Config.Target = {
    range       = 120.0,
    coneDegrees = 12.0,
}

-- Beweise. Aufnahme und Upload laufen immer serverseitig.
--   fivemanage: Key per ConVar policedash_fivemanage_key
--   discord:    Bild wird mit dem Embed an policedash_discord_webhook geschickt (nur Fotos)
--   custom:     multipart POST (Feld 'file') an customUrl, Key per ConVar policedash_upload_key als X-API-Key
Config.Evidence = {
    screenshot       = true,
    autoScreenshot   = true,         -- Foto automatisch nach jeder gueltigen Messung
    provider         = 'fivemanage', -- fivemanage | discord | custom | none
    customUrl        = '',

    -- Video. 'nui': eigene Aufnahme NUR der Dashcam mit eingebranntem OSD (Bild-im-Bild
    -- oder Vollbild-Dashcam), braucht keine weitere Resource. 'screencapture': ganzer Bildschirm
    -- ueber screencapture (nur fivemanage/custom).
    video            = true,
    videoSource      = 'nui',        -- nui | screencapture
    videoMaxSeconds  = 30,
    videoTail        = 4,            -- Sekunden nach dem Ergebnis weiter aufnehmen (G im Bild)
    videoBitrate     = 2500000,      -- bit/s (960x720)
    videoLocal       = true,         -- zusaetzlich im Resource-Ordner unter recordings/ speichern
    videoMaxMB       = 25,
    videoChunkSize   = 262144,       -- Zeichen pro Uebertragungsstueck (Base64)
    videoBps         = 500000,       -- Bandbreite der Uebertragung zum Server (Byte/s)
}

-- Messvideos im Spiel abspielen (/policedash play <Nr>, /policedash show [Nr], Bedienteil -> Historie)
Config.Playback = {
    radius     = 8.0,       -- Vorfuehren: alle Spieler in diesem Umkreis (Meter, braucht OneSync)
    viewJobs   = { police = 0, sheriff = 0, judge = 0, lawyer = 0 },   -- duerfen per Messnummer abrufen
    viewAce    = 'policedash.view',
    cooldown   = 5,         -- Sekunden zwischen zwei Abrufen pro Spieler
    bps        = 500000,    -- Bandbreite beim Streamen lokaler Videos (Byte/s je Zuschauer)
    closeAfter = 8,         -- Fenster schliesst sich so viele Sekunden nach Videoende
}

-- Discord-Protokoll (Webhook per ConVar policedash_discord_webhook)
Config.Discord = {
    enabled  = true,
    username = nil,          -- nil = PoliceDash / PolDash je nach Sprache
    color    = 0xF2F2F2,
}

-- Serverseitige Plausibilitaetspruefung
Config.Server = {
    submitCooldown       = 3,      -- Sekunden zwischen zwei Messungen pro Spieler
    photoCooldown        = 10,
    maxSpeedKmh          = 400,
    consistencyTolerance = 0.15,   -- Strecke/Dauer muss zum Messwert passen (±15 %)
    maxReportDistance    = 500.0,  -- Meter zwischen Spieler und gemeldeter Position
    logRejected          = true,   -- verworfene Messungen in der Konsole loggen
}

-- Speicherung
Config.Storage = {
    database   = 'auto',  -- auto | true | false
    kvpHistory = 20,      -- letzte X Messungen lokal
}

-- Export an MDT / externe API
Config.Export = {
    enabled = false,
    url     = '',
    -- API-Key per ConVar: set policedash_export_key "..."
}

Config.VersionCheck = true

-- Secrets NIEMALS hier eintragen, nur per ConVar in der server.cfg:
--   set policedash_fivemanage_key "..."
--   set policedash_discord_webhook "..."
--   set policedash_export_key "..."
