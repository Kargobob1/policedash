-- Update-Check gegen GitHub Releases. Repo kommt aus fxmanifest (policedash_repo 'owner/name').
if not Config.VersionCheck then return end

local RESOURCE = GetCurrentResourceName()
local current = GetResourceMetadata(RESOURCE, 'version', 0) or '0.0.0'
local repo = GetResourceMetadata(RESOURCE, 'policedash_repo', 0) or ''

-- '0.1.0-alpha' -> { 0, 1, 0, pre = 'alpha' }. Vorabversionen sind aelter als die fertige Version.
local function parse(version)
    local text = tostring(version)
    local major, minor, patch = text:match('(%d+)%.(%d+)%.?(%d*)')
    local pre = text:match('%d[%-%+]?([%a][%w%.]*)$')
    return { tonumber(major) or 0, tonumber(minor) or 0, tonumber(patch) or 0, pre = pre and pre:lower() }
end

local function isNewer(latest, installed)
    local a, b = parse(latest), parse(installed)
    for i = 1, 3 do
        if a[i] ~= b[i] then return a[i] > b[i] end
    end
    if a.pre == b.pre then return false end
    if not a.pre then return true end    -- fertig vs. Vorabversion
    if not b.pre then return false end
    return a.pre > b.pre                 -- alpha < beta < rc
end

if repo == '' then return end

CreateThread(function()
    Wait(5000)
    local url = ('https://api.github.com/repos/%s/releases/latest'):format(repo)
    PerformHttpRequest(url, function(status, body)
        if status ~= 200 or not body then return end
        local ok, release = pcall(json.decode, body)
        if not ok or type(release) ~= 'table' or not release.tag_name then return end

        if isNewer(release.tag_name, current) then
            print(('^3[policedash] Neue Version %s verfuegbar (installiert: %s): %s^0'):format(
                release.tag_name, current, release.html_url or ('https://github.com/' .. repo)))
        end
    end, 'GET', '', { ['User-Agent'] = RESOURCE, ['Accept'] = 'application/vnd.github+json' })
end)
