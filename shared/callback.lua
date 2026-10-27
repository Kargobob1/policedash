-- Schlanke Callbacks Client -> Server -> Client, unabhaengig von ox_lib.
-- Server-Handler bekommen (source, ...) und muessen ihre Argumente selbst validieren.
Callback = {}

local resource = GetCurrentResourceName()
local REQUEST  = resource .. ':cb:request'
local RESPONSE = resource .. ':cb:response'

if IsDuplicityVersion() then
    local handlers = {}

    function Callback.register(name, handler)
        handlers[name] = handler
    end

    RegisterNetEvent(REQUEST, function(name, id, ...)
        local src = source
        local handler = handlers[name]
        if type(id) ~= 'number' or not handler then return end

        local ok, result = pcall(handler, src, ...)
        if not ok then
            print(('^1[policedash] callback "%s" failed: %s^0'):format(name, result))
            result = nil
        end
        TriggerClientEvent(RESPONSE, src, id, result)
    end)
else
    local pending, nextId = {}, 0

    RegisterNetEvent(RESPONSE, function(id, result)
        local p = pending[id]
        if p then
            pending[id] = nil
            p:resolve(result)
        end
    end)

    -- Muss in einem Thread laufen. Liefert nil bei Timeout.
    function Callback.await(name, timeoutMs, ...)
        nextId = nextId + 1
        local id = nextId
        local p = promise.new()
        pending[id] = p

        TriggerServerEvent(REQUEST, name, id, ...)
        SetTimeout(timeoutMs or 10000, function()
            if pending[id] then
                pending[id] = nil
                p:resolve(nil)
            end
        end)

        return Citizen.Await(p)
    end
end
