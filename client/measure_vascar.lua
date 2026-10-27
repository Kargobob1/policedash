-- Modus Weg-Zeit (VASCAR): Start- und Endpunkt setzen, wenn das Ziel zwei Merkmale passiert.
-- Geschwindigkeit = Strecke (Luftlinie Start -> Ende) / Zeit.
local cfg = Config.VASCAR
local LIVE_INTERVAL = 100
local MARKER_TYPE = 1   -- Zylinder am Boden

local run = nil

local function stop()
    if not run then return end
    local current = run
    run, Measure.running = nil, nil

    local target = Target.locked
    if not target or target.entity ~= current.target.entity or not DoesEntityExist(target.entity) then
        return Measure.fail('VASCAR', 'err_target_lost')
    end

    local duration = (GetGameTimer() - current.startedAt) / 1000
    if duration <= 1.0 then return Measure.fail('VASCAR', 'err_duration_short') end

    local endPos = GetEntityCoords(target.entity)
    local track = #(endPos - current.startPos)
    if track < cfg.minTrackLength then
        return Measure.fail('VASCAR', 'err_track_short', track, cfg.minTrackLength)
    end
    if track > cfg.maxTrackLength then
        return Measure.fail('VASCAR', 'err_track_long', track, cfg.maxTrackLength)
    end

    Measure.finish({
        mode     = 'VASCAR',
        measured = Utils.round(Utils.msToUnit(track / duration), 1),
        duration = Utils.round(duration, 2),
        distance = Utils.round(track, 1),
        target   = Target.publicData(target),
        track    = Measure.trackData(current.track, { start = current.startPos, finish = endPos }),
    })
end

local function start()
    local target = Target.locked
    if not target then
        Notify(_L('target_required'), 'error')
        return
    end

    local current = {
        startedAt = GetGameTimer(),
        startPos  = GetEntityCoords(target.entity),
        target    = target,
        track     = Measure.newTrack(GetEntityCoords(State.vehicle)),
    }
    run, Measure.running = current, 'VASCAR'
    Measure.started()
    Measure.sendLive(nil, 0, true)
    Notify(_L('vascar_start_set'), 'info')

    CreateThread(function()
        local nextLive = 0
        local p = current.startPos
        local found, groundZ = GetGroundZFor_3dCoord(p.x, p.y, p.z + 1.0, false)
        local markerZ = found and groundZ or p.z - 0.5
        while run == current do
            local now = GetGameTimer()
            local elapsed = (now - current.startedAt) / 1000

            if elapsed > cfg.maxDuration then
                run, Measure.running = nil, nil
                Measure.fail('VASCAR', 'err_too_long', cfg.maxDuration)   -- meldet auch das Video-Ende
                break
            end

            if now >= nextLive then
                nextLive = now + LIVE_INTERVAL
                local entity = current.target.entity
                local targetPos = DoesEntityExist(entity) and GetEntityCoords(entity) or nil
                local track = targetPos and #(targetPos - current.startPos) or nil
                Measure.sendLive(nil, elapsed, true, track)
                Measure.trackPoint(current.track, now - current.startedAt, GetEntityCoords(State.vehicle), targetPos)
            end

            if cfg.showMarker then
                -- Startpunkt sichtbar markieren, damit man das Ende sinnvoll waehlen kann
                DrawMarker(MARKER_TYPE, p.x, p.y, markerZ, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                    3.0, 3.0, 0.6, 255, 255, 255, 90, false, false, 2, false, nil, nil, false)
                Wait(0)
            else
                Wait(LIVE_INTERVAL)
            end
        end
    end)
end

-- Ziel verloren -> Messung sofort ungueltig
AddEventHandler('policedash:client:targetLost', function()
    if run then stop() end
end)

Measure.register('VASCAR', {
    trigger = function() if run then stop() else start() end end,   -- 1. Druck Start-, 2. Druck Endpunkt
    stop    = stop,
    cancel  = function() run = nil end,
})
