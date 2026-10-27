-- ESX (es_extended)
Bridge.register('esx', {
    resource = 'es_extended',

    server = function()
        local ESX = exports['es_extended']:getSharedObject()

        return {
            getJob = function(src)
                local xPlayer = ESX.GetPlayerFromId(src)
                if not xPlayer or not xPlayer.job then return nil end
                return {
                    name   = xPlayer.job.name,
                    grade  = tonumber(xPlayer.job.grade) or 0,
                    onDuty = xPlayer.job.onDuty,   -- nur neuere ESX-Versionen, sonst nil
                }
            end,
            getName = function(src)
                local xPlayer = ESX.GetPlayerFromId(src)
                return xPlayer and xPlayer.getName()
            end,
            getIdentifier = function(src)
                local xPlayer = ESX.GetPlayerFromId(src)
                return xPlayer and xPlayer.identifier
            end,
        }
    end,

    client = function()
        RegisterNetEvent('esx:setJob', Bridge.invalidateAccess)
        RegisterNetEvent('esx:playerLoaded', Bridge.invalidateAccess)
        return {}
    end,
})
