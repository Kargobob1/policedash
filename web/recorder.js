// Videoaufnahme NUR der Dashcam mit eingebranntem OSD (WebM).
// Bilder kommen von PiP.onFrame (Bild-im-Bild: Dashcam-Frames, Vollbild: Spielbild im capture-Modus).
// Ablauf: rec:start (Messbeginn) -> rec:finish (nach Annahme durch den Server, mit Messnummer
// und Nachlauf, damit G im Bild steht) -> Base64-Stuecke an den Client -> Server.
//
// Jede Aufnahme ist eine eigene Session. MediaRecorder.stop() meldet sich asynchron; die Session
// raeumt dann nur ihre eigenen Sachen auf und fasst die gemeinsamen (PiP) nur an, solange sie
// noch die aktuelle ist. So kann eine neue Messung direkt nach der alten starten.
'use strict';

const Recorder = (() => {
    const SIZES = { pip: [960, 720], cam: [960, 720] };
    // Ein Videobild pro Dashcam-Bild (captureStream(0) + requestFrame) statt fest 25 fps abzutasten:
    // ~15 Dashcam-Bilder in 25 fps ergaben ungleich verdoppelte Bilder (Ruckeln bei hohem Tempo).
    // Vollbild-Dashcam liefert jedes Spielbild, dort auf MAX_FPS begrenzen.
    const MAX_FPS = 30;
    const MIN_FRAME_MS = 1000 / MAX_FPS - 2;   // etwas Spiel fuer rAF-Schwankungen

    let current = null;        // laufende Session (nimmt Frames auf, auch im Nachlauf)
    let latest = null;         // zuletzt gestartete Session ohne Messnummer (wartet auf finish/abort)
    let chunkSize = 262144;

    function pickMime() {
        const types = ['video/webm;codecs=vp9', 'video/webm;codecs=vp8', 'video/webm'];
        return types.find((t) => window.MediaRecorder && MediaRecorder.isTypeSupported(t)) || '';
    }

    function frame(source, sx, sy, sw, sh) {
        const s = current;
        if (!s || !s.recording) return;
        const now = performance.now();
        if (now - s.lastFrameAt < MIN_FRAME_MS) return;
        s.lastFrameAt = now;
        s.ctx.drawImage(source, sx, sy, sw, sh, 0, 0, s.canvas.width, s.canvas.height);
        OSD.draw(s.ctx, s.canvas.width, s.canvas.height, { scanlines: true });
        if (s.track) s.track.requestFrame();
    }

    // Gemeinsame Hooks loesen, aber nur wenn keine neuere Session sie uebernommen hat
    function detach(s) {
        clearTimeout(s.maxTimer);
        s.recording = false;
        if (current !== s) return;
        current = null;
        PiP.onFrame = null;
        if (s.usingCapture) PiP.stop();
    }

    function cleanup(s) {
        detach(s);
        clearTimeout(s.tailTimer);
        s.stream.getTracks().forEach((t) => t.stop());
    }

    // Aufnahme beenden, liefert Promise<Blob | null>
    function stopSession(s) {
        if (s.stopped) return s.stopped;
        detach(s);   // ab sofort keine Frames mehr, neue Session kann uebernehmen
        s.stopped = new Promise((resolve) => {
            if (s.recorder.state === 'inactive') { cleanup(s); resolve(null); return; }
            s.recorder.onstop = () => {
                cleanup(s);
                resolve(s.chunks.length ? new Blob(s.chunks, { type: s.mime }) : null);
            };
            s.recorder.stop();
        });
        return s.stopped;
    }

    function blobToBase64(blob) {
        return new Promise((resolve, reject) => {
            const reader = new FileReader();
            reader.onload = () => resolve(String(reader.result).replace(/^data:[^,]*,/, ''));
            reader.onerror = reject;
            reader.readAsDataURL(blob);
        });
    }

    async function send(id, blob) {
        if (!blob) return;
        const data = await blobToBase64(blob);
        const total = Math.ceil(data.length / chunkSize);
        for (let i = 0; i < total; i += 1) {
            await post('videoChunk', { id, index: i + 1, total, chunk: data.slice(i * chunkSize, (i + 1) * chunkSize) });
        }
    }

    function stopAndSend(s) {
        clearTimeout(s.tailTimer);
        stopSession(s).then((blob) => send(s.finishId, blob)).catch(() => {});
    }

    // options: { device: 'pip' | 'cam', maxSeconds, bitrate, chunkSize }
    function start(options = {}) {
        // Vorherige Aufnahme: im Nachlauf -> jetzt beenden und senden, sonst verwerfen
        if (current) {
            if (current.finishId) stopAndSend(current);
            else abort();
        }
        const mime = pickMime();
        if (!mime || !options.device) return;
        if (options.chunkSize) chunkSize = options.chunkSize;

        const [w, h] = SIZES[options.device] || SIZES.pip;
        const canvas = document.createElement('canvas');
        canvas.width = w;
        canvas.height = h;
        const ctx = canvas.getContext('2d');
        ctx.fillStyle = '#000';
        ctx.fillRect(0, 0, w, h);

        // Ohne requestFrame (alter CEF) faellt es auf feste Abtastung zurueck
        let stream = canvas.captureStream(0);
        let track = stream.getVideoTracks()[0];
        if (!track || typeof track.requestFrame !== 'function') {
            stream.getTracks().forEach((t) => t.stop());
            stream = canvas.captureStream(25);
            track = null;
        }
        const s = {
            canvas, ctx, stream, track, mime,
            lastFrameAt: -Infinity,
            recorder: new MediaRecorder(stream, { mimeType: mime, videoBitsPerSecond: options.bitrate || 1500000 }),
            chunks: [],
            recording: true,
            usingCapture: options.device === 'cam',
            stopped: null,
            finishId: null,
            maxTimer: null,
            tailTimer: null,
        };
        s.recorder.ondataavailable = (e) => { if (e.data && e.data.size) s.chunks.push(e.data); };
        s.recorder.start(1000);
        current = s;

        PiP.onFrame = frame;
        if (s.usingCapture) PiP.start({ mode: 'capture' });
        // Sicherheitsgrenze; die Datei bleibt erhalten, bis finish() die Messnummer liefert
        s.maxTimer = setTimeout(() => stopSession(s), (options.maxSeconds || 30) * 1000);
        latest = s;
    }

    // Nach Annahme der Messung: noch `tail` Sekunden aufnehmen, dann senden
    function finish({ id, tail }) {
        const s = latest;
        if (!s || s.finishId || typeof id !== 'string') return;
        s.finishId = id;
        latest = null;
        const delay = s.recording ? Math.max(0, Number(tail) || 0) * 1000 : 0;
        s.tailTimer = setTimeout(() => stopAndSend(s), delay);
    }

    // Verwerfen (ungueltige/abgebrochene Messung, Geraet aus). Eine Aufnahme im Nachlauf
    // gehoert zu einer angenommenen Messung: die wird sofort beendet und gesendet.
    function abort() {
        const s = latest;
        if (!s) {
            if (current && current.finishId) stopAndSend(current);
            return;
        }
        latest = null;
        s.chunks = [];
        if (s.recorder.state !== 'inactive') {
            s.recorder.onstop = () => cleanup(s);
            detach(s);
            s.recorder.stop();
        } else {
            cleanup(s);
        }
    }

    return { start, finish, abort, isRecording: () => !!(current && current.recording) };
})();
