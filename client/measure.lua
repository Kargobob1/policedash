-- Gemeinsamer Messablauf: Modus-Verwaltung, Bedienaktionen, Ergebnis + Toleranz, Ergebnis-Karte.
-- Modi melden sich per Measure.register(name, { trigger, stop, cancel }) an.
Measure = {
    modes   = {},
    order   = {},
    running = nil,   -- Name des laufenden Modus
}

function Measure.register(name, mode)
    Measure.modes[name] = mode
    Measure.order[#Measure.order + 1] = name
end

local function getLocation(vehicle)
    local c = GetEntityCoords(vehicle)
    local streetHash, crossingHash = GetStreetNameAtCoord(c.x, c.y, c.z)
    return {
        street   = GetStreetNameFromHashKey(streetHash),
        crossing = crossingHash ~= 0 and GetStreetNameFromHashKey(crossingHash) or nil,
        zone     = GetLabelText(GetNameOfZone(c.x, c.y, c.z)),
        coords   = { x = Utils.round(c.x, 2), y = Utils.round(c.y, 2), z = Utils.round(c.z, 2) },
    }
end

local function getOwnVehicle(vehicle)
    return {
        model = GetDisplayNameFromVehicleModel(GetEntityModel(vehicle)):lower(),
        plate = Utils.trim(GetVehicleNumberPlateText(vehicle)),
    }
end

-- ---------- Fahrspur fuer die Mini-Map ----------
-- Positionen von Streifenwagen und Ziel, relativ zum Startpunkt, 2D, 5x pro Sekunde.
-- Punkt: { ms seit Start, eigenX, eigenY, zielX?, zielY? }

local TRACK_INTERVAL = 200
local TRACK_MAX = 650

function Measure.newTrack(origin)
    return { origin = { x = Utils.round(origin.x, 1), y = Utils.round(origin.y, 1) }, points = {}, lastAt = -TRACK_INTERVAL }
end

function Measure.trackPoint(track, elapsedMs, own, target)
    if not track or elapsedMs - track.lastAt < TRACK_INTERVAL or #track.points >= TRACK_MAX then return end
    track.lastAt = elapsedMs
    local o = track.origin
    local point = { math.floor(elapsedMs), Utils.round(own.x - o.x, 1), Utils.round(own.y - o.y, 1) }
    if target then
        point[4] = Utils.round(target.x - o.x, 1)
        point[5] = Utils.round(target.y - o.y, 1)
    end
    track.points[#track.points + 1] = point
end

-- marks: { start = vec, finish = vec } (VASCAR), als relative 2D-Punkte
function Measure.trackData(track, marks)
    if not track then return nil end
    local o = track.origin
    local rel = {}
    for name, pos in pairs(marks or {}) do
        rel[name] = { x = Utils.round(pos.x - o.x, 1), y = Utils.round(pos.y - o.y, 1) }
    end
    return { origin = o, points = track.points, marks = rel }
end

-- Live-Werte fuers OSD (W = Messweg, Z = Messzeit; nil = Platzhalter)
function Measure.sendLive(value, duration, running, distance)
    NUI.send('overlay:measure', { value = value, duration = duration, running = running, distance = distance })
end

-- Videoaufnahme: 'nui' nimmt die Dashcam selbst mit eingebranntem OSD auf,
-- 'screencapture' laesst den Server ueber screencapture aufnehmen.
local function videoSource()
    return Config.Evidence.video and Config.Evidence.videoSource or nil
end

-- Nachlauf, in dem das Bild-im-Bild nach der Messung noch live bleibt (Ergebnis G + Video-Ende)
local function liveTail()
    return (videoSource() == 'nui' and Config.Evidence.videoTail or 0) + 1
end

function Measure.started()
    if PiP and PiP.active then PiP.measureLive(true) end
    local source = videoSource()
    if source == 'nui' then
        NUI.send('rec:start', { maxSeconds = Config.Evidence.videoMaxSeconds, bitrate = Config.Evidence.videoBitrate })
    elseif source == 'screencapture' then
        TriggerServerEvent('policedash:server:measureStarted')
    end
end

local function aborted()
    if PiP and PiP.active then PiP.measureLive(false, 1) end
    local source = videoSource()
    if source == 'nui' then
        NUI.send('rec:abort')
    elseif source == 'screencapture' then
        TriggerServerEvent('policedash:server:measureAborted')
    end
end

-- An den Server senden; der prueft, vergibt ID/Zeitstempel und liefert den finalen Datensatz
local function submit(result)
    local response = Callback.await('submit', 15000, result)
    if not response or not response.ok then
        Notify(_L(response and 'submit_rejected' or 'submit_timeout'), 'error')
        aborted()
        return
    end

    local record = response.record
    State.lastMeasurement = record
    History.add(record)
    NUI.send('result:id', { id = record.id })
    -- Aufnahme laeuft noch einige Sekunden weiter, damit G (das Ergebnis) im Video steht
    if PiP and PiP.active then PiP.measureLive(false, liveTail()) end
    if videoSource() == 'nui' then
        NUI.send('rec:finish', { id = record.id, tail = Config.Evidence.videoTail })
    end
    TriggerEvent('policedash:client:measurementDone', record)
end

-- Gueltige Messung. data: { mode, measured, duration, distance, target?, ... }
function Measure.finish(data)
    local vehicle = State.vehicle
    local chargeable, tolerance = Utils.applyTolerance(data.measured)

    local result = data
    result.valid      = true
    result.unit       = Config.Units
    result.tolerance  = tolerance
    result.chargeable = chargeable
    result.vehicle    = getOwnVehicle(vehicle)
    result.location   = getLocation(vehicle)

    Measure.sendLive(result.measured, result.duration, false, result.distance)
    NUI.send('result', result)
    Utils.debug(('measurement %s: %.1f -> %d'):format(result.mode, result.measured, chargeable))
    CreateThread(function() submit(result) end)
end

-- Ungueltige Messung mit verstaendlichem Grund
function Measure.fail(mode, reasonKey, ...)
    aborted()
    Measure.sendLive(nil, nil, false)
    NUI.send('result', { valid = false, mode = mode, reason = _L(reasonKey, ...) })
end

function Measure.cancel(notify)
    local mode = Measure.running and Measure.modes[Measure.running]
    if not mode then return end
    mode.cancel()
    Measure.running = nil
    aborted()
    Measure.sendLive(nil, nil, false)
    if notify then Notify(_L('measure_cancelled'), 'warning') end
end

local function requireCam()
    if DeviceActive() then return true end
    Notify(_L('cam_required'), 'error')
    return false
end

-- Start/Stop-Taste: Bedeutung haengt vom Modus ab (MAN: Start/Stop, VASCAR: Start-/Endpunkt)
Actions.startStop = function()
    if not requireCam() then return end
    local mode = Measure.modes[State.mode]
    if not mode then
        Notify(_L('not_implemented'), 'info')
        return
    end
    NUI.send('result', nil)
    mode.trigger()
end

Actions.stop = function()
    local mode = Measure.running and Measure.modes[Measure.running]
    if mode then mode.stop() end
end

Actions.mode = function()
    if Measure.running then
        Notify(_L('measure_running'), 'error')
        return
    end
    local order = Measure.order
    local index = 1
    for i, name in ipairs(order) do
        if name == State.mode then index = i % #order + 1 end
    end
    State.mode = order[index]
    NUI.send('overlay:update', { mode = State.mode })
    if Sync then Sync.modeChanged() end
    Notify(_L('mode_changed', _L('mode_' .. State.mode)), 'info')
end

Actions.reset = function()
    Measure.cancel(false)
    NUI.send('result', nil)
end

AddEventHandler('policedash:client:deviceStopped', function()
    Measure.cancel(true)
    NUI.send('result', nil)
end)
