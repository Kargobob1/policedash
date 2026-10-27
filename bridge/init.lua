-- Framework-Bridge: Erkennung und gemeinsame API.
-- Framework-Dateien melden sich per Bridge.register an, Bridge.load() waehlt eins aus.
--
-- Server-API:  Bridge.hasAccess(src), Bridge.getOfficer(src)
-- Client-API:  Bridge.invalidateAccess() (von Framework-Dateien bei Jobwechsel aufgerufen)
Bridge = {
    name = nil,
    impl = {},
}

local definitions = {}
local isServer = IsDuplicityVersion()

-- Reihenfolge fuer 'auto'. qbox zuerst, weil qbx_core sich auch als qb-core ausgibt.
local AUTO_ORDER = { 'qbox', 'esx', 'qb' }

function Bridge.register(name, definition)
    definitions[name] = definition
end

local function isAvailable(name)
    local def = definitions[name]
    return def and (not def.resource or Utils.isStarted(def.resource))
end

local function detect()
    local wanted = Config.Framework or 'auto'
    if wanted ~= 'auto' then
        if isAvailable(wanted) then return wanted end
        print(('^3[policedash] Framework "%s" konfiguriert, aber nicht verfuegbar - nutze standalone.^0'):format(wanted))
        return 'standalone'
    end
    for _, name in ipairs(AUTO_ORDER) do
        if isAvailable(name) then return name end
    end
    return 'standalone'
end

function Bridge.load()
    Bridge.name = detect()
    local def = definitions[Bridge.name]
    local factory = def[isServer and 'server' or 'client']
    Bridge.impl = factory and factory() or {}
    Utils.debug('Framework erkannt:', Bridge.name)
end

if isServer then
    -- Hat der Spieler einen der Jobs (job = Mindestrang)?
    function Bridge.hasJob(src, jobs)
        local job = Bridge.impl.getJob and Bridge.impl.getJob(src)
        if not job or not jobs then return false end

        local minGrade = jobs[job.name]
        if not minGrade or (job.grade or 0) < minGrade then return false end
        if Config.RequireOnDuty and job.onDuty == false then return false end
        return true
    end

    -- Job-Berechtigung laut Config.Jobs, die ACE-Permission gilt immer zusaetzlich
    function Bridge.hasAccess(src)
        if Config.AcePermission and IsPlayerAceAllowed(tostring(src), Config.AcePermission) then
            return true
        end
        return Bridge.hasJob(src, Config.Jobs)
    end

    function Bridge.getOfficer(src)
        local impl = Bridge.impl
        return {
            identifier = (impl.getIdentifier and impl.getIdentifier(src))
                or GetPlayerIdentifierByType(src, 'license')
                or ('player:' .. src),
            name = (impl.getName and impl.getName(src)) or GetPlayerName(src),
        }
    end
else
    function Bridge.invalidateAccess()
        TriggerEvent('policedash:client:accessInvalidated')
    end
end
