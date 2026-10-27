-- Beweise: Foto per Taste, Beweis-Updates vom Server, Weitergabe der NUI-Videoaufnahme.
-- Upload-Ziele und Keys kennt nur der Server; der Client reicht Daten nur weiter.

Actions.photo = function()
    if not Config.Evidence.screenshot or Config.Evidence.provider == 'none' then
        Notify(_L('not_implemented'), 'info')
        return
    end

    local last = State.lastMeasurement
    if not (last and last.id) then
        Notify(_L('photo_no_measurement'), 'error')
        return
    end

    Notify(_L('photo_taking'), 'info')
    local response = Callback.await('photo', 30000, last.id)
    if response and response.ok then
        Notify(_L('photo_saved'), 'success')
    else
        Notify(_L('photo_failed'), 'error')
    end
end

-- Server meldet hochgeladene Bild-/Video-URLs zu einer Messung
RegisterNetEvent('policedash:client:evidence', function(id, evidence)
    if type(id) ~= 'string' or type(evidence) ~= 'table' then return end
    History.setEvidence(id, evidence)
    local last = State.lastMeasurement
    if last and last.id == id then last.evidence = evidence end
end)

RegisterNetEvent('policedash:client:videoSaved', function(id)
    if type(id) == 'string' then Notify(_L('video_saved', id), 'success') end
end)

-- NUI-Videoaufnahme (WebM, Base64) in Stuecken per Latent-Event an den Server.
-- Latent-Events drosseln die Bandbreite, damit das Spiel nicht hakt.
RegisterNUICallback('videoChunk', function(data, cb)
    cb('ok')
    if type(data) ~= 'table' then return end
    local id, index, total, chunk = data.id, tonumber(data.index), tonumber(data.total), data.chunk
    if type(id) ~= 'string' or not index or not total or type(chunk) ~= 'string' then return end
    if #chunk > Config.Evidence.videoChunkSize then return end

    -- Upload kann laenger dauern als die naechste Messung, daher die letzten paar Messungen zulassen
    local recent = false
    for i, entry in ipairs(History.all()) do
        if i > 3 then break end
        if entry.id == id then recent = true break end
    end
    if not recent then return end

    TriggerLatentServerEvent('policedash:server:videoChunk', Config.Evidence.videoBps, id, index, total, chunk)
    if index == total then Notify(_L('video_sending'), 'info') end
end)
