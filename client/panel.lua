-- Bedienteil: Statusanzeige, Tasten per Maus, Historie, Einstellungen
Panel = {}

local STATE_INTERVAL = 500

-- Vom NUI ausloesbare Aktionen (Whitelist)
local PANEL_ACTIONS = {
    toggleCam = true, mode = true, lock = true, startStop = true, reset = true, photo = true,
}

local function lastSummary()
    local last = State.lastMeasurement
    if not last then return nil end
    return { id = last.id, chargeable = last.chargeable, unit = last.unit, plate = last.target and last.target.plate }
end

function Panel.push()
    if not State.panelOpen then return end
    NUI.send('panel:state', {
        camActive = DeviceActive(),
        mode      = State.mode,
        running   = Measure.running ~= nil,
        target    = Target.locked and Target.locked.plate or nil,
        last      = lastSummary(),
    })
end

function Panel.open()
    if State.panelOpen then return end
    NUI.setPanel(true)
    CreateThread(function()
        while State.panelOpen do
            Panel.push()
            Wait(STATE_INTERVAL)
        end
    end)
end

function Panel.close()
    if State.panelOpen then NUI.setPanel(false) end
end

Actions.togglePanel = function()
    if State.panelOpen then Panel.close() else Panel.open() end
end

RegisterNUICallback('action', function(data, cb)
    cb('ok')
    local name = type(data) == 'table' and data.name
    if not PANEL_ACTIONS[name] then return end
    CreateThread(function()
        if not (Sync and Sync.blocksAction(name)) and CanUse() then Actions[name]() end
        Panel.push()
    end)
end)

RegisterNUICallback('settings', function(data, cb)
    local settings = Settings.set(data)
    NUI.send('settings', settings)
    cb(settings)
end)

RegisterNUICallback('history', function(_, cb)
    cb(History.all())
end)

-- Bedienteil schliessen, wenn das Fahrzeug nicht mehr passt
AddEventHandler('policedash:client:eligibilityChanged', function(eligible)
    if not eligible then Panel.close() end
end)
