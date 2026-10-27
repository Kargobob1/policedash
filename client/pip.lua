-- Bild-im-Bild (/policedash pip). Standardmaessig nur waehrend einer Messung live (Config.PiP.liveMode).
--
-- FiveM kann keine zweite Kamera parallel rendern. Trick: Das Spiel rendert abwechselnd Frames aus
-- der Spielersicht und aus der Dashcam. Jeder Frame bekommt oben links eine Farbmarke
-- (gruen = Spieler, magenta = Dashcam), die im selben Tick wie die Kamera gesetzt wird und daher
-- garantiert im selben Frame landet. Das NUI (web/pip.js) greift das Spielbild ab, sortiert die
-- Frames anhand der Marke, zeigt Spieler-Frames vollflaechig und Dashcam-Frames im Monitor.
PiP = { active = false }

local cfg = Config.PiP
local UPDATE_INTERVAL = 200
local CONTROL_VEH_EXIT = 75

local MARKER_PLAYER = { 0, 255, 0 }
local MARKER_DASH   = { 255, 0, 255 }

local dashCam, mirrorCam = nil, nil
local pipVehicle = 0
local scriptCamsOn = false
local rawMode = false   -- /policedash pip raw: nur Hook-Test, keine Kamerawechsel
local logging = nil     -- /policedash pip log: { untilAt, ticks, done }

-- Live-Betrieb. Im Standby laeuft kein Kamerawechsel: echtes Spielbild, kein Ruckeln, kein Ton-Problem,
-- der Monitor zeigt das letzte Bild. Live nur waehrend einer Messung (+ Nachlauf), per Taste oder immer.
local manualLive, measureLive, liveUntil = false, false, 0
local viewerMode = false   -- Zuschauer (client/sync.lua): live nur mit Config.Sync.viewerLive oder per Taste

function PiP.isLive()
    if not PiP.active then return false end
    if rawMode or manualLive then return true end
    if viewerMode then
        return Config.Sync.viewerLive and (measureLive or GetGameTimer() < liveUntil)
    end
    return cfg.liveMode == 'always' or measureLive or GetGameTimer() < liveUntil
end

-- Volle Monitor-FPS (Messung + Nachlauf, Taste, Rohtest), sonst die sparsame Dauer-Rate
function PiP.fullRate()
    return rawMode or manualLive or measureLive or GetGameTimer() < liveUntil
end

-- Von measure.lua: an bei Messbeginn, aus mit Nachlauf (damit Ergebnis/Video-Ende noch live sind)
function PiP.measureLive(on, tailSeconds)
    measureLive = on == true
    if not on then liveUntil = GetGameTimer() + (tailSeconds or 0) * 1000 end
end

-- Diagnose: Frame-Nummer als Farbe (r = low byte, g = high byte, b = 128) neben der Marke,
-- damit das NUI weiss, welchen Spielframe es gerade anzeigt
local function drawFrameCounter(n)
    n = n % 65536
    DrawRect(0.013, 0.007, 0.008, 0.014, n % 256, n // 256, 128, 255)
end

local function drawMarker(color)
    -- ~15x15 px bei 1080p, oben links; das NUI deckt die Ecke ab
    DrawRect(0.004, 0.007, 0.008, 0.014, color[1], color[2], color[3], 255)
end

local function setScriptCams(on)
    if scriptCamsOn == on then return end
    scriptCamsOn = on
    RenderScriptCams(on, false, 0, true, true)
end

local function syncDashRotation()
    Camera.followRotation(dashCam, pipVehicle)   -- bei Config.CamAttach 'hard' nichts zu tun
end

-- Methode 'mirror': zweite Skript-Kamera folgt der Gameplay-Kamera, es wird nur zwischen Skript-Kameras gewechselt.
-- mirrorAttach: Die Kamera wird relativ zum Fahrzeug angehaengt statt auf Weltkoordinaten gesetzt. Die
-- Gameplay-Position ist einen Frame alt; als Weltposition wuerde das Auto gegen die Kamera ruckeln,
-- angehaengt rechnet das Spiel die Position im selben Frame wie das Fahrzeug.
--   'prev':    Offset gegen die Fahrzeuglage des VORHERIGEN Frames rechnen (die Gameplay-Position ist auch
--              von dort) -> korrekt; gegen die aktuelle Lage gerechnet waere die Kamera um v*dt zu weit hinten
--   'current': Offset gegen die aktuelle Fahrzeuglage
--   'off':     Weltposition (Auto ruckelt gegen die Kamera)
local lastMatrix = nil   -- { forward, right, up, pos } des Fahrzeugs aus dem vorherigen Frame

local function dot(a, b)
    return a.x * b.x + a.y * b.y + a.z * b.z
end

-- Drehung: Die Gameplay-Drehung ist ebenfalls einen Frame alt. Ans Fahrzeug haengen hilft hier nicht
-- (die Verfolgerkamera neigt sich bewusst NICHT mit dem Auto, relativ zum Auto aendert sie sich bei
-- Bodenwellen also schnell). Stattdessen einen Frame vorausschaetzen: rot + (rot - vorherige rot) * mirrorPredict.
-- Nur fuer die gedaempfte Verfolgerkamera sinnvoll. Im Test (2026-10-25) ruckelte es mit Mausbewegung
-- deutlich (Mauseingaben kommen stufig, die Schaetzung verstaerkt die Stufen) -> Standard aus.
-- Spruenge (Kamera-Schnitt, Rueckblick) werden nicht vorausgeschaetzt.
local MAX_PREDICT_DEG = 8.0
local lastGameplayRot = nil

local function wrapDeg(a)
    return (a + 180.0) % 360.0 - 180.0
end

local function predictRotation(rot)
    local k = cfg.mirrorPredict or 0
    local last = lastGameplayRot
    lastGameplayRot = rot
    if k <= 0 or not last then return rot end
    local dx, dz = wrapDeg(rot.x - last.x), wrapDeg(rot.z - last.z)
    if math.abs(dx) > MAX_PREDICT_DEG or math.abs(dz) > MAX_PREDICT_DEG then return rot end
    return vec3(rot.x + dx * k, rot.y, rot.z + dz * k)
end

local function syncMirror()
    local pos = GetGameplayCamCoord()
    local rot = predictRotation(GetGameplayCamRot(2))
    local forward, right, up, vehPos = GetEntityMatrix(pipVehicle)
    local mode = cfg.mirrorAttach

    if mode == 'prev' and lastMatrix then
        local delta = pos - lastMatrix.pos
        AttachCamToEntity(mirrorCam, pipVehicle, dot(delta, lastMatrix.right), dot(delta, lastMatrix.forward), dot(delta, lastMatrix.up), true)
    elseif mode == 'prev' or mode == 'current' then
        local offset = GetOffsetFromEntityGivenWorldCoords(pipVehicle, pos.x, pos.y, pos.z)
        AttachCamToEntity(mirrorCam, pipVehicle, offset.x, offset.y, offset.z, true)
    else
        DetachCam(mirrorCam)
        SetCamCoord(mirrorCam, pos.x, pos.y, pos.z)
    end
    lastMatrix = { forward = forward, right = right, up = up, pos = vehPos }

    SetCamRot(mirrorCam, rot.x, rot.y, rot.z, 2)
    SetCamFov(mirrorCam, GetGameplayCamFov())
end

-- Auch im Standby mitfuehren, damit der erste Live-Frame schon den richtigen Vorframe kennt
local function trackVehicle()
    local forward, right, up, vehPos = GetEntityMatrix(pipVehicle)
    lastMatrix = { forward = forward, right = right, up = up, pos = vehPos }
end

local function shouldAbort(ped)
    return not DoesEntityExist(pipVehicle)
        or GetVehiclePedIsIn(ped, false) ~= pipVehicle
        or IsEntityDead(ped)
        or IsControlJustPressed(0, CONTROL_VEH_EXIT)
end

-- Jeder Dashcam-Frame fehlt im Hauptbild (ein Bild steht doppelt so lange, danach springt das Auto).
-- Der Monitor zielt auf eine Bildrate:
--   Messung/Taste: cfg.monitorFps, Dauerbetrieb (liveMode 'always') ausserhalb: cfg.idleFps.
-- Takt: jeder N-te Frame. N wird nur einmal pro Sekunde (und beim Wechsel Messung/Dauerbetrieb) neu
-- bestimmt. Springt N zwischen zwei Werten (z.B. 6/7), werden die Abstaende der Dashcam-Bilder ungleich
-- und es ruckelt im Monitor und im Video. Ein fester Zeittakt waere schlechter (simuliert: Frames
-- abwechselnd 6/7 auseinander), ein festes N gibt exakt gleiche Abstaende in Frames.
-- Obergrenze: Die Dashcam darf hoechstens cfg.maxSteal Anteil der Frames nehmen. Bei niedriger
-- Bildrate sinkt dann lieber die Monitor-FPS, statt das Hauptbild zu halbieren.
-- Das NUI sieht nicht jeden Spielframe (Logs: ~20 % gehen verloren, Spiel und CEF sind nicht synchron).
-- Es meldet, wie viele Dashcam-Frames ankamen ('pipRate'); der Ausfall wird ausgeglichen (innerhalb der Obergrenze).
local MIN_EVERY, MAX_EVERY = 2, 60
local MAX_STEAL = { idle = 0.08, measure = 0.25 }
local RECALC_INTERVAL = 1000

local seenRatio = 1.0          -- Anteil der Dashcam-Frames, die das NUI erreicht (geglaettet)
local emittedSinceReport = 0
local avgFrameMs = 1000 / 60
local dashEvery, dashEveryFull, recalcAt = 4, nil, 0

-- Hysterese: N bleibt, solange der exakte Wert weniger als 0,75 daneben liegt. Sonst kippt N an
-- Rundungsgrenzen hin und her (Log 2026-10-25: 100 fps / 15 = 6,67 -> 6 und 7 im Wechsel).
local HYSTERESIS = 0.75

local function computeEvery(full, current)
    local fps = 1000 / math.max(avgFrameMs, 1)
    local steal = cfg.maxSteal or MAX_STEAL
    local maxShare = math.max((full and steal.measure or steal.idle) or 0.25, 0.01)
    local target = full and cfg.monitorFps or (cfg.idleFps or 4)
    local exact = math.max(fps * seenRatio / math.max(target, 1), math.ceil(1 / maxShare))
    local every = math.floor(exact + 0.5)
    if current and math.abs(exact - current) < HYSTERESIS and current >= math.ceil(1 / maxShare) then
        every = current
    end
    return math.min(MAX_EVERY, math.max(MIN_EVERY, every))
end

local function dashDue(now, sinceDash)
    local full = PiP.fullRate() == true
    if now >= recalcAt or full ~= dashEveryFull then
        -- beim Wechsel Messung/Dauerbetrieb ohne Hysterese neu bestimmen (andere Ziel-FPS)
        local current = full == dashEveryFull and dashEvery or nil
        dashEvery, dashEveryFull, recalcAt = computeEvery(full, current), full, now + RECALC_INTERVAL
    end
    return sinceDash >= dashEvery
end

RegisterNUICallback('pipRate', function(data, cb)
    cb('ok')
    local seen = type(data) == 'table' and tonumber(data.dash)
    local emitted = emittedSinceReport
    emittedSinceReport = 0                                  -- gleiches Fenster wie das NUI
    if not seen or emitted < 3 then return end              -- zu wenig fuer eine Aussage
    local ratio = math.min(1.0, math.max(0.3, seen / emitted))
    seenRatio = seenRatio * 0.6 + ratio * 0.4
end)

-- Hoerer wieder dem Spiel ueberlassen (nach 'pin')
local function releaseMicrophone()
    local p = GetGameplayCamCoord()
    SetMicrophonePosition(false, p.x, p.y, p.z, p.x, p.y, p.z, p.x, p.y, p.z)
end

local function standby()
    releaseMicrophone()
    setScriptCams(false)
    if dashCam then SetCamActive(dashCam, false) end
    if mirrorCam then SetCamActive(mirrorCam, false) end
end

-- Umschalten ohne Flackern (Handshake mit dem NUI):
--   standby -> warmup:   nur Spielersicht (Spiegelkamera), NUI baut die Kopie auf und meldet 'pipReady'
--   warmup  -> live:     erst jetzt kommen Dashcam-Frames
--   live    -> cooldown: keine Dashcam-Frames mehr, NUI blendet die Kopie aus und meldet 'pipHidden'
--   cooldown -> standby: erst jetzt zurueck auf die echte Spielkamera
local HANDSHAKE_TIMEOUT = 600   -- ms, falls das NUI nicht antwortet
local nuiReady, nuiHidden = false, false

RegisterNUICallback('pipReady', function(_, cb) nuiReady = true; cb('ok') end)
RegisterNUICallback('pipHidden', function(_, cb) nuiHidden = true; cb('ok') end)

local function tick()
    local frame, nextUpdate = 0, 0
    local history = {}   -- frame -> isDash, fuer den Marken-Versatz
    local sinceDash = 0
    local phase, phaseSince = 'standby', 0

    while PiP.active do
        if shouldAbort(PlayerPedId()) then
            PiP.stop()
            break
        end

        local now = GetGameTimer()
        if now >= nextUpdate then
            nextUpdate = now + UPDATE_INTERVAL
            NUI.deviceUpdate(pipVehicle)
        end

        local wantLive = PiP.isLive()
        if wantLive and (phase == 'standby' or phase == 'cooldown') then
            phase, phaseSince, nuiReady = 'warmup', now, false
            history, sinceDash, emittedSinceReport = {}, 0, 0
            recalcAt, lastGameplayRot = 0, nil
            NUI.send('pip:live', { on = true })
        elseif not wantLive and (phase == 'live' or phase == 'warmup') then
            phase, phaseSince, nuiHidden = 'cooldown', now, false
            NUI.send('pip:live', { on = false })
        end
        if phase == 'warmup' and (nuiReady or now - phaseSince > HANDSHAKE_TIMEOUT) then
            phase = 'live'
        elseif phase == 'cooldown' and (nuiHidden or now - phaseSince > HANDSHAKE_TIMEOUT) then
            phase = 'standby'
            standby()
        end

        -- auch im Standby messen, damit N beim Live-Start gleich stimmt
        avgFrameMs = avgFrameMs * 0.95 + GetFrameTime() * 1000 * 0.05
        if phase == 'standby' then trackVehicle() end
        if phase ~= 'standby' then
            frame = frame + 1
            sinceDash = sinceDash + 1
            local isDash = phase == 'live' and not rawMode and dashDue(now, sinceDash)
            if isDash then
                sinceDash = 0
                emittedSinceReport = emittedSinceReport + 1
            end
            history[frame] = isDash
            history[frame - 10] = nil

            -- Kamerawechsel wirken ggf. erst N Frames spaeter, die Marke sofort:
            -- die Marke beschreibt daher die Kamera von vor N Frames.
            local shownDash = history[frame - (cfg.markerDelay[cfg.method] or 0)] == true

            if rawMode then
                -- keine Kamerawechsel
            elseif cfg.method == 'mirror' then
                syncMirror()
                if isDash then syncDashRotation() end
                SetCamActive(dashCam, isDash)
                SetCamActive(mirrorCam, not isDash)
                setScriptCams(true)
            elseif isDash then
                syncDashRotation()
                setScriptCams(true)
            else
                setScriptCams(false)
            end

            if cfg.hideHud == 'always' or (shownDash and cfg.hideHud == 'dash') then HideHudAndRadarThisFrame() end
            -- Audio-Hoerer haengt an der aktiven Kamera. Springt er jeden Frame zwischen Spielersicht und
            -- Frontscheibe, entsteht Doppler (Sirenen zu hoch). 'pin': Hoerer jeden Frame fest auf die
            -- Spielerkamera setzen (wie Rockstars Missionsskripte), 'freeze': nur Dashcam-Frames einfrieren.
            if cfg.audioFix == 'pin' then
                local p = GetGameplayCamCoord()
                SetMicrophonePosition(true, p.x, p.y, p.z, p.x, p.y, p.z, p.x, p.y, p.z)
            elseif cfg.audioFix == 'freeze' and shownDash then
                FreezeMicrophone()
            end

            if logging and not logging.done then
                drawFrameCounter(frame)
                local ticks = logging.ticks
                ticks[#ticks + 1] = { frame % 65536, GetGameTimer(), Utils.round(GetFrameTime() * 1000, 2), isDash and 1 or 0, shownDash and 1 or 0 }
                if GetGameTimer() >= logging.untilAt then logging.done = true end
            end
            drawMarker(shownDash and MARKER_DASH or MARKER_PLAYER)
        end
        Wait(0)
    end
end

local function release()
    releaseMicrophone()
    setScriptCams(false)
    for _, cam in ipairs({ dashCam, mirrorCam }) do
        if cam then DestroyCam(cam, false) end
    end
    dashCam, mirrorCam = nil, nil
end

function PiP.start(raw, viewer)
    if PiP.active or not State.eligible then return end
    if State.camActive then Camera.stop() end
    rawMode = raw == true
    viewerMode = viewer == true

    pipVehicle = State.vehicle
    dashCam = CreateCam('DEFAULT_SCRIPTED_CAMERA', false)
    Camera.attachTo(dashCam, pipVehicle)
    -- Bewegungsunschaerfe gegen das "Daumenkino" bei 15 FPS und hohem Tempo (Test, Standard aus)
    if (cfg.dashMotionBlur or 0) > 0 then SetCamMotionBlurStrength(dashCam, cfg.dashMotionBlur) end
    if cfg.method == 'mirror' then
        mirrorCam = CreateCam('DEFAULT_SCRIPTED_CAMERA', false)
    end

    PiP.active = true
    manualLive, measureLive, liveUntil = false, false, 0
    NUI.deviceStart('pip', { stats = cfg.showStats, raw = rawMode, fill = cfg.fillGaps })
    NUI.deviceUpdate(pipVehicle)
    CreateThread(tick)
end

function PiP.stop()
    if not PiP.active then return end
    PiP.active = false
    release()
    pipVehicle = 0
    NUI.deviceStop()
    if viewerMode then
        viewerMode = false
        State.viewer = nil   -- nach deviceStop, damit sync.lua das Aus nicht als Bediener meldet
    end
end

-- Monitor manuell live schalten (z.B. beim Hinterherfahren vor der Messung)
function PiP.toggleLive()
    if not PiP.active then return end
    manualLive = not manualLive
    Notify(_L(manualLive and 'pip_live_on' or 'pip_live_off'), 'info')
end

RegisterCommand('policedash_piplive', function() PiP.toggleLive() end, false)
RegisterKeyMapping('policedash_piplive', _L('key_pip_live'), 'keyboard', Config.Keys.pipLive)

-- Fuer alle (mit Berechtigung):
-- /policedash pip                   Bild-im-Bild ein/aus
-- /policedash pip live              Monitor manuell live/standby
-- /policedash pip fps <10-24>       Dashcam-FPS (Monitor + Video), gespeichert wie im Bedienteil
--
-- Nur mit Config.Debug (Feinabstimmung und Diagnose):
-- /policedash pip raw               Hook-Test ohne Kamerawechsel
-- /policedash pip audio pin|freeze|off   Gegenmittel gegen verzerrten Ton (live)
-- /policedash pip delay <0-3>       Marken-Versatz live aendern
-- /policedash pip method toggle|mirror
-- /policedash pip hud dash|always|off
-- /policedash pip log [Sekunden]    Diagnose aufzeichnen, Datei landet auf dem Server unter logs/
-- /policedash pip fill              Lueckenfuellung im Hauptbild ein/aus (live)
-- /policedash pip attach [prev|current|off]   Kamera-Anbindung durchschalten (live)
-- /policedash pip stats             Diagnosezeile ein/aus (beim naechsten Start)
-- /policedash pip cam [hard|script] Dashcam-Anbindung (live)
-- /policedash pip predict <0-1.5>   Vorausschaetzung der Spielerkamera-Drehung (live, 0 = aus)
-- /policedash pip blur <0-1>        Bewegungsunschaerfe der Dashcam (live, 0 = aus)
local DEBUG_SUBS = {
    raw = true, audio = true, log = true, fill = true, attach = true, stats = true,
    cam = true, predict = true, blur = true, hud = true, delay = true, method = true,
}

Subcommands.pip = function(args)
    local sub = args[1]
    if DEBUG_SUBS[sub] and not Config.Debug then
        Notify(_L('debug_only'), 'error')
        return
    end
    if sub == 'live' then
        PiP.toggleLive()
        return
    elseif sub == 'audio' then
        if args[2] == 'pin' or args[2] == 'freeze' or args[2] == 'off' then
            if cfg.audioFix == 'pin' and args[2] ~= 'pin' then releaseMicrophone() end
            cfg.audioFix = args[2]
            Notify('PiP audioFix = ' .. cfg.audioFix, 'info')
        end
        return
    elseif sub == 'log' then
        if not PiP.active then
            Notify('PiP zuerst mit /policedash pip starten.', 'error')
            return
        end
        local seconds = math.min(30, math.max(3, tonumber(args[2]) or 10))
        logging = { untilAt = GetGameTimer() + seconds * 1000, ticks = {} }
        NUI.send('pip:log', { seconds = seconds })
        Notify(('PiP-Log laeuft %d s - normal weiterfahren ...'):format(seconds), 'info')
        return
    elseif sub == 'fill' then
        cfg.fillGaps = not cfg.fillGaps
        NUI.send('pip:fill', { on = cfg.fillGaps })
        Notify('PiP fillGaps = ' .. tostring(cfg.fillGaps), 'info')
        return
    elseif sub == 'attach' then
        local nextMode = { prev = 'current', current = 'off', off = 'prev' }
        cfg.mirrorAttach = args[2] and nextMode[args[2]] and args[2] or nextMode[cfg.mirrorAttach] or 'prev'
        lastMatrix = nil
        Notify('PiP mirrorAttach = ' .. cfg.mirrorAttach, 'info')
        return
    elseif sub == 'stats' then
        cfg.showStats = not cfg.showStats
        Notify('PiP showStats = ' .. tostring(cfg.showStats), 'info')
        return
    elseif sub == 'fps' then
        local fps = ClampDashFps(args[2])
        if fps then
            local settings = Settings.set({ dashFps = fps })   -- speichert und setzt cfg.monitorFps
            NUI.send('settings', settings)
            Notify(_L('dash_fps_set', settings.dashFps), 'info')
        else
            Notify(_L('dash_fps_usage', DASH_FPS_MIN, DASH_FPS_MAX), 'error')
        end
        return
    elseif sub == 'cam' then
        -- Dashcam-Anbindung live umschalten: hard | script
        Config.CamAttach = (args[2] == 'hard' or args[2] == 'script') and args[2]
            or (Config.CamAttach == 'script' and 'hard' or 'script')
        if PiP.active and dashCam then Camera.attachTo(dashCam, pipVehicle) end
        Notify('CamAttach = ' .. Config.CamAttach, 'info')
        return
    elseif sub == 'predict' then
        local k = tonumber(args[2])
        if k and k >= 0 and k <= 1.5 then cfg.mirrorPredict = k end
        lastGameplayRot = nil
        Notify('PiP mirrorPredict = ' .. tostring(cfg.mirrorPredict or 0), 'info')
        return
    elseif sub == 'blur' then
        local strength = tonumber(args[2])
        if strength and strength >= 0 and strength <= 1 then
            cfg.dashMotionBlur = strength
            if PiP.active and dashCam then SetCamMotionBlurStrength(dashCam, strength) end
        end
        Notify('PiP dashMotionBlur = ' .. tostring(cfg.dashMotionBlur or 0), 'info')
        return
    elseif sub == 'hud' then
        if args[2] == 'dash' or args[2] == 'always' or args[2] == 'off' then
            cfg.hideHud = args[2]
            Notify('PiP hideHud = ' .. cfg.hideHud, 'info')
        end
        return
    elseif sub == 'delay' then
        local n = tonumber(args[2])
        if n and n >= 0 and n <= 3 then
            cfg.markerDelay[cfg.method] = math.floor(n)
            Notify(('PiP markerDelay (%s) = %d'):format(cfg.method, cfg.markerDelay[cfg.method]), 'info')
        end
        return
    elseif sub == 'method' then
        if args[2] == 'toggle' or args[2] == 'mirror' then
            local wasActive = PiP.active
            if wasActive then PiP.stop() end
            cfg.method = args[2]
            Notify('PiP method = ' .. cfg.method, 'info')
            if wasActive then PiP.start() end
        end
        return
    end

    if sub and sub ~= 'raw' then
        Notify(_L('pip_usage'), 'error')
        return
    end
    CreateThread(function()
        if not PiP.active and not CanUse() then return end
        if PiP.active then PiP.stop() else PiP.start(sub == 'raw') end
    end)
end

-- NUI liefert seine Messwerte nach Ablauf; zusammen mit den Lua-Werten an den Server
RegisterNUICallback('pipLog', function(data, cb)
    cb('ok')
    if not logging or type(data) ~= 'table' or type(data.entries) ~= 'table' then return end
    local width, height = GetActiveScreenResolution()
    local payload = json.encode({
        meta = {
            method = cfg.method, monitorFps = cfg.monitorFps, markerDelay = cfg.markerDelay[cfg.method],
            mirrorAttach = cfg.mirrorAttach, hideHud = cfg.hideHud, fillGaps = cfg.fillGaps, screen = { width, height },
            nui = data.meta,
        },
        lua = logging.ticks,   -- { frame, gameTimer, frameTimeMs, isDash, shownDash }
        nui = data.entries,    -- { performance.now, kind (1 Spieler, 2 Dash, 0 ?), frame (-1 = nicht lesbar) }
    })
    logging = nil
    TriggerLatentServerEvent('policedash:server:pipLog', 200000, payload)
    Notify('PiP-Log wird an den Server geschickt ...', 'info')
end)

RegisterNetEvent('policedash:client:pipLogSaved', function(path)
    Notify('PiP-Log gespeichert: ' .. tostring(path), 'success')
end)

AddEventHandler('policedash:client:eligibilityChanged', function(eligible, vehicle)
    if PiP.active and (not eligible or vehicle ~= pipVehicle) then PiP.stop() end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() and PiP.active then release() end
end)
