-- Speicherung: oxmysql (optional) oder Server-KVP, dazu Discord-Webhook und HTTP-Export ans MDT.
-- SQL ausschliesslich mit Platzhaltern (Prepared Statements).
Storage = { db = false }
Webhook = {}
Export  = {}

local CACHE_SIZE = 200
local PLATE_INDEX_SIZE = 50

local cache, cacheOrder = {}, {}

local function remember(record)
    if not cache[record.id] then
        cacheOrder[#cacheOrder + 1] = record.id
        if #cacheOrder > CACHE_SIZE then
            cache[table.remove(cacheOrder, 1)] = nil
        end
    end
    cache[record.id] = record
end

local function normalizePlate(plate)
    return Utils.trim(plate):upper()
end

-- Lesend, muss in einem Thread laufen
local function dbQuery(query, params)
    local p = promise.new()
    exports.oxmysql:query(query, params or {}, function(result) p:resolve(result) end)
    return Citizen.Await(p)
end

-- Schreibend, ohne zu warten (auch aus HTTP-Callbacks heraus nutzbar)
local function dbExecute(query, params)
    exports.oxmysql:query(query, params or {}, function() end)
end

local function decode(raw)
    if type(raw) ~= 'string' then return nil end
    local ok, data = pcall(json.decode, raw)
    return ok and data or nil
end

-- ---------- Initialisierung ----------

local CREATE_TABLE = [[
CREATE TABLE IF NOT EXISTS policedash_measurements (
  id           VARCHAR(20) PRIMARY KEY,
  mode         VARCHAR(10) NOT NULL,
  created_at   TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  officer_id   VARCHAR(64),
  officer_name VARCHAR(100),
  target_plate VARCHAR(12),
  target_model VARCHAR(50),
  street       VARCHAR(100),
  measured     DECIMAL(6,1),
  tolerance    DECIMAL(5,1),
  chargeable   DECIMAL(6,1),
  unit         VARCHAR(4),
  duration     DECIMAL(6,2),
  distance     DECIMAL(8,1),
  image_url    VARCHAR(255),
  video_url    VARCHAR(255),
  data         LONGTEXT,
  INDEX idx_policedash_plate (target_plate)
)]]

local function counterKey()
    return 'counter:' .. os.date('%Y')
end

-- Muss in einem Thread laufen (wartet auf die DB)
function Storage.init()
    local setting = Config.Storage.database
    local available = Utils.isStarted('oxmysql')
    Storage.db = (setting == true or setting == 'auto') and available

    if setting == true and not available then
        print('^3[policedash] Config.Storage.database = true, aber oxmysql laeuft nicht - nutze KVP.^0')
    end
    if not Storage.db then return end

    -- Migration vom Arbeitstitel (bis 0.1.0-alpha intern "provida"): alte Tabelle samt Messungen uebernehmen.
    -- Der Messnummern-Zaehler folgt unten automatisch aus der hoechsten Nummer in der Tabelle.
    local old = dbQuery("SHOW TABLES LIKE 'provida_measurements'")
    local new = dbQuery("SHOW TABLES LIKE 'policedash_measurements'")
    if old and old[1] and not (new and new[1]) then
        dbQuery('RENAME TABLE provida_measurements TO policedash_measurements')
        print('^2[policedash] Tabelle provida_measurements -> policedash_measurements uebernommen.^0')
    end

    dbQuery(CREATE_TABLE)

    -- Zaehler mit der DB abgleichen, falls die KVP-Datei verloren ging
    local year = os.date('%Y')
    local rows = dbQuery('SELECT id FROM policedash_measurements WHERE id LIKE ? ORDER BY id DESC LIMIT 1',
        { ('PV-%s-%%'):format(year) })
    local last = rows and rows[1] and tonumber(rows[1].id:match('(%d+)$'))
    if last and last > GetResourceKvpInt(counterKey()) then
        SetResourceKvpInt(counterKey(), last)
    end
end

function Storage.nextId()
    local key = counterKey()
    local n = GetResourceKvpInt(key) + 1
    SetResourceKvpInt(key, n)
    return ('PV-%s-%06d'):format(os.date('%Y'), n)
end

-- ---------- Schreiben ----------

function Storage.insert(record)
    remember(record)

    if Storage.db then
        local target = record.target or {}
        dbExecute([[INSERT INTO policedash_measurements
            (id, mode, officer_id, officer_name, target_plate, target_model, street,
             measured, tolerance, chargeable, unit, duration, distance, data)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]], {
            record.id, record.mode, record.officer.identifier, record.officer.name,
            target.plate and normalizePlate(target.plate), target.model, record.location.street,
            record.measured, record.tolerance, record.chargeable, record.unit,
            record.duration, record.distance, json.encode(record),
        })
        return
    end

    SetResourceKvp('m:' .. record.id, json.encode(record))
    if record.target and record.target.plate then
        local key = 'p:' .. normalizePlate(record.target.plate)
        local ids = decode(GetResourceKvpString(key)) or {}
        table.insert(ids, 1, record.id)
        while #ids > PLATE_INDEX_SIZE do table.remove(ids) end
        SetResourceKvp(key, json.encode(ids))
    end
end

function Storage.updateEvidence(record)
    remember(record)
    if Storage.db then
        dbExecute('UPDATE policedash_measurements SET image_url = ?, video_url = ?, data = ? WHERE id = ?', {
            record.evidence.image, record.evidence.video, json.encode(record), record.id,
        })
    else
        SetResourceKvp('m:' .. record.id, json.encode(record))
    end
end

-- ---------- Lesen ----------
-- Mit cb: asynchron, inkl. Datenbank. Ohne cb: synchron aus Cache bzw. KVP (DB-Eintraege nur, wenn im Cache).

local function getSync(id)
    return cache[id] or (not Storage.db and decode(GetResourceKvpString('m:' .. id))) or nil
end

function Storage.get(id, cb)
    if type(id) ~= 'string' then
        if cb then cb(nil) end
        return nil
    end
    if not cb then return getSync(id) end

    local record = getSync(id)
    if record or not Storage.db then return cb(record) end
    CreateThread(function()
        local rows = dbQuery('SELECT data FROM policedash_measurements WHERE id = ?', { id })
        cb(rows and rows[1] and decode(rows[1].data))
    end)
end

local function byPlateSync(plate, limit)
    local result = {}
    if Storage.db then
        for i = #cacheOrder, 1, -1 do
            local record = cache[cacheOrder[i]]
            if record.target and normalizePlate(record.target.plate) == plate then
                result[#result + 1] = record
                if #result >= limit then break end
            end
        end
        return result
    end

    for _, id in ipairs(decode(GetResourceKvpString('p:' .. plate)) or {}) do
        local record = getSync(id)
        if record then result[#result + 1] = record end
        if #result >= limit then break end
    end
    return result
end

function Storage.byPlate(plate, limit, cb)
    if type(plate) ~= 'string' then
        if cb then cb({}) end
        return {}
    end
    plate = normalizePlate(plate)
    limit = math.min(tonumber(limit) or 10, 100)

    if not cb then return byPlateSync(plate, limit) end
    if not Storage.db then return cb(byPlateSync(plate, limit)) end

    CreateThread(function()
        local rows = dbQuery('SELECT data FROM policedash_measurements WHERE target_plate = ? ORDER BY created_at DESC LIMIT ?',
            { plate, limit }) or {}
        local result = {}
        for _, row in ipairs(rows) do result[#result + 1] = decode(row.data) end
        cb(result)
    end)
end

-- ---------- Discord-Webhook ----------

local function speedText(value, unit)
    return ('%s %s'):format(value, Utils.unitLabel(unit))
end

local function buildEmbed(record)
    local target = record.target
    local loc = record.location
    local place = loc.street or '?'
    if loc.crossing then place = place .. ' / ' .. loc.crossing end
    if loc.zone then place = place .. ', ' .. loc.zone end

    return {
        title = _L('wh_title', record.id),
        color = Config.Discord.color,
        timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ', record.timestamp),
        fields = {
            { name = _L('wh_mode'),        value = _L('mode_' .. record.mode), inline = true },
            { name = _L('wh_officer'),     value = record.officer.name or '?', inline = true },
            { name = _L('wh_target'),      value = target and ('%s (%s)'):format(target.plate, target.label) or '-', inline = true },
            { name = _L('wh_location'),    value = place, inline = false },
            { name = _L('res_measured'),   value = speedText(record.measured, record.unit), inline = true },
            { name = _L('res_tolerance'),  value = speedText(record.tolerance, record.unit), inline = true },
            { name = _L('res_chargeable'), value = '**' .. speedText(record.chargeable, record.unit) .. '**', inline = true },
            { name = _L('res_duration'),   value = ('%.1f s'):format(record.duration), inline = true },
            { name = _L('res_distance'),   value = ('%.0f m'):format(record.distance), inline = true },
        },
    }
end

local function webhookUrl()
    if not Config.Discord.enabled then return nil end
    local url = GetConvar('policedash_discord_webhook', '')
    return url ~= '' and url or nil
end

-- Sendet das Embed. Mit imageData (JPEG-Bytes) wird das Bild in derselben Nachricht angehaengt;
-- cb(url) bekommt dann die Discord-URL des Anhangs.
function Webhook.send(record, imageData, cb)
    cb = cb or function() end
    local url = webhookUrl()
    if not url then return cb(nil) end

    local embed = buildEmbed(record)
    if record.evidence.image and not imageData then
        embed.image = { url = record.evidence.image }
    end
    if record.evidence.video then
        embed.fields[#embed.fields + 1] = { name = _L('wh_video'), value = record.evidence.video, inline = false }
    end
    local payload = { username = Config.Discord.username or _L('title'), embeds = { embed } }

    if not imageData then
        PerformHttpRequest(url, function(status)
            if status < 200 or status >= 300 then print(('^3[policedash] Discord-Webhook: HTTP %s^0'):format(status)) end
            cb(nil)
        end, 'POST', json.encode(payload), { ['Content-Type'] = 'application/json' })
        return
    end

    local filename = record.id .. '.jpg'
    embed.image = { url = 'attachment://' .. filename }
    local body, contentType = Upload.multipart({
        { name = 'payload_json', contentType = 'application/json', data = json.encode(payload) },
        { name = 'files[0]', filename = filename, contentType = 'image/jpeg', data = imageData },
    })

    PerformHttpRequest(url .. (url:find('?', 1, true) and '&' or '?') .. 'wait=true', function(status, response)
        if status < 200 or status >= 300 then
            print(('^3[policedash] Discord-Webhook (Bild): HTTP %s^0'):format(status))
            return cb(nil)
        end
        local message = decode(response)
        local attachment = message and message.attachments and message.attachments[1]
        cb(attachment and attachment.url or nil)
    end, 'POST', body, { ['Content-Type'] = contentType })
end

-- ---------- HTTP-Export ans MDT ----------

function Export.send(record)
    local cfg = Config.Export
    if not cfg.enabled or cfg.url == '' then return end

    local body = json.encode(record)
    local headers = {
        ['Content-Type'] = 'application/json',
        ['X-API-Key'] = GetConvar('policedash_export_key', ''),
    }

    local function attempt(n)
        PerformHttpRequest(cfg.url, function(status)
            if status >= 200 and status < 300 then return end
            if n < 2 then
                SetTimeout(5000, function() attempt(n + 1) end)
            else
                print(('^3[policedash] Export %s fehlgeschlagen: HTTP %s^0'):format(record.id, status))
            end
        end, 'POST', body, headers)
    end
    attempt(1)
end
