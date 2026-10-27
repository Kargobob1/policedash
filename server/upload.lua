-- Beweis-Uploads. API-Keys und Webhooks existieren nur hier (ConVars), nie am Client.
--
-- Foto:  screencapture -> remoteUpload (serverseitiger Upload, dokumentierte API)
--        sonst screenshot-basic -> requestClientScreenshot (Data-URI) + eigener multipart-Upload
--        provider 'discord' -> Bild geht zusammen mit dem Embed an den Webhook
-- Video: nur screencapture (startVideoCaptureUpload / stopVideoCapture), nur fivemanage/custom
Upload = {}

local FIVEMANAGE_URL = 'https://api.fivemanage.com/api/v3/file'

local videos = {}   -- src -> { id, done, url, onDone }
local warned = {}

local function warnOnce(key, message)
    if warned[key] then return end
    warned[key] = true
    print('^3[policedash] ' .. message .. '^0')
end

-- Ziel fuer multipart-Uploads (fivemanage/custom). nil = nicht konfiguriert.
local function uploadTarget(provider)
    if provider == 'fivemanage' then
        local key = GetConvar('policedash_fivemanage_key', '')
        if key == '' then
            warnOnce('fm', 'provider fivemanage, aber ConVar policedash_fivemanage_key ist leer.')
            return nil
        end
        return { url = FIVEMANAGE_URL, headers = { ['Authorization'] = key } }
    elseif provider == 'custom' then
        if Config.Evidence.customUrl == '' then
            warnOnce('custom', 'provider custom, aber Config.Evidence.customUrl ist leer.')
            return nil
        end
        return { url = Config.Evidence.customUrl, headers = { ['X-API-Key'] = GetConvar('policedash_upload_key', '') } }
    end
    return nil
end

-- URL aus der Antwort ziehen (Tabelle oder JSON-String; fivemanage: data.url)
local function extractUrl(response)
    if type(response) == 'string' then
        local ok, decoded = pcall(json.decode, response)
        response = ok and decoded or nil
    end
    if type(response) ~= 'table' then return nil end
    local url = (type(response.data) == 'table' and response.data.url) or response.url
    return type(url) == 'string' and url:match('^https?://') and url or nil
end

-- ---------- multipart / base64 ----------

local B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local b64Lookup = {}
for i = 1, #B64 do b64Lookup[B64:byte(i)] = i - 1 end

-- Grosse Videos in Bloecken verarbeiten (eine Tabelle pro Byte wuerde Hunderte MB belegen)
-- und zwischendurch abgeben, damit der Server-Tick nicht steht. Gibt nur ab, wo das erlaubt ist.
local B64_BLOCK = 16384   -- 4er-Gruppen pro Block

local function yieldBlock()
    if coroutine.isyieldable() then Wait(0) end
end

local function base64Decode(data)
    data = data:gsub('^data:[^,]*,', ''):gsub('[^%w%+/]', '')
    local pad = (4 - #data % 4) % 4
    if pad == 3 then data = data:sub(1, -2); pad = 0 end   -- ungueltiger Rest
    data = data .. ('A'):rep(pad)

    local out, block = {}, {}
    local char, byte = string.char, string.byte
    local len = #data
    for i = 1, len, 4 do
        local a, b, c, d = byte(data, i, i + 3)
        local n = (b64Lookup[a] << 18) | (b64Lookup[b] << 12) | (b64Lookup[c] << 6) | b64Lookup[d]
        block[#block + 1] = char((n >> 16) & 0xFF, (n >> 8) & 0xFF, n & 0xFF)
        if #block >= B64_BLOCK then
            out[#out + 1] = table.concat(block)
            block = {}
            yieldBlock()
        end
    end
    out[#out + 1] = table.concat(block)
    local result = table.concat(out)
    return pad > 0 and result:sub(1, -pad - 1) or result
end

function Upload.base64Encode(data)
    local out, block = {}, {}
    local len = #data
    for i = 1, len, 3 do
        local a, b, c = data:byte(i, i + 2)
        local n = (a << 16) | ((b or 0) << 8) | (c or 0)
        local c1 = (n >> 18) & 63
        local c2 = (n >> 12) & 63
        local c3 = (n >> 6) & 63
        local c4 = n & 63
        block[#block + 1] = B64:sub(c1 + 1, c1 + 1) .. B64:sub(c2 + 1, c2 + 1)
            .. (b and B64:sub(c3 + 1, c3 + 1) or '=') .. (c and B64:sub(c4 + 1, c4 + 1) or '=')
        if #block >= B64_BLOCK then
            out[#out + 1] = table.concat(block)
            block = {}
            yieldBlock()
        end
    end
    out[#out + 1] = table.concat(block)
    return table.concat(out)
end

-- parts: { { name, data, filename?, contentType? } } -> body, Content-Type-Header
function Upload.multipart(parts)
    local boundary = ('----policedash%d%d'):format(os.time(), math.random(100000, 999999))
    local chunks = {}
    for _, part in ipairs(parts) do
        local disposition = ('Content-Disposition: form-data; name="%s"'):format(part.name)
        if part.filename then disposition = disposition .. ('; filename="%s"'):format(part.filename) end
        chunks[#chunks + 1] = '--' .. boundary .. '\r\n' .. disposition .. '\r\n'
        if part.contentType then chunks[#chunks + 1] = 'Content-Type: ' .. part.contentType .. '\r\n' end
        chunks[#chunks + 1] = '\r\n' .. part.data .. '\r\n'
    end
    chunks[#chunks + 1] = '--' .. boundary .. '--\r\n'
    return table.concat(chunks), 'multipart/form-data; boundary=' .. boundary
end

-- ---------- Foto ----------

-- Bild vom Client holen, cb(jpegBytes | nil)
local function captureImage(src, cb)
    if Utils.isStarted('screencapture') then
        exports.screencapture:serverCapture(src, { encoding = 'jpg' }, function(data)
            cb(type(data) == 'string' and base64Decode(data) or nil)
        end)
    elseif Utils.isStarted('screenshot-basic') then
        exports['screenshot-basic']:requestClientScreenshot(src, { encoding = 'jpg', quality = 0.85 }, function(err, data)
            cb(not err and type(data) == 'string' and base64Decode(data) or nil)
        end)
    else
        warnOnce('noshot', 'Weder screencapture noch screenshot-basic gestartet - keine Beweisfotos.')
        cb(nil)
    end
end

-- Foto zur Messung aufnehmen und hochladen. cb(url | nil, webhookSent)
function Upload.screenshot(src, record, cb)
    local provider = Config.Evidence.provider
    if not Config.Evidence.screenshot or provider == 'none' then return cb(nil, false) end

    if provider == 'discord' then
        captureImage(src, function(image)
            if not image then return cb(nil, false) end
            Webhook.send(record, image, function(url) cb(url, true) end)
        end)
        return
    end

    local target = uploadTarget(provider)
    if not target then return cb(nil, false) end

    if Utils.isStarted('screencapture') then
        exports.screencapture:remoteUpload(src, target.url, {
            encoding  = 'jpg',
            headers   = target.headers,
            formField = 'file',
            filename  = record.id,
        }, function(response)
            cb(extractUrl(response), false)
        end)
        return
    end

    captureImage(src, function(image)
        if not image then return cb(nil, false) end
        local body, contentType = Upload.multipart({
            { name = 'file', filename = record.id .. '.jpg', contentType = 'image/jpeg', data = image },
        })
        local headers = { ['Content-Type'] = contentType }
        for k, v in pairs(target.headers) do headers[k] = v end

        PerformHttpRequest(target.url, function(status, response)
            if status < 200 or status >= 300 then
                print(('^3[policedash] Upload %s fehlgeschlagen: HTTP %s^0'):format(record.id, status))
                return cb(nil, false)
            end
            cb(extractUrl(response), false)
        end, 'POST', body, headers)
    end)
end

-- ---------- Video ----------

local function videoAvailable()
    if not Config.Evidence.video or Config.Evidence.videoSource ~= 'screencapture' then return false end
    if not Utils.isStarted('screencapture') then
        warnOnce('novideo', 'Config.Evidence.video = true, aber screencapture laeuft nicht.')
        return false
    end
    return true
end

function Upload.abortVideo(src)
    local entry = videos[src]
    videos[src] = nil
    if entry and not entry.done and entry.id and exports.screencapture:isVideoCaptureActive(entry.id) then
        exports.screencapture:stopVideoCapture(entry.id)
    end
end

function Upload.startVideo(src)
    if not videoAvailable() then return end
    local target = uploadTarget(Config.Evidence.provider)
    if not target then
        warnOnce('videoprov', 'Video-Upload braucht provider fivemanage oder custom.')
        return
    end

    Upload.abortVideo(src)
    local entry = {}
    entry.id = exports.screencapture:startVideoCaptureUpload(src, target.url, {
        duration  = Config.Evidence.videoMaxSeconds,
        maxWidth  = 1280,
        maxHeight = 720,
        headers   = target.headers,
        formField = 'file',
        filename  = ('policedash-%d-%d'):format(src, os.time()),
    }, function(result)
        entry.done = true
        if type(result) == 'table' and result.status == 'success' then
            entry.url = extractUrl(result.response)
        elseif type(result) == 'table' then
            print(('^3[policedash] Video fehlgeschlagen: %s^0'):format(result.error or 'unknown'))
        end
        if entry.onDone then entry.onDone(entry.url) end
    end)
    videos[src] = entry
end

function Upload.hasVideo(src)
    return videos[src] ~= nil
end

-- Aufnahme beenden, cb(url | nil) sobald der Upload fertig ist
function Upload.stopVideo(src, cb)
    local entry = videos[src]
    videos[src] = nil
    if not entry then return cb(nil) end
    if entry.done then return cb(entry.url) end

    entry.onDone = cb
    if entry.id and exports.screencapture:isVideoCaptureActive(entry.id) then
        exports.screencapture:stopVideoCapture(entry.id)
    end
end

-- ---------- NUI-Video (videoSource 'nui') ----------
-- Der Client schickt die WebM-Datei als Base64 in Stuecken. Erst wenn alle da sind, wird
-- zusammengesetzt, lokal gespeichert und (optional) hochgeladen.

local incoming = {}   -- src -> id -> { total, parts, count }

local function maxChunks()
    local cfg = Config.Evidence
    return math.ceil(cfg.videoMaxMB * 1024 * 1024 * 4 / 3 / cfg.videoChunkSize) + 1
end

-- Video an den Discord-Webhook (eigene Nachricht mit Messnummer), cb(url | nil)
local function videoToDiscord(record, bytes, cb)
    local url = Config.Discord.enabled and GetConvar('policedash_discord_webhook', '') or ''
    if url == '' then return cb(nil) end
    local body, contentType = Upload.multipart({
        { name = 'payload_json', contentType = 'application/json',
          data = json.encode({ username = Config.Discord.username or _L('title'), content = _L('wh_video_msg', record.id) }) },
        { name = 'files[0]', filename = record.id .. '.webm', contentType = 'video/webm', data = bytes },
    })
    PerformHttpRequest(url .. (url:find('?', 1, true) and '&' or '?') .. 'wait=true', function(status, response)
        if status < 200 or status >= 300 then
            print(('^3[policedash] Discord-Video %s: HTTP %s^0'):format(record.id, status))
            return cb(nil)
        end
        local ok, message = pcall(json.decode, response or '')
        local attachment = ok and type(message) == 'table' and message.attachments and message.attachments[1]
        cb(attachment and attachment.url or nil)
    end, 'POST', body, { ['Content-Type'] = contentType })
end

-- Speichern + Hochladen, cb(url | 'local:<pfad>' | nil)
local function storeVideo(record, bytes, cb)
    local localPath = nil
    if Config.Evidence.videoLocal then
        local path = ('recordings/%s.webm'):format(record.id)
        if SaveResourceFile(GetCurrentResourceName(), path, bytes, #bytes) then
            localPath = path
        else
            print(('^3[policedash] Video %s konnte nicht lokal gespeichert werden.^0'):format(record.id))
        end
    end
    local fallback = localPath and ('local:' .. localPath) or nil

    local provider = Config.Evidence.provider
    if provider == 'discord' then
        return videoToDiscord(record, bytes, function(url) cb(url or fallback) end)
    end

    local target = uploadTarget(provider)
    if not target then return cb(fallback) end

    local body, contentType = Upload.multipart({
        { name = 'file', filename = record.id .. '.webm', contentType = 'video/webm', data = bytes },
    })
    local headers = { ['Content-Type'] = contentType }
    for k, v in pairs(target.headers) do headers[k] = v end

    PerformHttpRequest(target.url, function(status, response)
        if status < 200 or status >= 300 then
            print(('^3[policedash] Video-Upload %s fehlgeschlagen: HTTP %s^0'):format(record.id, status))
            return cb(fallback)
        end
        cb(extractUrl(response) or fallback)
    end, 'POST', body, headers)
end

-- Ein Stueck annehmen. cb(url) wird aufgerufen, sobald das Video komplett gespeichert ist.
function Upload.videoChunk(src, record, index, total, chunk, cb)
    if type(index) ~= 'number' or type(total) ~= 'number' or type(chunk) ~= 'string' then return end
    if total < 1 or total > maxChunks() or index < 1 or index > total or index % 1 ~= 0 then return end
    if #chunk > Config.Evidence.videoChunkSize then return end

    local list = incoming[src] or {}
    incoming[src] = list
    local entry = list[record.id]
    if not entry or entry.total ~= total then
        entry = { total = total, parts = {}, count = 0 }
        list[record.id] = entry
    end
    if entry.parts[index] then return end

    entry.parts[index] = chunk
    entry.count = entry.count + 1
    if entry.count < entry.total then return end

    list[record.id] = nil
    CreateThread(function()
        local bytes = base64Decode(table.concat(entry.parts))
        Utils.debug(('video %s: %d bytes'):format(record.id, #bytes))
        storeVideo(record, bytes, cb)
    end)
end

AddEventHandler('playerDropped', function()
    Upload.abortVideo(source)
    incoming[source] = nil
end)
