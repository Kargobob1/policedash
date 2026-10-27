-- Messvideos im Spiel abspielen: Abruf per Messnummer und Vorfuehren an Umstehende.
-- https-Videos (Fivemanage/Discord) spielt das NUI direkt ab; lokal gespeicherte Videos
-- streamt der Server per Latent-Event an jeden Zuschauer (braucht keine oeffentliche URL).
Playback = {}

local cfg = Config.Playback
local ONESYNC = GetConvar('onesync', 'off') ~= 'off'
local CACHE_SIZE = 4
local LOCAL_PATTERN = '^local:(recordings/[%w%-]+%.webm)$'

local encoded, encodedOrder = {}, {}   -- id -> Base64 der lokalen Datei (klein gehaltener Cache)

function Playback.canView(src)
    return Bridge.hasAccess(src)
        or (cfg.viewAce and IsPlayerAceAllowed(tostring(src), cfg.viewAce))
        or Bridge.hasJob(src, cfg.viewJobs)
end

-- Nur was die Zuschauer sehen sollen, ohne Identifier o.ae.
local function summary(record)
    local loc = record.location or {}
    return {
        id         = record.id,
        mode       = record.mode,
        timestamp  = record.timestamp,
        officer    = record.officer and record.officer.name or nil,
        target     = record.target,
        street     = loc.street,
        zone       = loc.zone,
        measured   = record.measured,
        tolerance  = record.tolerance,
        chargeable = record.chargeable,
        unit       = record.unit,
        duration   = record.duration,
        distance   = record.distance,
        gap        = record.gap,
        track      = record.track,   -- Mini-Map
    }
end

local function audience(src, nearby)
    local list = { src }
    if not nearby or not ONESYNC then return list end

    local origin = GetEntityCoords(GetPlayerPed(src))
    for _, player in ipairs(GetPlayers()) do
        local id = tonumber(player)
        if id ~= src and #(GetEntityCoords(GetPlayerPed(id)) - origin) <= cfg.radius then
            list[#list + 1] = id
        end
    end
    return list
end

local function loadLocal(id, path)
    if encoded[id] then return encoded[id] end
    local data = LoadResourceFile(GetCurrentResourceName(), path)
    if not data or data == '' then return nil end

    local b64 = Upload.base64Encode(data)
    encoded[id] = b64
    encodedOrder[#encodedOrder + 1] = id
    if #encodedOrder > CACHE_SIZE then encoded[table.remove(encodedOrder, 1)] = nil end
    return b64
end

-- Spielt die Messung fuer src (und bei nearby fuer alle im Umkreis) ab.
-- Liefert ok, reasonKey | count. Muss in einem Thread laufen.
function Playback.play(src, id, nearby)
    if type(id) ~= 'string' or #id > 32 then return false, 'play_not_found' end

    local p = promise.new()
    Storage.get(id, function(record) p:resolve(record) end)
    local record = Citizen.Await(p)
    if not record then return false, 'play_not_found' end

    local video = record.evidence and record.evidence.video
    if type(video) ~= 'string' then return false, 'play_no_video' end

    local info = summary(record)
    info.shownBy = Bridge.getOfficer(src).name
    local targets = audience(src, nearby)

    if video:match('^https://') then
        info.url = video
        for _, target in ipairs(targets) do
            TriggerClientEvent('policedash:client:playVideo', target, info, target == src)
        end
        return true, #targets
    end

    local path = video:match(LOCAL_PATTERN)
    local data = path and loadLocal(record.id, path)
    if not data then return false, 'play_no_video' end

    local size = Config.Evidence.videoChunkSize
    local total = math.ceil(#data / size)
    info.chunks = total
    for _, target in ipairs(targets) do
        TriggerClientEvent('policedash:client:playVideo', target, info, target == src)
        for i = 1, total do
            TriggerLatentClientEvent('policedash:client:videoChunk', target, cfg.bps, record.id, i, total,
                data:sub((i - 1) * size + 1, i * size))
        end
    end
    return true, #targets
end
