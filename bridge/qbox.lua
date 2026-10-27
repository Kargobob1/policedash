-- Qbox (qbx_core). PlayerData entspricht qb-core, Helfer kommen aus bridge/qb.lua.
Bridge.register('qbox', {
    resource = 'qbx_core',

    server = function()
        local helpers = Bridge.qbHelpers
        local function data(src)
            local player = exports.qbx_core:GetPlayer(src)
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
