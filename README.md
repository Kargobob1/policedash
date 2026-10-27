# PoliceDash

**Alpha** · Dashcam and speed measurement for police roleplay on FiveM. Called **PolDash** in German.

[Deutsche Version](README.de.md)

> **Alpha:** All features are in place and running on a live test server (ESX Legacy). Expect rough edges,
> especially in picture-in-picture mode. Use it on test or community servers and report bugs.
> Settings and data formats may still change before 1.0.
>
> Bugs and feedback: [GitHub Issues](https://github.com/Kargobob1/policedash/issues) or Discord: Excurse (`execurse2`).

Pacing (MAN) and distance-over-time (VASCAR) measurements with tolerance deduction, measurement log,
evidence photo and video, and MDT integration. No hard dependencies.

## Features

- Windshield dashcam with an on-screen display (date, time, own speed, mode, measured value, timer, target, REC)
- **Picture-in-picture:** drive in your normal view while a small monitor shows the live dashcam
- Target acquisition in a cone in front of the vehicle, reads plate and model
- **MAN (pacing):** average speed over an interval, distance to the target is checked
- **VASCAR (distance over time):** set start and end point, speed = distance / time
- Tolerance deduction (configurable, km/h and mph), result card with a reason for invalid measurements
- **Passenger operation:** whoever turns the device on operates it, the other occupants see the same display
- Mouse-driven control panel: keys, status, history with mini map, personal settings
- **Evidence video** of the dashcam only, with the OSD burned in. No extra resource needed.
- Play back measurement videos in-game, privately or for everyone nearby
- Server-side validation, measurement IDs `PV-2026-000123`, storage in oxmysql or KVP
- Discord webhook, HTTP export to MDT systems, exports and events
- Uploads are server-side only, no API key ever reaches a client
- Idle 0.00 ms: per-frame loops only run while the camera or a measurement is active

## Installation

1. Copy the folder to `resources/policedash`. Keep the folder name `policedash`, the exports and stored data use it.
2. Start it in `server.cfg` **after** the optional dependencies:

```cfg
ensure oxmysql        # optional - measurement log in the database
ensure ox_lib         # optional - notifications
ensure screencapture  # optional - evidence photos (alternatively screenshot-basic)
ensure [framework]    # optional - es_extended, qb-core or qbx_core
ensure policedash

# Secrets go here only, never in config.lua
set policedash_fivemanage_key ""
set policedash_discord_webhook ""
set policedash_upload_key ""     # provider 'custom' only
set policedash_export_key ""     # Config.Export only

# Standalone, or additionally for admins
add_ace group.admin policedash.use allow
```

3. With oxmysql the table is created on start (`sql/install.sql` for manual installs).
4. In game, run `/policedash debug`. The F8 output shows framework, detected resources and permission.
   The server console warns about invalid values in `config.lua` on start.

**Required dependencies: none.** Everything optional is detected at runtime.
OneSync is recommended (needed for passenger operation and position checks).
Game build **2189 or newer** for the stable dashcam mount (`Config.CamAttach = 'hard'`).

## Controls

| Key (default) | Function |
|---|---|
| F7 | Full-screen dashcam on/off |
| F9 | Control panel (mouse), ESC closes it |
| NUMPAD9 | Lock / release target |
| NUMPAD5 | MAN: start/stop · VASCAR: start point, then end point |
| NUMPAD8 | Switch mode |
| NUMPAD2 | Reset / cancel measurement |
| NUMPAD0 | Evidence photo for the last measurement |
| NUMPAD7 | Picture-in-picture monitor live (manual) |
| BACKSPACE | Close the video window |

All keys can be changed under *Settings → Key Bindings → FiveM*.

## Commands

`/policedash` and `/poldash` both work, regardless of language.

| Command | Function |
|---|---|
| `/policedash pip` | Picture-in-picture on/off |
| `/policedash pip live` | Monitor live / standby |
| `/policedash pip fps <10-24>` | Dashcam FPS (monitor and video), saved per player |
| `/policedash play <ID>` | Watch a measurement video yourself (e.g. judge, lawyer) |
| `/policedash show [ID]` | Show a video to everyone nearby (no ID = your last measurement) |
| `/policedash debug` | Diagnostics in F8 (server console: `policedash debug`) |

With `Config.Debug = true`, extra tuning commands are available (`/policedash pip raw|log|hud|cam|…`, `/policedash offset`), see `client/pip.lua`.

**Pacing (MAN):** lock the target, start, follow it at a steady distance (default 10–80 m, up to 30 % variation, 45 % in FunMode), stop after at least 3 s.

**VASCAR:** lock the target. Set the start point when it passes a landmark (e.g. an intersection) and the end point at the second one. The track must be 100–2000 m. The start point is marked on the ground.

## Picture-in-picture (alpha)

FiveM can only render one camera per frame. PoliceDash therefore takes every Nth frame for the dashcam (about 15 per second). Each frame carries a tiny colour tag, and the NUI sorts frames into your view and the monitor. The NUI also blends over the missing frames in your view.

- By default the monitor is only live during a measurement. The rest of the time you see the real game and the monitor shows a still image.
- `liveMode = 'always'` keeps it live all the time at a low rate (`idleFps`).
- The dashcam takes at most `maxSteal` of your frames. At 120 fps your view keeps about 100–105 fps. At low frame rates the monitor FPS drops instead of your view.
- If HUD elements flicker, use `hideHud = 'off'`. The screen edges where the HUD sits are cropped from the monitor anyway.

## Configuration

All options are commented in `config.lua`. The most important ones:

| Option | Meaning |
|---|---|
| `Config.Locale` | `de` (PolDash) or `en` (PoliceDash) |
| `Config.Framework` | `auto`, `esx`, `qb`, `qbox`, `standalone` |
| `Config.Jobs` | job = minimum grade, e.g. `{ police = 0 }` |
| `Config.AcePermission` | ACE that always grants access (`policedash.use`) |
| `Config.Vehicles` | models with camera offset (and optional `fov`), plus class 18 if `AllowEmergencyClass` |
| `Config.CamAttach` | `hard` (stable, build 2189+) or `script` |
| `Config.Units` | `kmh` or `mph` |
| `Config.Tolerance` | deduction below 100 km/h (absolute) and from 100 km/h (percent) |
| `Config.FunMode` | more lenient checks |
| `Config.PiP` | picture-in-picture: `liveMode`, `monitorFps`, `idleFps`, `maxSteal`, `hideHud`, … |
| `Config.Sync` | passenger operation |
| `Config.Overlay` | theme, clock (`ingame`/`real`), size, OSD label (`brand`) |
| `Config.Evidence` | photo/video, provider `fivemanage`, `discord`, `custom`, `none` |
| `Config.Playback` | in-game video playback: radius, who may watch |
| `Config.Storage` | database `auto`/`true`/`false`, history length |
| `Config.Export` | HTTP export to an MDT |
| `Config.Server` | rate limits and validation limits |

**Tuning the camera offset:** set `Config.Debug = true`, get in the vehicle, turn the dashcam on, then try
`/policedash offset 0.0 0.6 0.65 60`. The matching config line is printed to F8.

## Evidence

| Provider | Behaviour |
|---|---|
| `fivemanage` | upload to `api.fivemanage.com/api/v3/file` with `policedash_fivemanage_key` |
| `discord` | image attached to the webhook embed. Discord attachment URLs expire after a while, use Fivemanage for permanent links. |
| `custom` | multipart POST (field `file`) to `Config.Evidence.customUrl`, header `X-API-Key` = `policedash_upload_key`. The response must contain `url` or `data.url`. |

- **Video (`videoSource = 'nui'`, default):** records only the dashcam with the OSD, saved under `recordings/` and uploaded to the provider.
- **Video (`videoSource = 'screencapture'`):** the whole screen via screencapture, `fivemanage` or `custom` only.
- Photos use screencapture (`remoteUpload`) or screenshot-basic.

## API

### Client

```lua
exports['policedash']:IsCamActive()          -- boolean
exports['policedash']:GetLastMeasurement()   -- record or nil

AddEventHandler('policedash:client:measurementDone', function(record) end)  -- after the server accepted it
```

### Server

```lua
-- With callback: async, includes the database
exports['policedash']:GetMeasurement('PV-2026-000123', function(record) end)
exports['policedash']:GetMeasurementsByPlate('46EEK572', 10, function(records) end)

-- Without callback: sync, cache (last 200) or KVP only
local record = exports['policedash']:GetMeasurement('PV-2026-000123')

AddEventHandler('policedash:server:measurementSaved', function(record) end)          -- incl. evidence URLs
AddEventHandler('policedash:server:videoSaved', function(record) end)                -- NUI video arrived later
AddEventHandler('policedash:server:submitRejected', function(source, reason) end)    -- validation, rate limit, permission
```

### Record

```lua
{
  id = 'PV-2026-000123', mode = 'MAN' | 'VASCAR', timestamp = 1792760000,
  officer  = { identifier, name },
  vehicle  = { model, plate },                 -- patrol car
  target   = { model, label, plate } | nil,
  location = { street, crossing, zone, coords = { x, y, z } },
  measured = 87.4, tolerance = 3, chargeable = 84, unit = 'kmh',
  duration = 6.3, distance = 153.0,
  maxSpeed = 91.2, gap = 34.5,                 -- MAN only
  track    = { origin, points, marks },        -- mini map
  evidence = { image = url | nil, video = url | 'local:recordings/…' | nil },
}
```

### HTTP export

With `Config.Export.enabled = true`, every saved record is sent as JSON via `POST` to `Config.Export.url`.
Headers: `Content-Type: application/json`, `X-API-Key: <policedash_export_key>`. On failure it retries once after 5 s.

## Security

- Secrets only via ConVar, never on the client or in `config.lua`
- Every server action checks permission. Submit, photo and playback are rate-limited.
- The server validates every measurement: maximum speed, distance/duration matches the value (±15 %), player position, seat in vehicle.
- Tolerance and chargeable value are recalculated server-side.
- SQL with placeholders only. The NUI sets text exclusively via `textContent`.

## Known limitations (alpha)

- Picture-in-picture costs some frames in your own view and adds about one frame of latency (`fillGaps`). Fast motion can still show slight stutter.
- Videos recorded with `videoSource = 'nui'` arrive after the Discord embed has been sent. They appear in the database and in playback, but not in the embed.
- Tested on ESX Legacy. QBCore, Qbox and standalone are implemented but not yet tested on a live server.

## Update check

`policedash_repo` in `fxmanifest.lua` is set to `Kargobob1/policedash`. On start the latest GitHub release is compared with the installed version (pre-releases such as `0.1.0-alpha` count as older than `0.1.0`). Disable with `Config.VersionCheck = false`.

## License and credit

Free to use, including on monetized servers. Resale is not allowed. See [LICENSE](LICENSE).

**Credit is required.** If you run PoliceDash (modified or not), name it where your server lists its credits or scripts
(credits page, website, Discord or forum post):

```
PoliceDash by Kargobob1/Excurse - https://github.com/Kargobob1/policedash
```

In-game names and branding may be changed.
