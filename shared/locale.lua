-- Lokalisierung: _L('key', ...) mit Fallback auf 'en', danach auf den Key selbst
Locales = {}

function _L(key, ...)
    local active = Locales[Config.Locale]
    local str = (active and active[key]) or (Locales.en and Locales.en[key]) or key
    if select('#', ...) > 0 then
        return str:format(...)
    end
    return str
end

-- Komplette Tabelle (en als Basis, aktive Sprache darueber) fuer das NUI
function GetLocaleTable()
    local result = {}
    for k, v in pairs(Locales.en or {}) do result[k] = v end
    for k, v in pairs(Locales[Config.Locale] or {}) do result[k] = v end
    return result
end
