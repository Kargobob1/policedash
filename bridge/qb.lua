-- QBCore (qb-core)

-- Gemeinsam mit qbox genutzt: PlayerData hat dort dieselbe Struktur
Bridge.qbHelpers = {
    jobFromPlayerData = function(data)
        if not data or not data.job then return nil end
        local grade = data.job.grade
        return {
            name   = data.job.name,
            grade  = tonumber(type(grade) == 'table' and grade.level or grade) or 0,
            onDuty = data.job.onduty,
        }
    end,
    nameFromPlayerData = function(data)
        local info = data and data.charinfo
        if not info then return nil end
        return ('%s %s'):format(info.firstname or '', info.lastname or '')
    end,
    registerClientEvents = function()
        RegisterNetEvent('QBCore:Client:OnJobUpdate', Bridge.invalidateAccess)
        RegisterNetEvent('QBCore:Client:OnPlayerLoaded', Bridge.invalidateAccess)
        RegisterNetEvent('QBCore:Client:SetDuty', Bridge.invalidateAccess)
    end,
}

Bridge.register('qb', {
    resource = 'qb-core',

    server = function()
        local QBCore = exports['qb-core']:GetCoreObject()
        local helpers = Bridge.qbHelpers
        local function data(src)
            local player = QBCore.Functions.GetPlayer(src)
            return player and player.PlayerData
        end

        return {
            getJob        = function(src) return helpers.jobFromPlayerData(data(src)) end,
            getName       = function(src) return helpers.nameFromPlayerData(data(src)) end,
            getIdentifier = function(src) local d = data(src); return d and d.citizenid end,
        }
    end,

    client = function()
        Bridge.qbHelpers.registerClientEvents()
        return {}
    end,
})
