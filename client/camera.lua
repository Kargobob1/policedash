-- Dashcam: Scripted Camera an der Frontscheibe, Overlay-Updates, Auto-Abbruch
Camera = { handle = nil }

local OVERLAY_INTERVAL = 200   -- ms zwischen Overlay-Updates (Kamera selbst laeuft jeden Frame)
local CONTROL_VEH_EXIT = 75

local camVehicle = 0
local debugOffset, debugFov = nil, nil
local timecycleActive = false

-- Offset/FOV je Modell (auch von client/pip.lua genutzt)
function Camera.getOffset(vehicle)
    if debugOffset then return debugOffset end
    local cfg = GetVehicleConfig(vehicle)
    return (cfg and cfg.offset) or Config.DefaultCamOffset
end

function Camera.getFov(vehicle)
    if debugFov then return debugFov end
    local cfg = GetVehicleConfig(vehicle)
    return (cfg and cfg.fov) or Config.CamFov
end

local getOffset, getFov = Camera.getOffset, Camera.getFov

-- Kamera ans Fahrzeug haengen (auch fuer die Dashcam im Bild-im-Bild).
--   'hard':   Position UND Drehung haengen am Fahrzeug (HardAttachCamToEntity, ab Build 2189). Das Spiel
--             rechnet beides im selben Frame wie das Fahrzeug -> kein Ruckeln bei Bodenwellen/hohem Tempo.
--   'script': Drehung jeden Frame per SetCamRot nachfuehren. Das Skript liest die Fahrzeuglage vor der
--             Physik, die angehaengte Position kommt danach -> Drehung kann einen Frame hinterherhinken.
function Camera.attachTo(cam, vehicle)
    local offset = getOffset(vehicle)
    DetachCam(cam)
    if Config.CamAttach == 'script' then
        AttachCamToEntity(cam, vehicle, offset.x, offset.y, offset.z, true)
    else
        HardAttachCamToEntity(cam, vehicle, 0.0, 0.0, 0.0, offset.x, offset.y, offset.z, true)
    end
    SetCamFov(cam, getFov(vehicle))
end

-- Nur bei 'script' noetig (jeden Frame aufrufen, in dem die Kamera rendert)
function Camera.followRotation(cam, vehicle)
    if Config.CamAttach ~= 'script' then return end
    local rot = GetEntityRotation(vehicle, 2)
    SetCamRot(cam, rot.x, rot.y, rot.z, 2)
end

local function attach(vehicle)
    Camera.attachTo(Camera.handle, vehicle)
end

local function syncRotation(vehicle)
    Camera.followRotation(Camera.handle, vehicle)
end

local function shouldAbort(ped, vehicle)
    return not DoesEntityExist(vehicle)
        or GetVehiclePedIsIn(ped, false) ~= vehicle
        or IsEntityDead(ped)
        or IsControlJustPressed(0, CONTROL_VEH_EXIT)   -- sofort beim Aussteigen, nicht erst nach dem Poll
end

local function tick()
    local nextOverlay = 0
    while State.camActive do
        local ped = PlayerPedId()
        if shouldAbort(ped, camVehicle) then
            Camera.stop()
            break
        end

        syncRotation(camVehicle)
        HideHudAndRadarThisFrame()

        local now = GetGameTimer()
        if now >= nextOverlay then
            nextOverlay = now + OVERLAY_INTERVAL
            NUI.deviceUpdate(camVehicle)
        end

        Wait(0)
    end
end

function Camera.start()
    if State.camActive or not State.eligible then return end
    if PiP and PiP.active then PiP.stop() end

    camVehicle = State.vehicle
    Camera.handle = CreateCam('DEFAULT_SCRIPTED_CAMERA', true)
    attach(camVehicle)
    syncRotation(camVehicle)
    RenderScriptCams(true, false, 0, true, true)

    if Config.CamTimecycle then
        SetTimecycleModifier(Config.CamTimecycle)
        SetTimecycleModifierStrength(Config.CamTimecycleStrength or 1.0)
        timecycleActive = true
    end

    State.camActive = true
    NUI.deviceStart('cam')
    NUI.deviceUpdate(camVehicle)
    CreateThread(tick)
end

-- Raeumt die Kamera auf, ohne Events oder NUI (auch fuer onResourceStop)
local function release()
    RenderScriptCams(false, false, 0, true, true)
    if Camera.handle then
        DestroyCam(Camera.handle, false)
        Camera.handle = nil
    end
    if timecycleActive then
        ClearTimecycleModifier()
        timecycleActive = false
    end
end

function Camera.stop()
    if not State.camActive then return end
    State.camActive = false
    release()
    camVehicle = 0
    NUI.deviceStop()
end

function Camera.toggle()
    if State.camActive then Camera.stop() else Camera.start() end
end

Actions.toggleCam = Camera.toggle

-- Fahrzeugwechsel, Aussteigen, Tod (Fallback zum Frame-Check)
AddEventHandler('policedash:client:eligibilityChanged', function(eligible, vehicle)
    if State.camActive and (not eligible or vehicle ~= camVehicle) then
        Camera.stop()
    end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() and Camera.handle then
        release()
    end
end)

-- /policedash offset x y z [fov] | /policedash offset reset  (nur mit Config.Debug)
-- Hilft beim Einstellen der Offsets je Modell und gibt die passende Config-Zeile aus.
Subcommands.offset = function(args)
    if not Config.Debug then return end

    if args[1] == 'reset' then
        debugOffset, debugFov = nil, nil
    else
        local x, y, z = tonumber(args[1]), tonumber(args[2]), tonumber(args[3])
        if not (x and y and z) then
            print('usage: /policedash offset <x> <y> <z> [fov] | reset')
            return
        end
        debugOffset, debugFov = vec3(x, y, z), tonumber(args[4])
    end

    if State.camActive then attach(camVehicle) end

    local vehicle = State.vehicle
    if vehicle ~= 0 then
        local offset, fov = getOffset(vehicle), getFov(vehicle)
        local model = GetDisplayNameFromVehicleModel(GetEntityModel(vehicle)):lower()
        print(('%s = { offset = vec3(%.2f, %.2f, %.2f), fov = %.1f },'):format(model, offset.x, offset.y, offset.z, fov))
    end
end
