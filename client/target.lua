-- Zielerfassung: Fahrzeug im Sichtkegel vor dem Streifenwagen finden, locken, Lock ueberwachen.
-- Laeuft nur, solange das Geraet aktiv ist (Vollbild-Dashcam oder Bild-im-Bild).
Target = {
    locked    = nil,   -- { entity, model, label, plate, lastSeen }
    candidate = nil,   -- Entity des naechsten passenden Fahrzeugs
}

local SCAN_INTERVAL = 200
local LOST_TIMEOUT  = 5000   -- ms ohne Sichtlinie, dann Lock weg
local BLOCKED_RETRY = 1000   -- verdeckte Kandidaten so lange ueberspringen
local LOS_FLAGS     = 1 | 16 -- Welt + Objekte. Andere Fahrzeuge blockieren bewusst nicht (Spielspass vor Praezision).

local range    = Config.Target.range
local cosCone  = math.cos(math.rad(Config.Target.coneDegrees))
local blocked  = {}          -- entity -> GetGameTimer(), ab dem es wieder geprueft wird
local blockedCount = 0
local sentKey  = nil         -- zuletzt ans NUI gesendeter Zustand

local function readVehicle(entity)
    local display = GetDisplayNameFromVehicleModel(GetEntityModel(entity))
    local label = GetLabelText(display)
    return {
        entity = entity,
        model  = display:lower(),
        label  = label ~= 'NULL' and label or display,
        plate  = Utils.trim(GetVehicleNumberPlateText(entity)),
    }
end

-- Fahrzeugdaten ohne Entity-Handle (fuer Ergebnis, NUI, Server)
function Target.publicData(lock)
    if not lock then return nil end
    return { model = lock.model, label = lock.label, plate = lock.plate }
end

-- Sichtlinie per asynchronem Shape-Test, wartet die noetigen Frames ab
local function hasLineOfSight(own, target)
    local from = GetOffsetFromEntityInWorldCoords(own, 0.0, 0.5, 1.0)
    local to = GetEntityCoords(target) + vec3(0.0, 0.0, 0.5)
    local handle = StartShapeTestLosProbe(from.x, from.y, from.z, to.x, to.y, to.z, LOS_FLAGS, own, 7)

    while true do
        -- status: 0 = ungueltig, 1 = laeuft noch, 2 = fertig
        local status, hit, _, _, entity = GetShapeTestResult(handle)
        if status ~= 1 then
            if status ~= 2 then return true end
            return not (hit == true or hit == 1) or entity == target
        end
        Wait(0)
    end
end

-- Naechstes Fahrzeug vor dem Streifenwagen innerhalb des (horizontalen) Kegels
local function findCandidate(own)
    local pos = GetEntityCoords(own)
    local fwd = GetEntityForwardVector(own)
    local fwdLen = math.sqrt(fwd.x * fwd.x + fwd.y * fwd.y)
    local now = GetGameTimer()
    local best, bestDist = nil, range

    for _, vehicle in ipairs(GetGamePool('CVehicle')) do
        if vehicle ~= own and (blocked[vehicle] or 0) <= now then
            local delta = GetEntityCoords(vehicle) - pos
            local dist = #delta
            if dist > 1.0 and dist < bestDist then
                local flat = math.sqrt(delta.x * delta.x + delta.y * delta.y)
                local cos = (fwd.x * delta.x + fwd.y * delta.y) / (flat * fwdLen)
                if cos >= cosCone then
                    best, bestDist = vehicle, dist
                end
            end
        end
    end
    return best
end

local function markBlocked(vehicle)
    if blockedCount > 32 then
        blocked, blockedCount = {}, 0
    end
    blocked[vehicle] = GetGameTimer() + BLOCKED_RETRY
    blockedCount = blockedCount + 1
end

local function sendTarget()
    local data, key = {}, ''
    if Target.locked then
        data = { plate = Target.locked.plate, locked = true }
        key = 'L' .. Target.locked.plate
    elseif Target.candidate then
        data = { plate = Utils.trim(GetVehicleNumberPlateText(Target.candidate)), locked = false }
        key = 'C' .. data.plate
    end
    if key ~= sentKey then
        sentKey = key
        NUI.send('overlay:target', data)
    end
end

function Target.lose(reasonKey)
    if not Target.locked then return end
    Target.locked = nil
    Notify(_L(reasonKey), 'warning')
    sendTarget()
    TriggerEvent('policedash:client:targetLost', reasonKey)
end

function Target.release()
    Target.locked, Target.candidate = nil, nil
    sendTarget()
end

local function updateCandidate(own)
    local vehicle = findCandidate(own)
    if vehicle and not hasLineOfSight(own, vehicle) then
        markBlocked(vehicle)
        vehicle = nil
    end
    Target.candidate = vehicle
end

local function updateLock(own)
    local lock = Target.locked
    if not DoesEntityExist(lock.entity) then
        return Target.lose('target_lost_gone')
    end
    if #(GetEntityCoords(lock.entity) - GetEntityCoords(own)) > range * 1.5 then
        return Target.lose('target_lost_range')
    end

    local now = GetGameTimer()
    if hasLineOfSight(own, lock.entity) then
        lock.lastSeen = now
    elseif now - lock.lastSeen > LOST_TIMEOUT then
        return Target.lose('target_lost_visible')
    end
end

local scanGeneration = 0

local function scan()
    scanGeneration = scanGeneration + 1
    if State.viewer then return end   -- Zuschauer bekommt das Ziel vom Bediener (client/sync.lua)
    local generation = scanGeneration
    while DeviceActive() and generation == scanGeneration do
        local own = State.vehicle
        if own ~= 0 then
            if Target.locked then updateLock(own) else updateCandidate(own) end
            -- Geraet kann waehrend des Shape-Tests ausgeschaltet worden sein
            if not DeviceActive() then break end
            sendTarget()
        end
        Wait(SCAN_INTERVAL)
    end
end

function Target.toggleLock()
    if Target.locked then
        if Measure.running then
            Notify(_L('measure_running'), 'error')
            return
        end
        Target.release()
        Notify(_L('target_released'), 'info')
        return
    end

    local candidate = Target.candidate
    if not candidate or not DoesEntityExist(candidate) then
        Notify(_L('no_target'), 'error')
        return
    end

    Target.locked = readVehicle(candidate)
    Target.locked.lastSeen = GetGameTimer()
    Target.candidate = nil
    sendTarget()
    Notify(_L('target_locked', Target.locked.plate, Target.locked.label), 'success')
end

Actions.lock = function()
    if not DeviceActive() then
        Notify(_L('cam_required'), 'error')
        return
    end
    Target.toggleLock()
end

-- Ein neuer Scan beendet den vorherigen (Generation), auch beim direkten Wechsel cam -> pip
AddEventHandler('policedash:client:deviceStarted', function()
    CreateThread(scan)
end)

AddEventHandler('policedash:client:deviceStopped', Target.release)
