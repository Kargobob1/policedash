-- Gemeinsame Hilfsfunktionen: Rundung, Einheiten, Toleranz, Formatierung
Utils = {}

-- Chat-/Konsolenbefehle: englischer und deutscher Name, beide immer aktiv
COMMAND_NAMES = { 'policedash', 'poldash' }

local KMH_PER_MPH = 1.609344

function Utils.round(value, decimals)
    local m = 10 ^ (decimals or 0)
    return math.floor(value * m + 0.5) / m
end

function Utils.trim(str)
    return (tostring(str or ''):gsub('^%s+', ''):gsub('%s+$', ''))
end

-- Optionale Resource verfuegbar?
function Utils.isStarted(resource)
    return GetResourceState(resource) == 'started'
end

-- m/s (GetEntitySpeed) -> konfigurierte Einheit
function Utils.msToUnit(ms, unit)
    unit = unit or Config.Units
    return unit == 'mph' and ms * 3.6 / KMH_PER_MPH or ms * 3.6
end

function Utils.toKmh(speed, unit)
    return (unit or Config.Units) == 'mph' and speed * KMH_PER_MPH or speed
end

function Utils.fromKmh(kmh, unit)
    return (unit or Config.Units) == 'mph' and kmh / KMH_PER_MPH or kmh
end

-- Toleranzabzug. Die Grenzen (100 km/h, km/h-Abzug) sind in km/h definiert,
-- bei mph wird umgerechnet. Rueckgabe: vorwerfbar, Toleranz (beide in 'unit').
function Utils.applyTolerance(speed, unit)
    unit = unit or Config.Units
    local kmh = Utils.toKmh(speed, unit)
    local tolKmh = kmh < 100 and Config.Tolerance.under100Kmh
        or kmh * Config.Tolerance.overPercent / 100
    local tolerance = Utils.fromKmh(tolKmh, unit)
    local result = math.max(0, speed - tolerance)
    local chargeable = Config.Tolerance.roundDown and math.floor(result) or Utils.round(result, 1)
    return chargeable, Utils.round(tolerance, 1)
end

function Utils.unitLabel(unit)
    return (unit or Config.Units) == 'mph' and 'mph' or 'km/h'
end

function Utils.formatSpeed(speed, unit)
    return ('%d %s'):format(math.floor(speed + 0.5), Utils.unitLabel(unit))
end

function Utils.debug(...)
    if Config.Debug then
        print('^3[policedash]^0', ...)
    end
end
