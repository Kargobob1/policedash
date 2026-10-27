-- NUI-Anbindung: Nachrichten, Callbacks, Notifications
NUI = { ready = false }

function NUI.send(action, data)
    SendNUIMessage({ action = action, data = data })
end

function NUI.setPanel(open)
    State.panelOpen = open
    SetNuiFocus(open, open)
    NUI.send('panel', { open = open })
end

-- Das NUI meldet sich nach dem Laden, erst dann Locale und Einstellungen senden
RegisterNUICallback('ready', function(_, cb)
    NUI.ready = true
    NUI.send('init', {
        locale  = GetLocaleTable(),
        overlay = Settings.get(),   -- Config.Overlay + persoenliche Einstellungen
        units   = Utils.unitLabel(),
        volume  = Config.Panel.volume,
        brand   = Config.Overlay.brand or _L('title'),
        zoom    = Config.Overlay.zoom,
        chunkSize = Config.Evidence.videoChunkSize,
        playbackCloseAfter = Config.Playback.closeAfter,
    })
    cb('ok')
end)

-- ---------- Geraet: Vollbild-Dashcam ('cam') oder Bild-im-Bild ('pip') ----------
-- Beide speisen dasselbe OSD und loesen dieselben Events aus.

local odometer, lastPos = 0.0, nil

function DeviceActive()
    return State.camActive or (PiP ~= nil and PiP.active)
end

function NUI.deviceStart(mode, extra)
    odometer, lastPos = 0.0, nil
    local data = extra or {}
    data.mode = mode
    NUI.send('device', data)
    TriggerEvent('policedash:client:deviceStarted', mode)
end

function NUI.deviceStop()
    NUI.send('device', { mode = false })
    TriggerEvent('policedash:client:deviceStopped')
end

-- OSD-Daten: Eigengeschwindigkeit, Modus, Wegstrecke seit Einschalten, Uhr (Echtzeit rechnet das NUI)
function NUI.deviceUpdate(vehicle)
    local pos = GetEntityCoords(vehicle)
    if lastPos then odometer = odometer + #(pos - lastPos) end
    lastPos = pos

    local data = {
        speed    = math.floor(Utils.msToUnit(GetEntitySpeed(vehicle)) + 0.5),
        mode     = State.mode,
        odometer = math.floor(odometer),
    }
    if Config.Overlay.clock ~= 'real' then
        data.clock = {
            year  = GetClockYear(),
            month = GetClockMonth() + 1,   -- Native liefert 0-11
            day   = GetClockDayOfMonth(),
            h     = GetClockHours(),
            m     = GetClockMinutes(),
            s     = GetClockSeconds(),
        }
    end
    NUI.send('overlay:update', data)
end

RegisterNUICallback('close', function(_, cb)
    if State.panelOpen then NUI.setPanel(false) end
    cb('ok')
end)

-- Notifications: ox_lib wenn vorhanden und erlaubt, sonst eigenes NUI
local NOTIFY_TYPES = { info = true, success = true, error = true, warning = true }

function Notify(message, kind)
    kind = NOTIFY_TYPES[kind] and kind or 'info'
    if Config.Integrations.oxLib and Utils.isStarted('ox_lib') then
        exports.ox_lib:notify({ title = _L('title'), description = message, type = kind })
    else
        NUI.send('notify', { message = message, type = kind })
    end
end

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
        SetNuiFocus(false, false)
    end
end)
