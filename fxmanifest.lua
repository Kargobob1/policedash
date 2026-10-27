fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'policedash'
description 'PoliceDash (PolDash) - dashcam and speed measurement for police RP / Dashcam und Geschwindigkeitsmessung'
author 'Kargobob1/Excurse'
version '0.1.0-alpha'   -- Alpha: Funktionen vollstaendig, Bild-im-Bild noch in Erprobung

-- GitHub-Repo fuer den Update-Check ('owner/name'), leer = kein Check
policedash_repo 'Kargobob1/policedash'

-- Asset Escrow (Cfx Portal): diese Dateien bleiben lesbar und anpassbar, der Rest wird verschluesselt.
-- Das NUI (web/) ist ohnehin nie verschluesselt, nur Lua-Dateien werden geschuetzt.
escrow_ignore {
    'config.lua',
    'locales/*.lua',
    'bridge/*.lua',   -- eigene Frameworks anbinden
}

-- Keine harten Abhaengigkeiten: ox_lib, oxmysql, screencapture und Frameworks
-- werden zur Laufzeit erkannt (siehe bridge/init.lua).

shared_scripts {
    'config.lua',
    'shared/locale.lua',
    'locales/*.lua',
    'shared/utils.lua',
    'shared/callback.lua',
    'bridge/init.lua',
    'bridge/esx.lua',
    'bridge/qb.lua',
    'bridge/qbox.lua',
    'bridge/standalone.lua',
}

client_scripts {
    'client/main.lua',
    'client/history.lua',
    'client/nui.lua',
    'client/camera.lua',
    'client/target.lua',
    'client/measure.lua',
    'client/measure_man.lua',
    'client/measure_vascar.lua',
    'client/evidence.lua',
    'client/panel.lua',
    'client/pip.lua',
    'client/playback.lua',
    'client/sync.lua',
}

server_scripts {
    'server/storage.lua',
    'server/upload.lua',
    'server/playback.lua',
    'server/version.lua',
    'server/main.lua',
}

ui_page 'web/index.html'

files {
    'web/index.html',
    'web/style.css',
    'web/app.js',
    'web/osd.js',
    'web/trackmap.js',
    'web/pip.js',
    'web/recorder.js',
}
