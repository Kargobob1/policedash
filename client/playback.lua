-- Messvideos ansehen und vorfuehren.
--   /policedash play <Messnummer>    nur selbst ansehen (z.B. Richter, Anwalt)
--   /policedash show [Messnummer]    allen im Umkreis vorfuehren (ohne Nummer: letzte eigene Messung)
-- Das Videofenster braucht keinen Mausfokus; geschlossen wird per Taste (Standard Ruecktaste).

local function request(id, nearby)
    if type(id) ~= 'string' or id == '' then
        Notify(_L('play_usage'), 'error')
        return
    end
    local response = Callback.await('playVideo', 20000, id:upper(), nearby)
    if not response then
        Notify(_L('submit_timeout'), 'error')
    elseif not response.ok then
        Notify(_L(response.reason or 'play_not_found'), 'error')
    elseif nearby then
        Notify(_L('play_shown', math.max(0, (response.count or 1) - 1)), 'success')
    end
end

Subcommands.play = function(args)
    CreateThread(function() request(args[1], false) end)
end

Subcommands.show = function(args)
    CreateThread(function()
        local id = args[1] or (State.lastMeasurement and State.lastMeasurement.id)
        request(id, true)
    end)
end

-- Aus dem Bedienteil (Historie): { id, nearby }
RegisterNUICallback('playback', function(data, cb)
    cb('ok')
    if type(data) ~= 'table' or type(data.id) ~= 'string' then return end
    CreateThread(function() request(data.id, data.nearby == true) end)
end)

-- Server startet die Wiedergabe. info: Messdaten + url (https) oder chunks (Anzahl folgender Stuecke)
RegisterNetEvent('policedash:client:playVideo', function(info, own)
    if type(info) ~= 'table' or type(info.id) ~= 'string' then return end
    if info.url ~= nil and (type(info.url) ~= 'string' or not info.url:match('^https://')) then return end
    NUI.send('player:open', info)
    if not own then Notify(_L('play_shown_by', tostring(info.shownBy or '?')), 'info') end
end)

RegisterNetEvent('policedash:client:videoChunk', function(id, index, total, chunk)
    if type(id) ~= 'string' or type(chunk) ~= 'string' then return end
    NUI.send('player:chunk', { id = id, index = index, total = total, chunk = chunk })
end)

RegisterCommand('policedash_closevideo', function()
    NUI.send('player:close')
end, false)
RegisterKeyMapping('policedash_closevideo', _L('key_close_video'), 'keyboard', Config.Keys.closeVideo)
