-- Client-Hauptlogik: State, Fahrzeug-/Sitzpruefung, Berechtigung, Keybinds, Debug
Bridge.load()

State = {
    vehicle         = 0,
    seat            = nil,
    eligible        = false,   -- erlaubtes Fahrzeug + erlaubter Sitz + lebendig
    access          = false,   -- vom Server bestaetigt
    accessCheckedAt = nil,     -- GetGameTimer() der letzten Pruefung, nil = ungueltig
    camActive       = false,
    panelOpen       = false,
    mode            = 'MAN',   -- MAN | VASCAR
    lastMeasurement = nil,
    viewer          = nil,     -- Server-ID des Bedieners, wenn dieser Client nur zuschaut (client/sync.lua)
}

local POLL_INTERVAL = 1000

-- Modell-Hashes einmalig vorberechnen
local vehicleConfigs = {}
for model, data in pairs(Config.Vehicles) do
    vehicleConfigs[joaat(model)] = data
end

function GetVehicleConfig(vehicle)
    return vehicleConfigs[GetEntityModel(vehicle)]
end

local function isVehicleAllowed(vehicle)
    if vehicleConfigs[GetEntityModel(vehicle)] then return true end
    return Config.AllowEmergencyClass and GetVehicleClass(vehicle) == 18
end

local function getAllowedSeat(ped, vehicle)
    for _, seat in ipairs(Config.AllowedSeats) do
        if GetPedInVehicleSeat(vehicle, seat) == ped then
            return seat
        end
    end
    return nil
end

-- Berechtigung beim Server erfragen und cachen. Muss in einem Thread laufen.
function RefreshAccess(force)
    local checkedAt = State.accessCheckedAt
    if not force and checkedAt and GetGameTimer() - checkedAt < Config.AccessCacheSeconds * 1000 then
        return State.access
    end

    local result = Callback.await('checkAccess', 10000)
    if result == nil then
        -- Timeout: alten Wert behalten, aber beim naechsten Mal erneut fragen
        return State.access
    end

    State.access = result == true
    State.accessCheckedAt = GetGameTimer()
    return State.access
end

AddEventHandler('policedash:client:accessInvalidated', function()
    State.accessCheckedAt = nil
end)

-- Fahrzeug-Poll (statt baseevents). Andere Module reagieren auf
-- 'policedash:client:eligibilityChanged' (z.B. Cam beenden, Messung abbrechen).
CreateThread(function()
    while true do
        local ped = PlayerPedId()
        local vehicle = GetVehiclePedIsIn(ped, false)
        local seat = nil

        if vehicle ~= 0 and not IsEntityDead(ped) and isVehicleAllowed(vehicle) then
            seat = getAllowedSeat(ped, vehicle)
        end

        local eligible = seat ~= nil
        if not eligible then vehicle = 0 end

        if eligible ~= State.eligible or vehicle ~= State.vehicle then
            State.eligible, State.vehicle, State.seat = eligible, vehicle, seat
            Utils.debug('eligibility changed:', eligible, vehicle, seat)
            TriggerEvent('policedash:client:eligibilityChanged', eligible, vehicle, seat)
            if eligible then RefreshAccess() end
        end

        Wait(POLL_INTERVAL)
    end
end)

-- Gemeinsame Vorbedingung fuer alle Bedienaktionen (Tasten und Bedienteil)
function CanUse()
    if not State.eligible then
        Notify(_L('not_in_vehicle'), 'error')
        return false
    end
    if not RefreshAccess() then
        Notify(_L('no_access'), 'error')
        return false
    end
    return true
end

-- Bedienaktionen; die Module (camera, target, measure, evidence, panel) setzen ihre Funktionen ein
Actions = {}

local function bind(command, action, key, labelKey)
    local name = 'policedash_' .. command
    RegisterCommand(name, function()
        CreateThread(function()
            if Sync and Sync.blocksAction(action) then return end
            if CanUse() then Actions[action]() end
        end)
    end, false)
    RegisterKeyMapping(name, _L(labelKey), 'keyboard', key)
end

local keys = Config.Keys
bind('togglecam', 'toggleCam',   keys.toggleCam,   'key_toggle_cam')
bind('panel',     'togglePanel', keys.togglePanel, 'key_toggle_panel')
bind('startstop', 'startStop',   keys.start,       'key_start')
if keys.stop and keys.stop ~= keys.start then
    bind('stop',  'stop',        keys.stop,        'key_stop')
end
bind('mode',      'mode',        keys.mode,        'key_mode')
bind('lock',      'lock',        keys.lock,        'key_lock')
bind('reset',     'reset',       keys.reset,       'key_reset')
bind('photo',     'photo',       keys.photo,       'key_photo')

-- /policedash <subcommand> ...; weitere Module koennen Subcommands ergaenzen
Subcommands = {}

-- /policedash debug
local function printDebug()
    local yesNo = function(v) return v and _L('yes') or _L('no') end
    local access = RefreshAccess(true)

    print(_L('debug_header'))
    print(_L('debug_framework', Bridge.name))
    for _, res in ipairs({ 'ox_lib', 'oxmysql', 'screencapture', 'screenshot-basic' }) do
        print(_L('debug_resource', res, GetResourceState(res)))
    end
    print(_L('debug_vehicle', State.vehicle, tostring(State.seat), yesNo(State.eligible)))
    print(_L('debug_access', yesNo(access)))

    local server = Callback.await('debugInfo', 5000)
    if server then
        print(_L('debug_server', server.framework, server.version))
        for res, state in pairs(server.resources) do
            print('  ' .. _L('debug_resource', res, state))
        end
    else
        print(_L('debug_no_server'))
    end

    Notify(_L('debug_summary', Bridge.name, yesNo(access)), 'info')
end

Subcommands.debug = function() CreateThread(printDebug) end

-- /policedash (englisch) und /poldash (deutsch) funktionieren beide, unabhaengig von Config.Locale
local function onCommand(_, args)
    local handler = Subcommands[args[1] or '']
    if handler then
        handler({ table.unpack(args, 2) })
    end
end
for _, name in ipairs(COMMAND_NAMES) do
    RegisterCommand(name, onCommand, false)
end

-- Oeffentliche Client-API (siehe README)
exports('IsCamActive', function() return State.camActive end)
exports('GetLastMeasurement', function() return State.lastMeasurement end)
