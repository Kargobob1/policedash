-- Beifahrer-Bedienung: Wer das Geraet einschaltet, bedient es ("Bediener"). Die anderen Insassen
-- auf erlaubten Sitzen bekommen dieselbe Anzeige als Zuschauer (Modus, Ziel, W/Z, Ergebnis, Messnummer).
-- Die Eigengeschwindigkeit rechnet jeder Client selbst; der Server leitet nur an Insassen desselben
-- Fahrzeugs weiter (braucht OneSync).
Sync = {}

local cfg = Config.Sync
local SEND_INTERVAL = 200     -- ms, Live-Werte gedrosselt
local RELAYED = {             -- NUI-Nachrichten des Bedieners, die Zuschauer ebenfalls bekommen
    ['overlay:target'] = true,
    ['overlay:measure'] = true,
    ['result'] = true,
    ['result:id'] = true,
}

local pendingMeasure, nextMeasureAt = nil, 0
local lastSent = {}            -- action -> data (fuer den Nachzuegler-Abgleich)

local function isOperator()
    return DeviceActive() and not State.viewer
end

local function send(action, data)
    TriggerServerEvent('policedash:server:sync', { action = action, data = data })
end

-- NUI.send des Bedieners mitschneiden und relevante Nachrichten weitergeben
local rawSend = NUI.send
NUI.send = function(action, data)
    rawSend(action, data)
    if not cfg.enabled or not RELAYED[action] or not isOperator() then return end

    if action == 'overlay:measure' and data and data.running then
        pendingMeasure = data   -- gedrosselt, siehe Thread
        return
    end
    if action == 'overlay:measure' then pendingMeasure = nil end   -- Endwert nicht von altem Live-Wert ueberschreiben
    lastSent[action] = data
    send(action, data)
end

CreateThread(function()
    while true do
        Wait(SEND_INTERVAL)
        if pendingMeasure and isOperator() then
            lastSent['overlay:measure'] = pendingMeasure
            send('overlay:measure', pendingMeasure)
            pendingMeasure = nil
        end
    end
end)

-- Modus-Wechsel (steckt im lokalen overlay:update) und Ein/Aus separat melden
AddEventHandler('policedash:client:deviceStarted', function(mode)
    if not cfg.enabled or State.viewer then return end
    lastSent = {}
    send('device', { on = true, mode = mode, measureMode = State.mode })
end)

AddEventHandler('policedash:client:deviceStopped', function()
    if not cfg.enabled or State.viewer then return end
    send('device', { on = false })
end)

function Sync.modeChanged()
    if cfg.enabled and isOperator() then send('mode', { mode = State.mode }) end
end

-- ---------- Zuschauer ----------

local function operatorInMyVehicle(operatorId)
    local player = GetPlayerFromServerId(operatorId)
    if player == -1 then return false end
    return State.vehicle ~= 0 and GetVehiclePedIsIn(GetPlayerPed(player), false) == State.vehicle
end

-- Reihenfolge wichtig: erst stoppen (State.viewer ist dabei noch gesetzt, damit das Aus nicht
-- als Bediener gemeldet wird), dann zuruecksetzen
local function stopViewing()
    if not State.viewer then return end
    if PiP.active then PiP.stop() end
    State.viewer = nil
end

local function startViewing(operatorId)
    if DeviceActive() then return end   -- eigenes Geraet laeuft schon
    if not State.eligible then return end
    State.viewer = operatorId
    PiP.start(false, true)
    if not PiP.active then State.viewer = nil end
end

RegisterNetEvent('policedash:client:sync', function(operatorId, msg)
    if not cfg.enabled or type(operatorId) ~= 'number' or type(msg) ~= 'table' then return end
    if not operatorInMyVehicle(operatorId) then return end
    local action, data = msg.action, msg.data

    if action == 'device' and type(data) == 'table' then
        if data.on then
            startViewing(operatorId)
            if State.viewer and type(data.measureMode) == 'string' then
                State.mode = data.measureMode
                rawSend('overlay:update', { mode = State.mode })
            end
        elseif State.viewer == operatorId then
            stopViewing()
        end
        return
    end

    if State.viewer ~= operatorId then return end

    if action == 'mode' and type(data) == 'table' and type(data.mode) == 'string' then
        State.mode = data.mode
        rawSend('overlay:update', { mode = State.mode })
    elseif RELAYED[action] then
        rawSend(action, data)
        -- Zuschauer-Monitor optional live waehrend der Messung des Bedieners
        if action == 'overlay:measure' and type(data) == 'table' and cfg.viewerLive then
            PiP.measureLive(data.running == true, Config.Evidence.videoTail + 1)
        end
    end
end)

-- Nachzuegler: Wer einsteigt, fragt nach; der Bediener schickt den aktuellen Stand
AddEventHandler('policedash:client:eligibilityChanged', function(eligible)
    if not eligible then
        stopViewing()
        return
    end
    if cfg.enabled then TriggerServerEvent('policedash:server:syncHello') end
end)

RegisterNetEvent('policedash:client:syncHello', function()
    if not cfg.enabled or not isOperator() then return end
    send('device', { on = true, mode = State.camActive and 'cam' or 'pip', measureMode = State.mode })
    for action, data in pairs(lastSent) do send(action, data) end
end)

-- Zuschauer koennen nicht bedienen (ausser Bedienteil oeffnen und Zuschauen beenden)
function Sync.blocksAction(action)
    if not State.viewer then return false end
    if action == 'togglePanel' then return false end
    if action == 'toggleCam' then
        stopViewing()
        return true
    end
    Notify(_L('sync_viewer'), 'info')
    return true
end
