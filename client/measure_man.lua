-- Modus MAN (Nachfahren): Durchschnittsgeschwindigkeit des Streifenwagens ueber ein Intervall,
-- waehrend das Ziel in moeglichst gleichem Abstand vorausfaehrt.
local cfg = Config.MAN
local run = nil

local function sample(current)
    local pos = GetEntityCoords(State.vehicle)
    current.distance = current.distance + #(pos - current.lastPos)
    current.lastPos = pos

    local speed = Utils.msToUnit(GetEntitySpeed(State.vehicle))
    if speed > current.maxSpeed then current.maxSpeed = speed end

    local targetPos = nil
    if current.target and DoesEntityExist(current.target.entity) then
        targetPos = GetEntityCoords(current.target.entity)
        local gap = #(targetPos - pos)
        local g = current.gap
        g.sum, g.count = g.sum + gap, g.count + 1
        if gap < g.min then g.min = gap end
        if gap > g.max then g.max = gap end
    end
    Measure.trackPoint(current.track, GetGameTimer() - current.startedAt, pos, targetPos)
end

-- Liefert Fehler-Key + Format-Argumente oder nil, wenn der Abstand passt
local function validateGap(gap)
    if gap.count == 0 then return 'err_no_samples' end
    local mean = gap.sum / gap.count
    if mean < cfg.minDistance then return 'err_too_close', mean, cfg.minDistance end
    if mean > cfg.maxDistance then return 'err_too_far', mean, cfg.maxDistance end

    local variance = (gap.max - gap.min) / mean
    local allowed = cfg.maxVariance * (Config.FunMode and 1.5 or 1.0)
    if variance > allowed then return 'err_variance', variance * 100, allowed * 100 end
    return nil
end

local function stop()
    if not run then return end
    local current = run
    run, Measure.running = nil, nil

    if current.lost then return Measure.fail('MAN', 'err_target_lost') end

    local duration = (GetGameTimer() - current.startedAt) / 1000
    if duration < cfg.minDuration then
        return Measure.fail('MAN', 'err_too_short', cfg.minDuration)
    end

    local gapMean = nil
    if current.target then
        local err, a, b = validateGap(current.gap)
        if err then return Measure.fail('MAN', err, a, b) end
        gapMean = Utils.round(current.gap.sum / current.gap.count, 1)
    end

    local measured = Utils.msToUnit(current.distance / duration)
    if measured < 5 then return Measure.fail('MAN', 'err_no_movement') end

    Measure.finish({
        mode      = 'MAN',
        measured  = Utils.round(measured, 1),
        maxSpeed  = Utils.round(current.maxSpeed, 1),
        duration  = Utils.round(duration, 2),
        distance  = Utils.round(current.distance, 1),
        gap       = gapMean,
        target    = Target.publicData(current.target),
        track     = Measure.trackData(current.track),
    })
end

local function start()
    local target = Target.locked
    if cfg.requireTarget and not target then
        Notify(_L('target_required'), 'error')
        return
    end

    local startPos = GetEntityCoords(State.vehicle)
    local current = {
        startedAt = GetGameTimer(),
        lastPos   = startPos,
        track     = Measure.newTrack(startPos),
        distance  = 0.0,
        maxSpeed  = 0.0,
        target    = target,
        gap       = { sum = 0.0, count = 0, min = math.huge, max = 0.0 },
    }
    run, Measure.running = current, 'MAN'
    Measure.started()
    Measure.sendLive(0, 0, true)

    CreateThread(function()
        while run == current do
            Wait(cfg.sampleRate)
            if run ~= current then break end

            sample(current)
            local elapsed = (GetGameTimer() - current.startedAt) / 1000
            Measure.sendLive(Utils.msToUnit(current.distance / math.max(elapsed, 0.001)), elapsed, true, current.distance)

            -- Maximaldauer erreicht: regulaer auswerten
            if elapsed >= cfg.maxDuration then stop() end
        end
    end)
end

-- Ziel waehrend der Messung verloren -> sofort als ungueltig auswerten
AddEventHandler('policedash:client:targetLost', function()
    if run and run.target then
        run.lost = true
        stop()
    end
end)

Measure.register('MAN', {
    trigger = function() if run then stop() else start() end end,
    stop    = stop,
    cancel  = function() run = nil end,
})
