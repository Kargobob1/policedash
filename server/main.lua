-- Server-Hauptlogik: Berechtigung, Messung annehmen + Plausibilitaet, Beweise, Exports, Debug
Bridge.load()

local RESOURCE = GetCurrentResourceName()
local VERSION = GetResourceMetadata(RESOURCE, 'version', 0) or '?'
local OPTIONAL_RESOURCES = { 'ox_lib', 'oxmysql', 'screencapture', 'screenshot-basic' }
local ONESYNC = GetConvar('onesync', 'off') ~= 'off'
local MODES = { MAN = true, VASCAR = true }
local EVIDENCE_TIMEOUT = 60000

local lastRecord = {}                                  -- src -> zuletzt angenommene Messung
local recentRecords = {}                               -- src -> letzte Messungen (Video-Upload kann laenger dauern)
local RECENT_RECORDS = 3
local cooldowns = { submit = {}, start = {}, photo = {}, play = {}, log = {}, hello = {} }
local syncWindow = {}                                  -- src -> { start, count } (Beifahrer-Sync, siehe unten)

CreateThread(Storage.init)

-- Tippfehler in der config.lua fallen sonst erst im Spiel auf (oder gar nicht)
local function validateConfig()
    local function check(path, value, allowed)
        for _, option in ipairs(allowed) do
            if value == option then return end
        end
        print(('^3[policedash] Config %s = %s ist ungueltig, erlaubt: %s^0'):format(
            path, tostring(value), table.concat(allowed, ', ')))
    end
    check('Locale', Config.Locale, { 'de', 'en' })
    check('Framework', Config.Framework, { 'auto', 'esx', 'qb', 'qbox', 'standalone' })
    check('Units', Config.Units, { 'kmh', 'mph' })
    check('CamAttach', Config.CamAttach, { 'hard', 'script' })
    check('Overlay.theme', Config.Overlay.theme, { 'white', 'green' })
    check('Overlay.clock', Config.Overlay.clock, { 'ingame', 'real' })
    check('Evidence.provider', Config.Evidence.provider, { 'fivemanage', 'discord', 'custom', 'none' })
    check('Evidence.videoSource', Config.Evidence.videoSource, { 'nui', 'screencapture' })
    check('PiP.liveMode', Config.PiP.liveMode, { 'measure', 'always' })
    check('PiP.method', Config.PiP.method, { 'mirror', 'toggle' })
    check('PiP.hideHud', Config.PiP.hideHud, { 'dash', 'always', 'off' })
    check('PiP.audioFix', Config.PiP.audioFix, { 'pin', 'freeze', 'off' })
    check('Storage.database', Config.Storage.database, { 'auto', true, false })
    if Config.Export.enabled and Config.Export.url == '' then
        print('^3[policedash] Config.Export.enabled = true, aber Config.Export.url ist leer.^0')
    end
end
validateConfig()

-- true, wenn der Spieler die Aktion gerade erst ausgefuehrt hat; sonst merken
local function onCooldown(kind, src, seconds)
    local now = GetGameTimer()
    local last = cooldowns[kind][src]
    if last and now - last < seconds * 1000 then return true end
    cooldowns[kind][src] = now
    return false
end

local function reject(src, reason)
    if Config.Server.logRejected then
        print(('^3[policedash] Messung von %s (%s) verworfen: %s^0'):format(GetPlayerName(src) or '?', src, reason))
    end
    TriggerEvent('policedash:server:submitRejected', src, reason)
    Upload.abortVideo(src)
    return { ok = false, reason = reason }
end

-- ---------- Validierung ----------

local function str(value, maxLength)
    if type(value) ~= 'string' then return nil end
    value = Utils.trim(value:gsub('%c', ''))
    return value ~= '' and value:sub(1, maxLength) or nil
end

local function num(value, min, max)
    value = tonumber(value)
    if not value or value ~= value or value < min or value > max then return nil end
    return value
end

local function vehicleInfo(data, labelled)
    if type(data) ~= 'table' then return nil end
    local plate = str(data.plate, 12)
    if not plate then return nil end
    return {
        model = str(data.model, 50) or '?',
        label = labelled and (str(data.label, 50) or '?') or nil,
        plate = plate,
    }
end

-- Fahrspur fuer die Mini-Map: nur Zahlen in plausiblen Grenzen, Laenge begrenzt
local TRACK_MAX_POINTS = 700
local TRACK_RANGE = 5000

local function sanitizeTrack(track)
    if type(track) ~= 'table' or type(track.points) ~= 'table' or type(track.origin) ~= 'table' then return nil end
    local origin = { x = num(track.origin.x, -1e5, 1e5), y = num(track.origin.y, -1e5, 1e5) }
    if not (origin.x and origin.y) then return nil end

    local points = {}
    for i, p in ipairs(track.points) do
        if i > TRACK_MAX_POINTS then break end
        if type(p) == 'table' then
            local t = num(p[1], 0, 700000)
            local ox, oy = num(p[2], -TRACK_RANGE, TRACK_RANGE), num(p[3], -TRACK_RANGE, TRACK_RANGE)
            if t and ox and oy then
                local point = { t, ox, oy }
                local tx, ty = num(p[4], -TRACK_RANGE, TRACK_RANGE), num(p[5], -TRACK_RANGE, TRACK_RANGE)
                if tx and ty then point[4], point[5] = tx, ty end
                points[#points + 1] = point
            end
        end
    end
    if #points < 2 then return nil end

    local marks = {}
    if type(track.marks) == 'table' then
        for _, name in ipairs({ 'start', 'finish' }) do
            local m = track.marks[name]
            if type(m) == 'table' then
                local x, y = num(m.x, -TRACK_RANGE, TRACK_RANGE), num(m.y, -TRACK_RANGE, TRACK_RANGE)
                if x and y then marks[name] = { x = x, y = y } end
            end
        end
    end
    return { origin = origin, points = points, marks = marks }
end

-- Baut aus den Client-Daten einen bereinigten Datensatz oder liefert nil + Grund
local function buildRecord(src, data)
    if type(data) ~= 'table' then return nil, 'payload' end
    if not MODES[data.mode] then return nil, 'mode' end
    if data.unit ~= Config.Units then return nil, 'unit' end

    local cfg = Config.Server
    local maxDuration = math.max(Config.MAN.maxDuration, Config.VASCAR.maxDuration) + 5
    local measured = num(data.measured, 0, Utils.fromKmh(cfg.maxSpeedKmh))
    local duration = num(data.duration, 0.5, maxDuration)
    local distance = num(data.distance, 0, math.max(Config.VASCAR.maxTrackLength, 20000))
    if not (measured and duration and distance) then return nil, 'values out of range' end

    -- Strecke und Dauer muessen zum Messwert passen
    local expected = Utils.msToUnit(distance / duration)
    if measured > 0 and math.abs(expected - measured) / measured > cfg.consistencyTolerance then
        return nil, ('inconsistent (%.1f vs %.1f)'):format(measured, expected)
    end
    if data.mode == 'VASCAR' and (distance < Config.VASCAR.minTrackLength or distance > Config.VASCAR.maxTrackLength) then
        return nil, 'track length'
    end

    local target = vehicleInfo(data.target, true)
    if data.mode == 'VASCAR' and not target then return nil, 'target missing' end

    local loc = type(data.location) == 'table' and data.location or {}
    local c = type(loc.coords) == 'table' and loc.coords or {}
    local coords = { x = num(c.x, -1e5, 1e5), y = num(c.y, -1e5, 1e5), z = num(c.z, -1e5, 1e5) }

    if ONESYNC then
        local ped = GetPlayerPed(src)
        if GetVehiclePedIsIn(ped, false) == 0 then return nil, 'not in vehicle' end

        local pos = GetEntityCoords(ped)
        if coords.x and coords.y and coords.z then
            local reported = vec3(coords.x, coords.y, coords.z)
            if #(pos - reported) > cfg.maxReportDistance then return nil, 'position mismatch' end
        end
        coords = { x = Utils.round(pos.x, 2), y = Utils.round(pos.y, 2), z = Utils.round(pos.z, 2) }
    elseif not (coords.x and coords.y and coords.z) then
        coords = nil
    end

    -- Toleranz serverseitig neu berechnen, Client-Werte werden ignoriert
    measured = Utils.round(measured, 1)
    local chargeable, tolerance = Utils.applyTolerance(measured)

    return {
        id         = Storage.nextId(),
        mode       = data.mode,
        timestamp  = os.time(),
        officer    = Bridge.getOfficer(src),
        vehicle    = vehicleInfo(data.vehicle, false),
        target     = target,
        location   = {
            street   = str(loc.street, 100),
            crossing = str(loc.crossing, 100),
            zone     = str(loc.zone, 100),
            coords   = coords,
        },
        measured   = measured,
        tolerance  = tolerance,
        chargeable = chargeable,
        unit       = Config.Units,
        duration   = Utils.round(duration, 2),
        distance   = Utils.round(distance, 1),
        maxSpeed   = num(data.maxSpeed, 0, Utils.fromKmh(cfg.maxSpeedKmh)),
        gap        = num(data.gap, 0, 1000),
        track      = sanitizeTrack(data.track),
        evidence   = {},
    }
end

-- ---------- Beweise sammeln, dann Webhook, Export, Event ----------

local function collectEvidence(src, record)
    local pending, finished, webhookSent = 0, false, false

    local function finish()
        if finished then return end
        finished = true
        Storage.updateEvidence(record)
        if not webhookSent then Webhook.send(record) end
        Export.send(record)
        TriggerEvent('policedash:server:measurementSaved', record)
        if GetPlayerName(src) then
            TriggerClientEvent('policedash:client:evidence', src, record.id, record.evidence)
        end
    end

    -- Erst alle Aufgaben anmelden, dann starten (sonst koennte eine sofortige Antwort zu frueh abschliessen)
    local function task()
        pending = pending + 1
        return function()
            pending = pending - 1
            if pending == 0 then finish() end
        end
    end

    local imageDone = Config.Evidence.screenshot and Config.Evidence.autoScreenshot and task()
    local videoDone = Upload.hasVideo(src) and task()

    if pending == 0 then return finish() end
    SetTimeout(EVIDENCE_TIMEOUT, finish)

    if imageDone then
        -- kurz warten, damit die Ergebnis-Karte im Bild ist (falls NUI mit aufgenommen wird)
        SetTimeout(500, function()
            Upload.screenshot(src, record, function(url, sent)
                record.evidence.image = url
                webhookSent = webhookSent or sent
                imageDone()
            end)
        end)
    end
    if videoDone then
        Upload.stopVideo(src, function(url)
            record.evidence.video = url
            videoDone()
        end)
    end
end

-- ---------- Callbacks & Events ----------

Callback.register('checkAccess', function(src)
    return Bridge.hasAccess(src)
end)

Callback.register('submit', function(src, data)
    if not Bridge.hasAccess(src) then return reject(src, 'no access') end
    if onCooldown('submit', src, Config.Server.submitCooldown) then return reject(src, 'rate limit') end

    local record, reason = buildRecord(src, data)
    if not record then return reject(src, reason) end

    Storage.insert(record)
    lastRecord[src] = record
    local recent = recentRecords[src] or {}
    table.insert(recent, 1, record)
    recent[RECENT_RECORDS + 1] = nil
    recentRecords[src] = recent
    collectEvidence(src, record)
    Utils.debug('accepted', record.id, record.measured, record.chargeable)
    return { ok = true, record = record }
end)

-- Manuelles Foto zur letzten eigenen Messung
Callback.register('photo', function(src, id)
    local record = lastRecord[src]
    if not Bridge.hasAccess(src) or not record or record.id ~= id then return { ok = false } end
    if onCooldown('photo', src, Config.Server.photoCooldown) then return { ok = false } end

    local p = promise.new()
    Upload.screenshot(src, record, function(url) p:resolve(url) end)
    local url = Citizen.Await(p)
    if not url then return { ok = false } end

    record.evidence.image = url
    Storage.updateEvidence(record)
    TriggerClientEvent('policedash:client:evidence', src, record.id, record.evidence)
    return { ok = true, url = url }
end)

-- Messvideo abspielen: nur selbst (Abruf per Messnummer) oder fuer alle im Umkreis (Vorfuehren)
Callback.register('playVideo', function(src, id, nearby)
    if not Playback.canView(src) then return { ok = false, reason = 'play_no_permission' } end
    if onCooldown('play', src, Config.Playback.cooldown) then return { ok = false, reason = 'play_cooldown' } end
    local ok, result = Playback.play(src, id, nearby == true)
    if not ok then return { ok = false, reason = result } end
    return { ok = true, count = result }
end)

RegisterNetEvent('policedash:server:measureStarted', function()
    local src = source
    if not Bridge.hasAccess(src) or onCooldown('start', src, 1) then return end
    Upload.startVideo(src)
end)

RegisterNetEvent('policedash:server:measureAborted', function()
    Upload.abortVideo(source)
end)

-- NUI-Videoaufnahme (Config.Evidence.videoSource = 'nui'), nur zu eigenen letzten Messungen
local function recentRecord(src, id)
    for _, record in ipairs(recentRecords[src] or {}) do
        if record.id == id then return record end
    end
end

RegisterNetEvent('policedash:server:videoChunk', function(id, index, total, chunk)
    local src = source
    local record = recentRecord(src, id)
    if Config.Evidence.videoSource ~= 'nui' or not record then return end
    if not Bridge.hasAccess(src) then return end

    Upload.videoChunk(src, record, index, total, chunk, function(url)
        if not url then return end
        record.evidence.video = url
        Storage.updateEvidence(record)
        TriggerEvent('policedash:server:videoSaved', record)
        if GetPlayerName(src) then
            TriggerClientEvent('policedash:client:evidence', src, record.id, record.evidence)
            TriggerClientEvent('policedash:client:videoSaved', src, record.id)
        end
    end)
end)

AddEventHandler('playerDropped', function()
    local src = source
    lastRecord[src] = nil
    recentRecords[src] = nil
    syncWindow[src] = nil
    for _, list in pairs(cooldowns) do list[src] = nil end
end)

-- ---------- Exports (siehe README) ----------
-- Mit Callback: asynchron inkl. Datenbank. Ohne Callback: synchron aus Cache bzw. KVP.

exports('GetMeasurement', function(id, cb)
    return Storage.get(id, cb)
end)

exports('GetMeasurementsByPlate', function(plate, limit, cb)
    return Storage.byPlate(plate, limit, cb)
end)

-- ---------- Debug ----------

local function getDebugInfo()
    local resources = {}
    for _, res in ipairs(OPTIONAL_RESOURCES) do
        resources[res] = GetResourceState(res)
    end
    return { framework = Bridge.name, version = VERSION, resources = resources }
end

Callback.register('debugInfo', function(src)
    if not Bridge.hasAccess(src) then return nil end
    return getDebugInfo()
end)

-- ---------- Beifahrer-Bedienung: Anzeige an die anderen Insassen weiterleiten ----------
-- Nur an Spieler im selben Fahrzeug, gedrosselt, nur fuer Berechtigte. Braucht OneSync.

local SYNC_MAX_PER_SECOND = 25   -- erlaubt kurze Bursts (Nachzuegler-Abgleich), bremst Spam

local function otherOccupants(src)
    local vehicle = GetVehiclePedIsIn(GetPlayerPed(src), false)
    if vehicle == 0 then return {} end
    local list = {}
    for _, player in ipairs(GetPlayers()) do
        local id = tonumber(player)
        if id ~= src and GetVehiclePedIsIn(GetPlayerPed(id), false) == vehicle then
            list[#list + 1] = id
        end
    end
    return list
end

RegisterNetEvent('policedash:server:sync', function(msg)
    local src = source
    if not Config.Sync.enabled or not ONESYNC or type(msg) ~= 'table' or type(msg.action) ~= 'string' then return end
    local now = GetGameTimer()
    local window = syncWindow[src]
    if not window or now - window.start >= 1000 then
        window = { start = now, count = 0 }
        syncWindow[src] = window
    end
    window.count = window.count + 1
    if window.count > SYNC_MAX_PER_SECOND then return end
    if not Bridge.hasAccess(src) then return end

    for _, target in ipairs(otherOccupants(src)) do
        TriggerClientEvent('policedash:client:sync', target, src, { action = msg.action, data = msg.data })
    end
end)

RegisterNetEvent('policedash:server:syncHello', function()
    local src = source
    if not Config.Sync.enabled or not ONESYNC or onCooldown('hello', src, 2) then return end
    for _, target in ipairs(otherOccupants(src)) do
        TriggerClientEvent('policedash:client:syncHello', target)
    end
end)

-- Diagnose-Log des Bild-im-Bild (/policedash pip log, nur mit Config.Debug) -> logs/pip-<zeit>-<id>.json
RegisterNetEvent('policedash:server:pipLog', function(payload)
    local src = source
    if not Config.Debug or not Bridge.hasAccess(src) or type(payload) ~= 'string' or #payload > 3000000 then return end
    if onCooldown('log', src, 5) then return end
    local path = ('logs/pip-%s-%d.json'):format(os.date('%Y%m%d-%H%M%S'), src)
    if SaveResourceFile(RESOURCE, path, payload, #payload) then
        print(('[policedash] PiP-Log gespeichert: %s (%d Bytes)'):format(path, #payload))
        TriggerClientEvent('policedash:client:pipLogSaved', src, path)
    end
end)

-- Serverkonsole: policedash debug (oder poldash debug)
local function onConsoleCommand(src, args)
    if src ~= 0 or args[1] ~= 'debug' then return end
    local info = getDebugInfo()
    print(('[policedash] v%s | Framework: %s | Speicher: %s | OneSync: %s'):format(
        info.version, info.framework, Storage.db and 'oxmysql' or 'KVP', tostring(ONESYNC)))
    for res, state in pairs(info.resources) do
        print(('[policedash]   %s: %s'):format(res, state))
    end
end
for _, name in ipairs(COMMAND_NAMES) do
    RegisterCommand(name, onConsoleCommand, true)
end

print(('^2[policedash] v%s gestartet | Framework: %s^0'):format(VERSION, Bridge.name))
if VERSION:lower():find('alpha', 1, true) then
    print('^3[policedash] ALPHA-Version: im Testbetrieb nutzen, Fehler bitte melden. Bild-im-Bild ist noch in Erprobung.^0')
end
if not ONESYNC then
    print('^3[policedash] OneSync aus: Fahrzeug- und Positionspruefung beim Submit eingeschraenkt.^0')
end
