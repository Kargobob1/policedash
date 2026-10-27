// Spielbild-Abgriff fuer Bild-im-Bild und Videoaufnahme. Gegenstueck zu client/pip.lua.
//
// Das Spielbild kommt ueber FiveMs WebGL-Texture-Hook ins NUI (dieselbe Technik wie
// citizenfx/screenshot-basic, MIT). Zwei Betriebsarten:
//
// 'pip':     Das Spiel rendert abwechselnd Spieler- und Dashcam-Frames, jeder mit Farbmarke oben links
//            (gruen = Spieler, magenta = Dashcam). Pro Animationsframe: Spielbild in einen Puffer
//            kopieren, Marke lesen, Puffer als "main" oder "dash" behalten (nur Zeiger tauschen),
//            main vollflaechig und dash (4:3 beschnitten) in den Monitor zeichnen.
// 'capture': Vollbild-Dashcam. Kein Anzeigen, jedes Spielbild geht nur an die Aufnahme.
//
// PiP.onFrame(source, sx, sy, sw, sh) bekommt jedes neue Dashcam-Bild (Ausschnitt eines Canvas).
'use strict';

const PiP = (() => {
    const VERTEX = `
        attribute vec2 a_pos;
        uniform float u_flip;
        uniform vec2 u_scale;
        uniform vec2 u_offset;
        varying vec2 v_uv;
        void main() {
            v_uv = (a_pos * 0.5 + 0.5) * u_scale + u_offset;
            if (u_flip > 0.5) v_uv.y = 1.0 - v_uv.y;
            gl_Position = vec4(a_pos, 0.0, 1.0);
        }`;
    // u_mix > 0 blendet u_tex2 ueber u_tex (Lueckenfuellung im Hauptbild)
    const FRAGMENT = `
        precision mediump float;
        uniform sampler2D u_tex;
        uniform sampler2D u_tex2;
        uniform float u_mix;
        varying vec2 v_uv;
        void main() { gl_FragColor = mix(texture2D(u_tex, v_uv), texture2D(u_tex2, v_uv), u_mix); }`;

    const BUILD = 'v11';          // Stand, wird im Zaehler angezeigt
    const MARKER_PROBE = 3;       // Pixelabstand vom Rand fuer die Markenabfrage
    const FLIP_KEY = 'policedash_gameview_flip';

    let gl = null;
    let canvas = null;
    let uFlip = null;
    let uScale = null;
    let uOffset = null;
    let uMix = null;
    let fillGaps = true;          // Luecken im Hauptbild durch Ueberblendung fuellen (1 Frame Verzoegerung)
    let gapPending = false;       // seit dem letzten Spieler-Frame kam ein Dashcam-Frame
    let pendingSnapshot = null;   // { target, done }: Standbild fuer den Standby anfertigen
    // Unsichtbarer Streifen unterhalb des Bildschirms: dort wird jedes Dashcam-Bild fuer die Aufnahme in
    // voller Aufnahmegroesse gezeichnet (statt den kleinen Monitor abzufilmen). Bleibt auf der GPU.
    const REC_W = 960;
    const REC_H = 720;
    let screenH = 0;              // Bildschirmhoehe in Canvas-Pixeln (der Canvas ist REC_H hoeher)
    const READY_FRAMES = 2;       // so viele Spieler-Frames, bevor die Kopie angezeigt werden darf
    let onReady = null;
    let playerFramesSinceStart = 0;
    let gameTexture = null;
    let targets = null;           // { latest, main, dash }
    let flip = loadFlip();
    let mode = null;              // 'pip' | 'raw' | 'capture'
    let showStats = false;
    let contextWatched = false;
    const pixel = new Uint8Array(4);
    const stats = { player: 0, dash: 0, unknown: 0, since: 0, lastMarker: 0 };
    const probes = { top: '', bottom: '', center: '' };

    const api = { start, stop, onFrame: null, isRunning: () => mode !== null };

    function loadFlip() {
        try { return localStorage.getItem(FLIP_KEY) !== 'false'; } catch (e) { return true; }
    }

    function rememberFlip(value) {
        if (value === flip) return;
        flip = value;
        try { localStorage.setItem(FLIP_KEY, String(value)); } catch (e) { /* egal */ }
    }

    function compile(type, source) {
        const shader = gl.createShader(type);
        gl.shaderSource(shader, source);
        gl.compileShader(shader);
        return shader;
    }

    // FiveM-Hook: diese texParameter-Folge bindet die Textur an das aktuelle Spielbild.
    // Aufbau wie beim CfxTexture-Pfad in three.js (sd-phone/utk_render): 1x1 RGB, Hook direkt nach dem Upload.
    // Startfarbe blau: liest die Diagnose 0,0,255, hat der Hook nicht gegriffen.
    function createGameTexture() {
        const tex = gl.createTexture();
        gl.bindTexture(gl.TEXTURE_2D, tex);
        gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, false);
        gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGB, 1, 1, 0, gl.RGB, gl.UNSIGNED_BYTE, new Uint8Array([0, 0, 255]));
        gl.texParameterf(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
        gl.texParameterf(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.MIRRORED_REPEAT);
        gl.texParameterf(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.REPEAT);
        return tex;
    }

    function createTarget(width, height) {
        const tex = gl.createTexture();
        gl.bindTexture(gl.TEXTURE_2D, tex);
        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, width, height, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
        const fbo = gl.createFramebuffer();
        gl.bindFramebuffer(gl.FRAMEBUFFER, fbo);
        gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, tex, 0);
        return { tex, fbo };
    }

    function init() {
        canvas = document.getElementById('pip-canvas');
        gl = canvas.getContext('webgl', {
            antialias: false, depth: false, stencil: false, alpha: false, preserveDrawingBuffer: false,
        });
        if (!gl) return false;

        const program = gl.createProgram();
        gl.attachShader(program, compile(gl.VERTEX_SHADER, VERTEX));
        gl.attachShader(program, compile(gl.FRAGMENT_SHADER, FRAGMENT));
        gl.linkProgram(program);
        gl.useProgram(program);
        uFlip = gl.getUniformLocation(program, 'u_flip');
        uScale = gl.getUniformLocation(program, 'u_scale');
        uOffset = gl.getUniformLocation(program, 'u_offset');
        uMix = gl.getUniformLocation(program, 'u_mix');
        gl.uniform1i(gl.getUniformLocation(program, 'u_tex'), 0);
        gl.uniform1i(gl.getUniformLocation(program, 'u_tex2'), 1);

        const quad = gl.createBuffer();
        gl.bindBuffer(gl.ARRAY_BUFFER, quad);
        gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW);
        const aPos = gl.getAttribLocation(program, 'a_pos');
        gl.enableVertexAttribArray(aPos);
        gl.vertexAttribPointer(aPos, 2, gl.FLOAT, false, 0, 0);

        gameTexture = createGameTexture();
        if (!contextWatched) {
            contextWatched = true;
            watchContext();
        }
        return true;
    }

    function resize() {
        const dpr = window.devicePixelRatio || 1;
        const width = Math.round(window.innerWidth * dpr);
        const height = Math.round(window.innerHeight * dpr);
        screenH = height;
        canvas.width = width;
        canvas.height = height + REC_H;
        canvas.style.width = `${width / dpr}px`;
        canvas.style.height = `${(height + REC_H) / dpr}px`;
        if (targets) {
            Object.values(targets).forEach((t) => {
                if (!t) return;
                gl.deleteFramebuffer(t.fbo);
                gl.deleteTexture(t.tex);
            });
        }
        targets = { latest: createTarget(width, height), main: createTarget(width, height), dash: createTarget(width, height) };
    }

    // crop: Anteil des Quellbilds in x/y (1 = alles), mittig. blendWith/mix: zweite Textur anteilig ueberblenden.
    function draw(texture, flipY, cropX = 1, cropY = 1, blendWith = null, mix = 0) {
        gl.activeTexture(gl.TEXTURE1);
        gl.bindTexture(gl.TEXTURE_2D, blendWith || texture);
        gl.activeTexture(gl.TEXTURE0);
        gl.bindTexture(gl.TEXTURE_2D, texture);
        gl.uniform1f(uMix, blendWith ? mix : 0);
        gl.uniform1f(uFlip, flipY ? 1 : 0);
        gl.uniform2f(uScale, cropX, cropY);
        gl.uniform2f(uOffset, (1 - cropX) / 2, (1 - cropY) / 2);
        gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
    }

    // Quellbild (Bildschirmformat) auf ein Zielformat beschneiden statt verzerren
    function cropFor(targetAspect) {
        const sourceAspect = canvas.width / screenH;
        return targetAspect < sourceAspect ? [targetAspect / sourceAspect, 1] : [1, sourceAspect / targetAspect];
    }

    function readPixel(x, y) {
        gl.readPixels(x, y, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, pixel);
        return `${pixel[0]},${pixel[1]},${pixel[2]}`;
    }

    function classify(px) {
        const [r, g, b] = px;
        if (g > 180 && r < 90 && b < 90) return 'player';
        if (r > 180 && b > 180 && g < 90) return 'dash';
        return null;
    }

    // Marke oben oder unten im Puffer suchen; die Lage verraet, ob das Bild gespiegelt ankommt.
    // Die bekannte Lage zuerst: meist reicht ein einziges readPixels pro Frame (jedes kostet einen GPU-Sync).
    function readMarker() {
        const h = screenH;
        const probe = (atTop) => {
            const value = readPixel(MARKER_PROBE, atTop ? h - 1 - MARKER_PROBE : MARKER_PROBE);
            if (atTop) probes.top = value; else probes.bottom = value;
            const kind = classify(pixel);
            if (kind) rememberFlip(!atTop);
            return kind;
        };
        return probe(!flip) || probe(flip);
    }

    // Diagnose (/policedash pip log): pro Anzeige-Frame Zeit, Typ und angezeigte Spielframe-Nummer.
    // Die Nummer steht als zweite Farbmarke neben der ersten (r = low, g = high, b = 128).
    let log = null;   // { until, entries }

    function readFrameCounter() {
        const h = screenH;
        const x = Math.round(canvas.width * 0.013);
        gl.readPixels(x, flip ? MARKER_PROBE : h - 1 - MARKER_PROBE, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, pixel);
        return pixel[2] > 100 && pixel[2] < 160 ? pixel[0] + pixel[1] * 256 : -1;
    }

    function logFrame(now, kind) {
        if (!log) return;
        const code = kind === 'player' ? 1 : kind === 'dash' ? 2 : 0;
        log.entries.push([Math.round(now * 10) / 10, code, readFrameCounter()]);
        if (now < log.until) return;
        const entries = log.entries;
        log = null;
        post('pipLog', {
            entries,
            meta: { canvas: [canvas.width, canvas.height], dpr: window.devicePixelRatio || 1, flip, fillGaps, build: BUILD },
        });
    }

    api.setFill = (on) => {
        fillGaps = !!on;
        gapPending = false;
    };

    api.startLog = (seconds) => {
        if (mode !== 'pip') return;
        log = { until: performance.now() + seconds * 1000, entries: [] };
    };

    // Selbstheilung: bleibt das Spielbild ~2 s schwarz, Hook neu aufbauen
    // (die Verbindung zum Spielbild kann z.B. nach Alt-Tab oder Aufloesungswechsel verloren gehen)
    const BLACK_CHECK_EVERY = 30;   // Frames
    const BLACK_CHECKS_BEFORE_REHOOK = 4;
    let frameCount = 0;
    let blackChecks = 0;
    let rehooks = 0;

    // yOffset: im Default-Framebuffer liegt das Bild ueber dem Aufnahmestreifen
    function checkBlack(yOffset = 0) {
        frameCount += 1;
        if (frameCount % BLACK_CHECK_EVERY !== 0) return;
        probes.center = readPixel(Math.floor(canvas.width / 2), yOffset + Math.floor(screenH / 2));
        // Exakt 0,0,0 (kein Bild) oder 0,0,255 (Startfarbe, Hook greift nicht); dunkle Nachtszenen sind nie exakt 0
        const black = pixel[0] === 0 && pixel[1] === 0 && (pixel[2] === 0 || pixel[2] === 255);
        blackChecks = black ? blackChecks + 1 : 0;
        if (blackChecks < BLACK_CHECKS_BEFORE_REHOOK) return;
        blackChecks = 0;
        rehooks += 1;
        gl.deleteTexture(gameTexture);
        gameTexture = createGameTexture();
    }

    // Innenflaeche des Monitors in Canvas-Pixeln: GL-Viewport (Ursprung unten) und Canvas-Ausschnitt (oben)
    function monitorRect() {
        const el = document.getElementById('pip-screen');
        const rect = el.getBoundingClientRect();
        const dpr = window.devicePixelRatio || 1;
        const x = Math.round((rect.left + el.clientLeft) * dpr);
        const top = Math.round((rect.top + el.clientTop) * dpr);
        const w = Math.round(el.clientWidth * dpr);
        const h = Math.round(el.clientHeight * dpr);
        return { x, top, w, h, glY: canvas.height - top - h };
    }

    function updateStats(now) {
        if (!showStats || now - stats.since < 1000) return;
        const seconds = (now - stats.since) / 1000;
        const markerLost = now - stats.lastMarker > 2000;
        document.getElementById('pip-stats').textContent =
            `${BUILD} | P ${Math.round(stats.player / seconds)} · D ${Math.round(stats.dash / seconds)} · ? ${Math.round(stats.unknown / seconds)} fps`
            + (flip ? ' · flip' : '')
            + (markerLost ? ' · MARKE NICHT ERKANNT' : '')
            + (rehooks ? ` · rehook ${rehooks}` : '')
            + ` | oben ${probes.top} · unten ${probes.bottom} · mitte ${probes.center} · ${canvas.width}x${canvas.height}`;
        stats.player = stats.dash = stats.unknown = 0;
        stats.since = now;
    }

    // Ankommende Dashcam-Frames je Sekunde an Lua melden; Lua gleicht verlorene Frames aus (client/pip.lua)
    const rate = { dash: 0, since: 0 };
    let lastKind = null;

    function reportRate(now) {
        if (!rate.since) rate.since = now;
        if (now - rate.since < 1000) return;
        post('pipRate', { dash: rate.dash }).catch(() => {});
        rate.dash = 0;
        rate.since = now;
    }

    function pipFrame(now) {
        const w = canvas.width;
        const h = screenH;

        // 1. Spielbild 1:1 in den Zwischenpuffer
        gl.bindFramebuffer(gl.FRAMEBUFFER, targets.latest.fbo);
        gl.viewport(0, 0, w, h);
        draw(gameTexture, false);

        // 2./3. einsortieren.
        // Mit fillGaps zeigt das Hauptbild immer den vorletzten Spieler-Frame (1 Frame Verzoegerung).
        // Dadurch ist nach einem Dashcam-Frame der naechste Spieler-Frame schon da, und die Luecke wird
        // mit einer Ueberblendung aus dem Frame davor und danach gefuellt statt mit Stehbild + Sprung:
        //   P1 P2 [D] P4 P5  ->  angezeigt: P1 P2 (P2+P4)/2 P4 ...
        const kind = readMarker();
        checkBlack();
        logFrame(now, kind);
        reportRate(now);

        const swapInto = (slot) => {
            const keep = targets[slot];
            targets[slot] = targets.latest;
            targets.latest = keep;
        };
        let show = targets.main.tex;
        let blend = null;

        if (kind === 'player') {
            stats.player += 1;
            stats.lastMarker = now;
            playerFramesSinceStart += 1;
            if (onReady && playerFramesSinceStart >= READY_FRAMES) {
                const ready = onReady;
                onReady = null;
                // erst nach diesem Frame anzeigen, dann ist 'main' sicher gefuellt
                requestAnimationFrame(ready);
            }
            if (fillGaps && gapPending) blend = targets.latest.tex;
            swapInto('main');
            if (!fillGaps) show = targets.main.tex;
            gapPending = false;
        } else if (kind === 'dash') {
            stats.dash += 1;
            stats.lastMarker = now;
            // Zwei Dashcam-Frames hintereinander = derselbe Frame doppelt gesehen (das Spiel sendet nie zwei)
            if (lastKind !== 'dash') rate.dash += 1;
            swapInto('dash');
            gapPending = true;
        } else {
            stats.unknown += 1;
            // Ohne erkannte Marke (Diagnose) das rohe Spielbild zeigen
            if (now - stats.lastMarker > 1000) show = targets.latest.tex;
        }

        if (kind) lastKind = kind;

        // 4. ausgeben (sichtbarer Bereich liegt ueber dem Aufnahmestreifen)
        gl.bindFramebuffer(gl.FRAMEBUFFER, null);
        gl.viewport(0, REC_H, w, h);
        draw(show, flip, 1, 1, blend, 0.5);

        const m = monitorRect();
        gl.viewport(m.x, m.glY, m.w, m.h);
        const [cx, cy] = cropFor(m.w / m.h);
        draw(targets.dash.tex, flip, cx, cy);

        // Neues Dashcam-Bild in voller Aufnahmegroesse in den unsichtbaren Streifen und an die Aufnahme
        // (im selben Task, solange der Canvas-Inhalt gilt)
        if (kind === 'dash' && api.onFrame) {
            gl.viewport(0, 0, REC_W, REC_H);
            const [rx, ry] = cropFor(REC_W / REC_H);
            draw(targets.dash.tex, flip, rx, ry);
            api.onFrame(canvas, 0, canvas.height - REC_H, REC_W, REC_H);
        }

        // Standby angefordert: aktuelles Monitorbild als Standbild sichern, dann anhalten
        if (pendingSnapshot) {
            const { target, done } = pendingSnapshot;
            pendingSnapshot = null;
            target.width = m.w;
            target.height = m.h;
            target.getContext('2d').drawImage(canvas, m.x, m.top, m.w, m.h, 0, 0, m.w, m.h);
            mode = null;
            done();
        }
    }

    // Rohtest: Spielbild direkt auf den Bildschirm, keine Sortierung
    function rawFrame() {
        const w = canvas.width;
        const h = screenH;
        gl.bindFramebuffer(gl.FRAMEBUFFER, null);
        gl.viewport(0, REC_H, w, h);
        draw(gameTexture, true);
        probes.center = readPixel(Math.floor(w / 2), REC_H + Math.floor(h / 2));
        probes.top = readPixel(MARKER_PROBE, REC_H + h - 1 - MARKER_PROBE);
        probes.bottom = readPixel(MARKER_PROBE, REC_H + MARKER_PROBE);
        stats.unknown += 1;
    }

    // Vollbild-Dashcam: unsichtbar mitlaufen, jedes Bild (4:3 beschnitten) an die Aufnahme
    function captureFrame() {
        const w = canvas.width;
        const h = screenH;
        gl.bindFramebuffer(gl.FRAMEBUFFER, null);
        gl.viewport(0, REC_H, w, h);
        draw(gameTexture, flip);
        checkBlack(REC_H);
        if (!api.onFrame) return;
        const cw = Math.min(w, Math.round(h * 4 / 3));
        api.onFrame(canvas, Math.round((w - cw) / 2), 0, cw, h);
    }

    function loop(now) {
        if (!mode) return;
        if (mode === 'pip') pipFrame(now);
        else if (mode === 'raw') rawFrame();
        else captureFrame();
        updateStats(now);
        requestAnimationFrame(loop);
    }

    // options: { mode: 'pip' | 'raw' | 'capture', stats }
    function start(options = {}) {
        const wanted = options.mode || 'pip';
        pendingSnapshot = null;   // ein Live-Wunsch ueberholt ein angefordertes Standbild
        onReady = options.onReady || null;
        playerFramesSinceStart = 0;
        if (mode === wanted) {
            // laeuft schon: sofort bereit
            if (onReady) { const ready = onReady; onReady = null; ready(); }
            return;
        }
        if (!gl && !init()) return;
        const wasRunning = mode !== null;
        mode = wanted;
        showStats = !!options.stats;
        fillGaps = options.fill !== false;
        gapPending = false;
        rate.dash = 0;
        rate.since = 0;
        lastKind = null;
        resize();
        stats.since = performance.now();
        stats.lastMarker = stats.since;
        if (!wasRunning) requestAnimationFrame(loop);
    }

    function stop() {
        mode = null;
        pendingSnapshot = null;
    }

    // Anhalten mit Standbild: im naechsten Frame wird das Monitorbild in `target` (2D-Canvas) kopiert.
    // Laeuft die Schleife nicht (mehr) im pip-Modus, sofort anhalten.
    api.stopWithSnapshot = (target, done) => {
        if (mode !== 'pip' || !target) {
            stop();
            done();
            return;
        }
        pendingSnapshot = { target, done };
        setTimeout(() => {
            if (pendingSnapshot && pendingSnapshot.target === target) {
                stop();
                done();
            }
        }, 250);
    };

    window.addEventListener('resize', () => { if (mode) resize(); });

    // WebGL-Kontext verloren (z.B. GPU-Reset): beim Wiederherstellen alles neu aufbauen
    function watchContext() {
        canvas.addEventListener('webglcontextlost', (e) => { e.preventDefault(); }, false);
        canvas.addEventListener('webglcontextrestored', () => {
            gl = null;
            targets = null;
            if (init() && mode) resize();
        }, false);
    }

    return api;
})();
