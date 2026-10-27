-- Lokale Messhistorie und persoenliche Einstellungen per KVP (pro Spieler und Server)
History = {}
Settings = {}

local HISTORY_KEY  = 'history'
local SETTINGS_KEY = 'settings'

local function readJson(key)
    local raw = GetResourceKvpString(key)
    if not raw or raw == '' then return nil end
    local ok, data = pcall(json.decode, raw)
    return ok and type(data) == 'table' and data or nil
end

-- ---------- Historie ----------

local entries = nil

local function load()
    if not entries then entries = readJson(HISTORY_KEY) or {} end
    return entries
end

local function save()
    SetResourceKvp(HISTORY_KEY, json.encode(entries))
end

function History.all()
    return load()
end

function History.add(record)
    local list = load()
    table.insert(list, 1, record)
    while #list > Config.Storage.kvpHistory do
        table.remove(list)
    end
    save()
end

function History.setEvidence(id, evidence)
    for _, entry in ipairs(load()) do
        if entry.id == id then
            entry.evidence = evidence
            save()
            return entry
        end
    end
end

-- ---------- Einstellungen (Overlay-Defaults aus der Config, vom Spieler im Panel aenderbar) ----------

local THEMES = { white = true, green = true }
DASH_FPS_MIN, DASH_FPS_MAX = 10, 24

function ClampDashFps(value)
    value = tonumber(value)
    if not value then return nil end
    return math.floor(math.min(DASH_FPS_MAX, math.max(DASH_FPS_MIN, value)) + 0.5)
end

function Settings.get()
    local stored = readJson(SETTINGS_KEY) or {}
    local result = {}
    for k, v in pairs(Config.Overlay) do result[k] = v end
    result.sounds = Config.Panel.sounds
    result.dashFps = ClampDashFps(Config.PiP.monitorFps) or 15

    if THEMES[stored.theme] then result.theme = stored.theme end
    if type(stored.scale) == 'number' then result.scale = stored.scale end
    if type(stored.sounds) == 'boolean' then result.sounds = stored.sounds end
    if ClampDashFps(stored.dashFps) then result.dashFps = ClampDashFps(stored.dashFps) end
    return result
end

-- Eingaben aus dem NUI validieren, nur bekannte Felder uebernehmen
function Settings.set(input)
    if type(input) ~= 'table' then return Settings.get() end
    local stored = readJson(SETTINGS_KEY) or {}

    if THEMES[input.theme] then stored.theme = input.theme end
    local scale = tonumber(input.scale)
    if scale then stored.scale = Utils.round(math.min(1.6, math.max(0.6, scale)), 2) end
    if type(input.sounds) == 'boolean' then stored.sounds = input.sounds end
    if ClampDashFps(input.dashFps) then stored.dashFps = ClampDashFps(input.dashFps) end

    SetResourceKvp(SETTINGS_KEY, json.encode(stored))
    local settings = Settings.get()
    Config.PiP.monitorFps = settings.dashFps   -- wirkt sofort, auch bei laufendem Bild-im-Bild
    return settings
end

-- Gespeicherte Dashcam-FPS beim Start uebernehmen
Config.PiP.monitorFps = Settings.get().dashFps
