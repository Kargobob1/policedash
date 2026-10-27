// Dashcam-OSD (Videobild-Einblendung) als Canvas-Zeichnung.
// Dieselbe Funktion zeichnet die Anzeige im Spiel und die Einblendung im aufgenommenen Video,
// daher sieht das Video genau so aus wie der Monitor.
//
//   oben links:   Datum TT.MM.JJ, Wegstrecke seit Einschalten      oben Mitte: Messmodus
//   oben rechts:  Uhrzeit, Bildzaehler (hex), Zoomkennzahl
//   unten:        G: Messwert (nach der Messung)  ...  E: Eigengeschwindigkeit
//   Balken:       W: Messweg  Z: Messzeit  Ziel  ...  Kennung
'use strict';

const OSD = (() => {
    const data = {
        clock: null,          // { year, month, day, h, m, s } oder null = Echtzeit
        realClock: false,
        speed: 0,             // E, Einheit wie unit
        mode: 'MAN',
        modeLabel: 'MAN',
        odometer: 0,          // m seit Einschalten
        measured: null,       // G nach der Messung
        liveDistance: null,   // W
        liveTime: null,       // Z
        running: false,
        target: null,         // Kennzeichen
        targetLocked: false,
        unit: 'km/h',
        brand: 'PoliceDash',
        zoom: '01',
        color: '#ffffff',
        startedAt: performance.now(),
    };

    const FONT = '"Lucida Console", Consolas, "Courier New", monospace';
    const pad2 = (n) => String(Math.trunc(Number(n) || 0)).padStart(2, '0');
    const comma = (v, digits) => v.toFixed(digits).replace('.', ',');
    const thousands = (n) => String(Math.max(0, Math.trunc(n))).replace(/\B(?=(\d{3})+(?!\d))/g, '.');

    function clock() {
        if (data.clock && !data.realClock) return data.clock;
        const d = new Date();
        return { year: d.getFullYear(), month: d.getMonth() + 1, day: d.getDate(), h: d.getHours(), m: d.getMinutes(), s: d.getSeconds() };
    }

    // Bildzaehler wie beim Original: hex, laeuft mit 25 Bildern/s ab Einschalten
    function frameCounter() {
        const frames = Math.floor((performance.now() - data.startedAt) * 25 / 1000);
        return frames.toString(16).toUpperCase().padStart(8, '0');
    }

    function reset() {
        data.startedAt = performance.now();
        data.measured = null;
        data.liveDistance = null;
        data.liveTime = null;
        data.running = false;
    }

    // Textblock auf dunklem, eckigem Kasten; Zeilen rechtsbuendig im Kasten
    function box(ctx, lines, x, y, size, anchor) {
        ctx.font = `bold ${size}px ${FONT}`;
        const padX = size * 0.35;
        const lineH = size * 1.15;
        const width = Math.max(...lines.map((l) => ctx.measureText(l).width)) + padX * 2;
        const height = lineH * lines.length + size * 0.2;
        const left = anchor === 'right' ? x - width : anchor === 'center' ? x - width / 2 : x;

        ctx.fillStyle = 'rgba(0, 0, 0, 0.78)';
        ctx.fillRect(left, y, width, height);
        ctx.fillStyle = data.color;
        ctx.textAlign = 'right';
        ctx.textBaseline = 'top';
        lines.forEach((line, i) => ctx.fillText(line, left + width - padX, y + size * 0.15 + i * lineH));
    }

    // Grosse Schrift direkt aufs Bild, mit dunkler Kontur
    function bigText(ctx, text, x, y, size, align) {
        ctx.font = `bold ${size}px ${FONT}`;
        ctx.textAlign = align;
        ctx.textBaseline = 'alphabetic';
        ctx.lineJoin = 'round';
        ctx.lineWidth = Math.max(2, size * 0.14);
        ctx.strokeStyle = 'rgba(0, 0, 0, 0.85)';
        ctx.strokeText(text, x, y);
        ctx.fillStyle = data.color;
        ctx.fillText(text, x, y);
    }

    function scanlines(ctx, w, h) {
        ctx.fillStyle = 'rgba(0, 0, 0, 0.10)';
        const step = Math.max(2, Math.round(h / 240));
        for (let y = 0; y < h; y += step * 2) ctx.fillRect(0, y, w, step);
    }

    // opts: { clear, scanlines }
    function draw(ctx, w, h, opts = {}) {
        if (opts.clear) ctx.clearRect(0, 0, w, h);
        if (opts.scanlines) scanlines(ctx, w, h);

        const small = Math.round(h / 24);
        const big = Math.round(h / 13);
        const pad = Math.round(h / 36);
        const c = clock();
        const unit = data.unit;

        // oben
        box(ctx, [`${pad2(c.day)}.${pad2(c.month)}.${pad2(c.year % 100)}`, `${thousands(data.odometer)}m`], pad, pad, small, 'left');
        box(ctx, [data.modeLabel], w / 2, pad, small, 'center');
        box(ctx, [`${pad2(c.h)}:${pad2(c.m)}:${pad2(c.s)}`, frameCounter(), data.zoom], w - pad, pad, small, 'right');

        // Balken ganz unten
        const barH = Math.round(small * 1.55);
        const barY = h - barH;
        ctx.fillStyle = '#000';
        ctx.fillRect(0, barY, w, barH);
        ctx.font = `bold ${small}px ${FONT}`;
        ctx.fillStyle = data.color;
        ctx.textBaseline = 'middle';
        const midY = barY + barH / 2;

        const dist = typeof data.liveDistance === 'number' ? String(Math.round(data.liveDistance)) : '0';
        const time = typeof data.liveTime === 'number' ? comma(data.liveTime, 2) : '0,00';
        ctx.textAlign = 'left';
        ctx.fillText(`W:${dist.padStart(5)}m.  Z:${time.padStart(6)}s.`, pad, midY);
        ctx.textAlign = 'right';
        ctx.fillText(data.brand, w - pad, midY);
        if (data.target) {
            // Ziel links neben der Kennung; [ ] = gelockt
            const brandWidth = ctx.measureText(data.brand).width;
            ctx.fillText(data.targetLocked ? `[${data.target}]` : data.target, w - pad - brandWidth - small * 1.5, midY);
        }

        // Messwert und Eigengeschwindigkeit ueber dem Balken
        const lineY = barY - big * 0.3;
        const g = typeof data.measured === 'number' && !data.running ? comma(data.measured, 2) : '0,00';
        bigText(ctx, `G:${g.padStart(7)}${unit}`, pad, lineY, big, 'left');
        bigText(ctx, `E:${String(Math.max(0, Math.round(data.speed))).padStart(4)}${unit}`, w - pad, lineY, big, 'right');
    }

    return { data, draw, reset };
})();
