// PoliceDash NUI - Vanilla JS, kein Build-Step.
// Sicherheit: Texte nur ueber textContent setzen, nie innerHTML (Kennzeichen etc.).
'use strict';

const RESOURCE = typeof GetParentResourceName === 'function' ? GetParentResourceName() : 'policedash';
const NOTIFY_DURATION = 4000;
const OSD_INTERVAL = 66;   // ms, ~15 Bilder/s fuer die Anzeige (die Aufnahme zeichnet selbst)

const state = {
    initialized: false,
    locale: {},
    panelOpen: false,
    overlay: { clock: 'ingame' },
    units: 'km/h',
    volume: 0.4,
    chunkSize: 262144,
    device: null,          // 'cam' | 'pip' | null
};

const $ = (id) => document.getElementById(id);
const pad = (n, len = 2) => String(Math.trunc(Number(n) || 0)).padStart(len, '0');
const num = (v) => typeof v === 'number' && Number.isFinite(v);
const fixed = (v, digits = 1) => (num(v) ? v.toFixed(digits) : null);

function post(name, data = {}) {
    return fetch(`https://${RESOURCE}/${name}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json; charset=UTF-8' },
        body: JSON.stringify(data),
    });
}

function t(key) {
    return state.locale[key] ?? key;
}

function applyLocale() {
    document.querySelectorAll('[data-locale]').forEach((el) => {
        el.textContent = t(el.dataset.locale);
    });
    document.querySelectorAll('[data-locale-title]').forEach((el) => {
        el.title = t(el.dataset.localeTitle);
    });
}

function applyOverlaySettings(overlay = {}) {
    state.overlay = overlay;
    const root = document.documentElement;
    root.dataset.theme = overlay.theme === 'green' ? 'green' : 'white';
    const scale = Number(overlay.scale);
    if (Number.isFinite(scale) && scale > 0.25 && scale < 4) {
        root.style.setProperty('--scale', String(scale));
    }
    OSD.data.color = overlay.theme === 'green' ? '#39ff6a' : '#ffffff';
    OSD.data.realClock = overlay.clock === 'real';
    renderSettings();
}

// ---------- Klickgeraeusch (WebAudio, keine Asset-Datei noetig) ----------

let audio = null;

function click() {
    if (!state.overlay.sounds) return;
    try {
        audio = audio || new AudioContext();
        const osc = audio.createOscillator();
        const gain = audio.createGain();
        const now = audio.currentTime;
        osc.type = 'square';
        osc.frequency.setValueAtTime(1800, now);
        osc.frequency.exponentialRampToValueAtTime(600, now + 0.03);
        gain.gain.setValueAtTime(state.volume * 0.25, now);
        gain.gain.exponentialRampToValueAtTime(0.0001, now + 0.05);
        osc.connect(gain).connect(audio.destination);
        osc.start(now);
        osc.stop(now + 0.06);
    } catch (e) {
        // Audio nicht verfuegbar - stumm weiter
    }
}

function formatDate(clock) {
    return t('date_format')
        .replace('DD', pad(clock.day))
        .replace('MM', pad(clock.month))
        .replace('YYYY', pad(clock.year, 4));
}

// ---------- Geraet: Vollbild-Dashcam ('cam') oder Bild-im-Bild ('pip') ----------

let osdTimer = null;

function renderOsd() {
    const canvas = $('osd-canvas');
    const parent = canvas.parentElement;
    if (!state.device || !parent) return;
    const dpr = window.devicePixelRatio || 1;
    const w = Math.round(parent.clientWidth * dpr);
    const h = Math.round(parent.clientHeight * dpr);
    if (!w || !h) return;
    if (canvas.width !== w || canvas.height !== h) {
        canvas.width = w;
        canvas.height = h;
    }
    OSD.draw(canvas.getContext('2d'), w, h, { clear: true, scanlines: true });
}

// { mode: 'cam' | 'pip' | false, stats, raw, fill }
function setDevice({ mode, stats, raw, fill }) {
    const device = mode === 'cam' || mode === 'pip' ? mode : null;
    const canvas = $('osd-canvas');

    if (!device) {
        Recorder.abort();
        PiP.stop();
        clearInterval(osdTimer);
        osdTimer = null;
        state.device = null;
        ['pip-canvas', 'pip-mask', 'pip-monitor', 'osd-full', 'osd-canvas'].forEach((id) => $(id).classList.add('hidden'));
        document.body.classList.remove('device-pip');
        showResult(null);
        return;
    }

    state.device = device;
    state.pipOptions = { mode: raw ? 'raw' : 'pip', stats: stats || raw, fill };
    OSD.reset();
    OSD.data.target = null;
    document.body.classList.toggle('device-pip', device === 'pip');

    const isPip = device === 'pip';
    $('pip-monitor').classList.toggle('hidden', !isPip);
    $('osd-full').classList.toggle('hidden', isPip);
    $('pip-stats').classList.toggle('hidden', !isPip || (!stats && !raw));
    (isPip ? $('pip-screen') : $('osd-full')).appendChild(canvas);
    canvas.classList.remove('hidden');

    // Bild-im-Bild startet im Standby; live schaltet erst 'pip:live' (Messung, Taste oder liveMode always)
    PiP.stop();
    setPipLive({ on: false, immediate: true });

    if (!osdTimer) osdTimer = setInterval(renderOsd, OSD_INTERVAL);
    renderOsd();
}

// Live: Spielbild-Kopie vollflaechig + Dashcam im Monitor. Standby: echtes Spielbild, Monitor mit Standbild.
function setPipLive({ on, immediate }) {
    if (state.device !== 'pip') return;
    const monitor = $('pip-monitor');
    const showLive = (live) => {
        ['pip-canvas', 'pip-mask'].forEach((id) => $(id).classList.toggle('hidden', !live));
        monitor.classList.toggle('standby', !live);
    };

    if (on) {
        // Kopie erst zeigen, wenn sie gueltige Bilder hat; dann darf das Spiel Dashcam-Frames einschieben
        PiP.start({
            ...(state.pipOptions || { mode: 'pip' }),
            onReady: () => {
                if (state.device !== 'pip') return;
                showLive(true);
                post('pipReady').catch(() => {});
            },
        });
        return;
    }
    if (immediate) {
        $('pm-still').getContext('2d').clearRect(0, 0, $('pm-still').width, $('pm-still').height);
        showLive(false);
        return;
    }
    // erst Standbild sichern und die Kopie ausblenden, dann darf das Spiel auf die echte Kamera zurueck
    PiP.stopWithSnapshot($('pm-still'), () => {
        showLive(false);
        post('pipHidden').catch(() => {});
    });
}

// { speed, mode, odometer, clock }
function updateDevice(data) {
    const d = OSD.data;
    if (num(data.speed)) d.speed = data.speed;
    if (num(data.odometer)) d.odometer = data.odometer;
    if (typeof data.mode === 'string') {
        d.mode = data.mode;
        d.modeLabel = t(`osd_mode_${data.mode}`);
    }
    if (data.clock) d.clock = data.clock;
}

// { plate, locked } oder {} fuer kein Ziel
function updateTarget({ plate, locked }) {
    OSD.data.target = plate ? String(plate) : null;
    OSD.data.targetLocked = !!locked;
}

// { value, duration, distance, running }; fehlende Werte = Nullanzeige
function updateMeasure({ duration, distance, running }) {
    const d = OSD.data;
    if (running && !d.running) d.measured = null;
    d.running = !!running;
    d.liveTime = num(duration) ? duration : null;
    d.liveDistance = num(distance) ? distance : null;
}

// ---------- Ergebnis-Karte ----------

let resultTimer = null;

function showResult(result) {
    const card = $('result');
    clearTimeout(resultTimer);
    $('res-id').textContent = '';
    OSD.data.measured = result && result.valid && num(result.measured) ? result.measured : null;
    if (!result) {
        card.classList.add('hidden');
        return;
    }

    const valid = !!result.valid;
    const unit = state.units;
    card.classList.toggle('invalid', !valid);
    $('res-status').textContent = t(valid ? 'res_valid' : 'res_invalid');

    const meta = [t(`mode_${result.mode}`)];
    if (result.target) meta.push(`${result.target.plate} · ${result.target.label}`);
    $('res-meta').textContent = meta.join('  |  ');

    $('res-reason').textContent = result.reason ? String(result.reason) : '';
    $('res-reason').classList.toggle('hidden', valid);
    $('res-values').classList.toggle('hidden', !valid);

    if (valid) {
        $('res-measured').textContent = `${fixed(result.measured)} ${unit}`;
        $('res-tolerance').textContent = `−${fixed(result.tolerance)} ${unit}`;
        $('res-chargeable').textContent = `${result.chargeable} ${unit}`;
        $('res-duration').textContent = `${fixed(result.duration)} s`;
        $('res-distance').textContent = `${fixed(result.distance, 0)} m`;
    }

    card.classList.remove('hidden');
    const seconds = Number(state.overlay.resultSeconds) || 8;
    resultTimer = setTimeout(() => card.classList.add('hidden'), seconds * 1000);
}

// Messnummer nachreichen, sobald der Server die Messung angenommen hat
function showResultId({ id }) {
    if (typeof id === 'string') $('res-id').textContent = id;
}

// ---------- Videoaufnahme ----------

function recStart({ maxSeconds, bitrate }) {
    if (!state.device) return;
    Recorder.start({ device: state.device, maxSeconds, bitrate, chunkSize: state.chunkSize });
}

// ---------- Wiedergabe von Messvideos ----------
// info: Messdaten + url (https, direkt abspielbar) oder chunks (Base64-Stuecke folgen per player:chunk)

const player = { id: null, parts: null, received: 0, objectUrl: null, closeTimer: null, track: null, mapLoop: false };

function mapLabels() {
    return { own: t('map_own'), target: t('map_target'), north: t('map_north') };
}

// Mini-Map im Videofenster laeuft mit der Videozeit mit (Aufnahme beginnt mit der Messung)
function drawPlayerMap() {
    if (!player.mapLoop) return;
    const canvas = $('pl-map');
    const video = $('pl-video');
    const playing = video.currentSrc && !video.ended && video.readyState >= 2;
    const t = playing ? Math.min(video.currentTime * 1000, TrackMap.duration(player.track)) : null;
    TrackMap.draw(canvas.getContext('2d'), canvas.width, canvas.height, player.track, t, mapLabels());
    requestAnimationFrame(drawPlayerMap);
}

function playerRow(list, label, value, main) {
    const dt = document.createElement('dt');
    const dd = document.createElement('dd');
    dt.textContent = label;
    dd.textContent = value;
    if (main) dd.className = 'pl-main';
    list.append(dt, dd);
}

function setPlayerSource(src) {
    const video = $('pl-video');
    video.src = src;
    video.play().catch(() => {});
    $('pl-loading').classList.add('hidden');
}

function closePlayer() {
    clearTimeout(player.closeTimer);
    const video = $('pl-video');
    video.pause();
    video.removeAttribute('src');
    video.load();
    if (player.objectUrl) URL.revokeObjectURL(player.objectUrl);
    Object.assign(player, { id: null, parts: null, received: 0, objectUrl: null, closeTimer: null, track: null, mapLoop: false });
    $('pl-map').classList.add('hidden');
    $('player').classList.add('hidden');
}

function openPlayer(info) {
    closePlayer();
    player.id = String(info.id);
    const unit = info.unit === 'mph' ? 'mph' : 'km/h';

    $('pl-title').textContent = `${t('play_title')} ${player.id}`;
    const data = $('pl-data');
    data.replaceChildren();
    playerRow(data, t('hist_time'), formatTimestamp(info.timestamp));
    playerRow(data, t('st_mode'), t(`mode_${info.mode}`));
    if (info.target) playerRow(data, t('st_target'), `${info.target.plate} · ${info.target.label}`);
    if (info.officer) playerRow(data, t('hist_officer'), String(info.officer));
    if (info.street) playerRow(data, t('hist_location'), [info.street, info.zone].filter(Boolean).join(', '));
    playerRow(data, t('res_measured'), `${fixed(info.measured)} ${unit}`);
    playerRow(data, t('res_tolerance'), `−${fixed(info.tolerance)} ${unit}`);
    playerRow(data, t('res_chargeable'), `${info.chargeable} ${unit}`, true);
    playerRow(data, t('res_duration'), `${fixed(info.duration)} s`);
    playerRow(data, t('res_distance'), `${fixed(info.distance, 0)} m`);
    if (num(info.gap)) playerRow(data, t('map_gap'), `${fixed(info.gap, 0)} m`);

    $('player').classList.remove('hidden');
    if (info.track && Array.isArray(info.track.points)) {
        player.track = info.track;
        player.mapLoop = true;
        $('pl-map').classList.remove('hidden');
        requestAnimationFrame(drawPlayerMap);
    }
    if (typeof info.url === 'string' && /^https:\/\//.test(info.url)) {
        setPlayerSource(info.url);
    } else if (num(info.chunks) && info.chunks > 0) {
        player.parts = new Array(info.chunks);
        $('pl-loading').textContent = `${t('play_loading')} 0 %`;
        $('pl-loading').classList.remove('hidden');
    }
}

function playerChunk({ id, index, total, chunk }) {
    if (id !== player.id || !player.parts || !num(index) || index < 1 || index > player.parts.length) return;
    if (player.parts[index - 1] === undefined) {
        player.parts[index - 1] = String(chunk);
        player.received += 1;
    }
    $('pl-loading').textContent = `${t('play_loading')} ${Math.floor(player.received / player.parts.length * 100)} %`;
    if (player.received < player.parts.length) return;

    const binary = atob(player.parts.join(''));
    player.parts = null;
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
    player.objectUrl = URL.createObjectURL(new Blob([bytes], { type: 'video/webm' }));
    setPlayerSource(player.objectUrl);
}

$('pl-video').addEventListener('ended', () => {
    clearTimeout(player.closeTimer);
    player.closeTimer = setTimeout(closePlayer, (state.playbackCloseAfter || 8) * 1000);
});

// ---------- Notifications ----------

function notify({ message, type }) {
    const el = document.createElement('div');
    el.className = `notify ${['info', 'success', 'error', 'warning'].includes(type) ? type : 'info'}`;
    el.textContent = String(message ?? '');
    $('notifications').appendChild(el);

    setTimeout(() => {
        el.classList.add('out');
        setTimeout(() => el.remove(), 300);
    }, NOTIFY_DURATION);
}

// ---------- Bedienteil ----------

function setPanel({ open }) {
    state.panelOpen = !!open;
    $('panel').classList.toggle('hidden', !state.panelOpen);
    if (state.panelOpen) showTab('status');
}

function showTab(name) {
    document.querySelectorAll('.pn-tab').forEach((tab) => {
        tab.classList.toggle('active', tab.dataset.tab === name);
    });
    ['status', 'history', 'settings'].forEach((view) => {
        $(`view-${view}`).classList.toggle('hidden', view !== name);
    });
    if (name === 'history') loadHistory();
}

function updatePanelState(s) {
    const onOff = (v) => t(v ? 'st_on' : 'st_off');
    $('st-cam').textContent = onOff(s.camActive);
    $('st-mode').textContent = t(`mode_${s.mode}`);
    $('st-target').textContent = s.target ? String(s.target) : '-';
    $('st-measure').textContent = t(s.running ? 'st_running' : 'st_idle');
    $('st-last').textContent = s.last
        ? `${s.last.chargeable} ${state.units}${s.last.plate ? ` · ${s.last.plate}` : ''}`
        : '-';
    $('led-cam').classList.toggle('on', !!s.camActive);
    $('led-measure').classList.toggle('on', !!s.running);
}

// ---------- Historie ----------

let historyEntryId = null;   // Messung in der Detailansicht (fuer Ansehen/Vorfuehren)

function formatTimestamp(ts) {
    if (!num(ts)) return '-';
    const d = new Date(ts * 1000);
    const date = formatDate({ year: d.getFullYear(), month: d.getMonth() + 1, day: d.getDate() });
    return `${date} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

function kvRow(list, label, value) {
    const dt = document.createElement('dt');
    const dd = document.createElement('dd');
    dt.textContent = label;
    dd.textContent = value;
    list.append(dt, dd);
}

function showHistoryDetail(entry) {
    $('hist-list').classList.add('hidden');
    $('hist-empty').classList.add('hidden');
    $('hist-detail').classList.remove('hidden');

    const unit = state.units;
    $('hd-title').textContent = `${entry.id ?? '-'} · ${t(`mode_${entry.mode}`)}`;

    const values = $('hd-values');
    values.replaceChildren();
    kvRow(values, t('hist_time'), formatTimestamp(entry.timestamp));
    if (entry.target) kvRow(values, t('st_target'), `${entry.target.plate} · ${entry.target.label}`);
    kvRow(values, t('res_measured'), `${fixed(entry.measured)} ${unit}`);
    kvRow(values, t('res_tolerance'), `−${fixed(entry.tolerance)} ${unit}`);
    kvRow(values, t('res_chargeable'), `${entry.chargeable} ${unit}`);
    kvRow(values, t('res_duration'), `${fixed(entry.duration)} s`);
    kvRow(values, t('res_distance'), `${fixed(entry.distance, 0)} m`);
    if (entry.location && entry.location.street) kvRow(values, t('hist_location'), entry.location.street);
    if (entry.officer && entry.officer.name) kvRow(values, t('hist_officer'), entry.officer.name);
    const map = $('hd-map');
    const hasTrack = !!(entry.track && Array.isArray(entry.track.points));
    map.classList.toggle('hidden', !hasTrack);
    if (hasTrack) TrackMap.draw(map.getContext('2d'), map.width, map.height, entry.track, null, mapLabels());

    const hasVideo = !!(entry.evidence && typeof entry.evidence.video === 'string' && entry.id);
    $('hd-actions').classList.toggle('hidden', !hasVideo);
    historyEntryId = hasVideo ? entry.id : null;

    const holder = $('hd-image');
    holder.replaceChildren();
    const image = entry.evidence && entry.evidence.image;
    if (typeof image === 'string' && /^https:\/\//.test(image)) {
        const img = document.createElement('img');
        img.className = 'pn-image';
        img.alt = entry.id ?? '';
        img.src = image;
        holder.appendChild(img);
    }
}

function renderHistory(entries) {
    const list = $('hist-list');
    list.replaceChildren();
    list.classList.remove('hidden');
    $('hist-detail').classList.add('hidden');
    $('hist-empty').classList.toggle('hidden', entries.length > 0);

    entries.forEach((entry) => {
        const li = document.createElement('li');
        const row = document.createElement('button');
        row.className = 'pn-row';

        const main = document.createElement('span');
        main.textContent = entry.target ? entry.target.plate : (entry.id ?? '-');
        const sub = document.createElement('span');
        sub.className = 'pn-row-sub';
        sub.textContent = formatTimestamp(entry.timestamp);
        const value = document.createElement('span');
        value.textContent = `${entry.chargeable} ${state.units}`;

        row.append(main, sub, value);
        row.addEventListener('click', () => { click(); showHistoryDetail(entry); });
        li.appendChild(row);
        list.appendChild(li);
    });
}

function loadHistory() {
    post('history')
        .then((res) => res.json())
        .then((entries) => renderHistory(Array.isArray(entries) ? entries : []))
        .catch(() => renderHistory([]));
}

// ---------- Einstellungen ----------

function renderSettings() {
    const o = state.overlay;
    const scale = Number(o.scale) || 1;
    $('set-scale').value = String(scale);
    $('set-scale-value').textContent = scale.toFixed(1);
    const dashFps = Number(o.dashFps) || 15;
    $('set-dashfps').value = String(dashFps);
    $('set-dashfps-value').textContent = String(dashFps);
    document.querySelectorAll('.pn-choice').forEach((group) => {
        const current = String(o[group.dataset.setting]);
        group.querySelectorAll('button').forEach((b) => {
            b.classList.toggle('active', b.dataset.value === current);
        });
    });
}

function saveSettings(changes) {
    post('settings', changes)
        .then((res) => res.json())
        .then((settings) => { if (settings && typeof settings === 'object') applyOverlaySettings(settings); })
        .catch(() => {});
}

// ---------- Events ----------

document.querySelectorAll('.pn-key').forEach((key) => {
    key.addEventListener('click', () => {
        click();
        post('action', { name: key.dataset.action });
    });
});

document.querySelectorAll('.pn-tab').forEach((tab) => {
    tab.addEventListener('click', () => { click(); showTab(tab.dataset.tab); });
});

$('hist-back').addEventListener('click', () => { click(); loadHistory(); });

[['hd-view', false], ['hd-show', true]].forEach(([id, nearby]) => {
    $(id).addEventListener('click', () => {
        if (!historyEntryId) return;
        click();
        post('playback', { id: historyEntryId, nearby });
    });
});

$('set-scale').addEventListener('input', (e) => {
    $('set-scale-value').textContent = Number(e.target.value).toFixed(1);
});
$('set-scale').addEventListener('change', (e) => saveSettings({ scale: Number(e.target.value) }));

$('set-dashfps').addEventListener('input', (e) => {
    $('set-dashfps-value').textContent = String(e.target.value);
});
$('set-dashfps').addEventListener('change', (e) => saveSettings({ dashFps: Number(e.target.value) }));

document.querySelectorAll('.pn-choice').forEach((group) => {
    group.querySelectorAll('button').forEach((b) => {
        b.addEventListener('click', () => {
            click();
            let value = b.dataset.value;
            if (group.dataset.setting === 'sounds') value = value === 'true';
            saveSettings({ [group.dataset.setting]: value });
        });
    });
});

const handlers = {
    init(data) {
        state.initialized = true;
        state.locale = data.locale || {};
        if (typeof data.units === 'string') {
            state.units = data.units;
            OSD.data.unit = data.units;
        }
        if (num(data.volume)) state.volume = Math.min(1, Math.max(0, data.volume));
        if (num(data.chunkSize)) state.chunkSize = data.chunkSize;
        if (typeof data.brand === 'string') OSD.data.brand = data.brand;
        if (typeof data.zoom === 'string') OSD.data.zoom = data.zoom;
        if (num(data.playbackCloseAfter)) state.playbackCloseAfter = data.playbackCloseAfter;
        OSD.data.modeLabel = t(`osd_mode_${OSD.data.mode}`);
        applyLocale();
        applyOverlaySettings(data.overlay);
    },
    notify,
    panel: setPanel,
    'panel:state': updatePanelState,
    settings: applyOverlaySettings,
    device: setDevice,
    'overlay:update': updateDevice,
    'overlay:target': updateTarget,
    'overlay:measure': updateMeasure,
    result: showResult,   // data darf null sein = Karte ausblenden
    'result:id': showResultId,
    'rec:start': recStart,
    'rec:finish': (data) => Recorder.finish(data),
    'rec:abort': () => Recorder.abort(),
    'player:open': openPlayer,
    'player:chunk': playerChunk,
    'player:close': closePlayer,
    'pip:log': ({ seconds }) => PiP.startLog(Number(seconds) || 10),
    'pip:fill': ({ on }) => PiP.setFill(on),
    'pip:live': ({ on }) => setPipLive({ on: !!on }),
};

window.addEventListener('message', (event) => {
    const { action, data } = event.data || {};
    const handler = handlers[action];
    if (!handler) return;
    if (action === 'result') handler(data || null);
    else handler(data || {});
});

window.addEventListener('keydown', (event) => {
    if (event.key === 'Escape' && state.panelOpen) {
        post('close');
    }
});

// Handshake: so lange 'ready' senden, bis der Client 'init' geschickt hat
// (die Lua-Callbacks sind beim Laden der Seite eventuell noch nicht registriert).
function announceReady() {
    if (state.initialized) return;
    post('ready').catch(() => {});
    setTimeout(announceReady, 1000);
}
announceReady();
