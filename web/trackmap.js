// Mini-Map einer Messung: Fahrspuren von Streifenwagen und Ziel als schematische Skizze
// (Raster, Massstab, Nordpfeil). Eine GTA-Karte als Hintergrund steht dem NUI nicht zur Verfuegung.
//
// track: { points: [[ms, eigenX, eigenY, zielX?, zielY?], ...], marks: { start?, finish? } }
// Koordinaten in Metern relativ zum Startpunkt, x = Osten, y = Norden.
'use strict';

const TrackMap = (() => {
    const COLORS = {
        bg: '#0b0c0d',
        grid: 'rgba(255, 255, 255, 0.07)',
        own: '#e6e6e6',
        target: '#ff5a4e',
        gap: 'rgba(255, 210, 94, 0.85)',
        text: '#9a9a9a',
        mark: '#ffd25e',
    };
    const FONT = '"Lucida Console", Consolas, monospace';
    const GRID_STEPS = [10, 25, 50, 100, 250, 500, 1000];

    function bounds(track) {
        let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
        const add = (x, y) => {
            if (!Number.isFinite(x) || !Number.isFinite(y)) return;
            minX = Math.min(minX, x); maxX = Math.max(maxX, x);
            minY = Math.min(minY, y); maxY = Math.max(maxY, y);
        };
        track.points.forEach((p) => { add(p[1], p[2]); add(p[3], p[4]); });
        Object.values(track.marks || {}).forEach((m) => add(m.x, m.y));
        if (!Number.isFinite(minX)) return null;
        // Mindestausdehnung, damit kurze Messungen nicht riesig gezoomt werden
        const pad = Math.max(15, Math.max(maxX - minX, maxY - minY) * 0.12);
        return { minX: minX - pad, minY: minY - pad, maxX: maxX + pad, maxY: maxY + pad };
    }

    // Position zum Zeitpunkt t (ms) linear zwischen zwei Punkten
    function positionAt(points, t, ix, iy) {
        let prev = null;
        for (const p of points) {
            if (!Number.isFinite(p[ix])) continue;
            if (p[0] >= t) {
                if (!prev) return [p[ix], p[iy]];
                const k = (t - prev[0]) / Math.max(1, p[0] - prev[0]);
                return [prev[ix] + (p[ix] - prev[ix]) * k, prev[iy] + (p[iy] - prev[iy]) * k];
            }
            prev = p;
        }
        return prev ? [prev[ix], prev[iy]] : null;
    }

    function duration(track) {
        const pts = track && track.points;
        return pts && pts.length ? pts[pts.length - 1][0] : 0;
    }

    // t: Zeitpunkt in ms (null = ganze Spur, Endzustand). labels: { own, target, north }
    function draw(ctx, w, h, track, t = null, labels = {}) {
        ctx.fillStyle = COLORS.bg;
        ctx.fillRect(0, 0, w, h);
        if (!track || !Array.isArray(track.points) || track.points.length < 2) return;
        const b = bounds(track);
        if (!b) return;

        // gleicher Massstab in x und y, zentriert
        const scale = Math.min(w / (b.maxX - b.minX), h / (b.maxY - b.minY));
        const cx = (b.minX + b.maxX) / 2;
        const cy = (b.minY + b.maxY) / 2;
        const sx = (x) => w / 2 + (x - cx) * scale;
        const sy = (y) => h / 2 - (y - cy) * scale;   // Norden oben

        // Raster
        const step = GRID_STEPS.find((s) => s * scale >= 28) || GRID_STEPS[GRID_STEPS.length - 1];
        ctx.strokeStyle = COLORS.grid;
        ctx.lineWidth = 1;
        ctx.beginPath();
        for (let x = Math.floor(b.minX / step) * step; x <= b.maxX; x += step) { ctx.moveTo(sx(x), 0); ctx.lineTo(sx(x), h); }
        for (let y = Math.floor(b.minY / step) * step; y <= b.maxY; y += step) { ctx.moveTo(0, sy(y)); ctx.lineTo(w, sy(y)); }
        ctx.stroke();

        const end = t === null ? Infinity : t;
        const trail = (ix, iy, color, width) => {
            ctx.strokeStyle = color;
            ctx.lineWidth = width;
            ctx.lineJoin = 'round';
            ctx.beginPath();
            let started = false;
            for (const p of track.points) {
                if (p[0] > end) break;
                if (!Number.isFinite(p[ix])) continue;
                if (started) ctx.lineTo(sx(p[ix]), sy(p[iy]));
                else { ctx.moveTo(sx(p[ix]), sy(p[iy])); started = true; }
            }
            const now = t === null ? null : positionAt(track.points, t, ix, iy);
            if (started && now) ctx.lineTo(sx(now[0]), sy(now[1]));
            ctx.stroke();
        };
        trail(3, 4, COLORS.target, 2);
        trail(1, 2, COLORS.own, 2);

        // VASCAR: Start- und Endmarke
        const mark = (m, label) => {
            if (!m) return;
            ctx.fillStyle = COLORS.mark;
            ctx.fillRect(sx(m.x) - 3, sy(m.y) - 3, 6, 6);
            ctx.font = `10px ${FONT}`;
            ctx.textAlign = 'left';
            ctx.textBaseline = 'bottom';
            ctx.fillText(label, sx(m.x) + 5, sy(m.y) - 2);
        };
        mark(track.marks && track.marks.start, 'A');
        mark(track.marks && track.marks.finish, 'B');

        // aktuelle Positionen + Abstand
        const tt = t === null ? duration(track) : t;
        const own = positionAt(track.points, tt, 1, 2);
        const target = positionAt(track.points, tt, 3, 4);
        if (own && target) {
            ctx.strokeStyle = COLORS.gap;
            ctx.setLineDash([4, 3]);
            ctx.beginPath();
            ctx.moveTo(sx(own[0]), sy(own[1]));
            ctx.lineTo(sx(target[0]), sy(target[1]));
            ctx.stroke();
            ctx.setLineDash([]);
            const gap = Math.hypot(target[0] - own[0], target[1] - own[1]);
            ctx.fillStyle = COLORS.gap;
            ctx.font = `11px ${FONT}`;
            ctx.textAlign = 'center';
            ctx.textBaseline = 'bottom';
            ctx.fillText(`${Math.round(gap)} m`, (sx(own[0]) + sx(target[0])) / 2, (sy(own[1]) + sy(target[1])) / 2 - 4);
        }
        const dot = (p, color) => {
            if (!p) return;
            ctx.fillStyle = color;
            ctx.beginPath();
            ctx.arc(sx(p[0]), sy(p[1]), 4.5, 0, Math.PI * 2);
            ctx.fill();
            ctx.strokeStyle = '#000';
            ctx.lineWidth = 1.5;
            ctx.stroke();
        };
        dot(target, COLORS.target);
        dot(own, COLORS.own);

        // Massstab, Nordpfeil, Legende, Zeit
        ctx.font = `10px ${FONT}`;
        ctx.fillStyle = COLORS.text;
        ctx.strokeStyle = COLORS.text;
        ctx.lineWidth = 1.5;
        ctx.textBaseline = 'bottom';
        ctx.textAlign = 'left';
        ctx.beginPath();
        ctx.moveTo(8, h - 8); ctx.lineTo(8 + step * scale, h - 8);
        ctx.moveTo(8, h - 11); ctx.lineTo(8, h - 5);
        ctx.moveTo(8 + step * scale, h - 11); ctx.lineTo(8 + step * scale, h - 5);
        ctx.stroke();
        ctx.fillText(`${step} m`, 8, h - 12);

        ctx.textAlign = 'right';
        ctx.textBaseline = 'top';
        ctx.fillText(`▲ ${labels.north || 'N'}`, w - 8, 6);
        ctx.textAlign = 'left';
        ctx.fillStyle = COLORS.own;
        ctx.fillText(`● ${labels.own || ''}`, 8, 6);
        ctx.fillStyle = COLORS.target;
        ctx.fillText(`● ${labels.target || ''}`, 8, 19);
        ctx.fillStyle = COLORS.text;
        ctx.textAlign = 'right';
        ctx.textBaseline = 'bottom';
        ctx.fillText(`${(tt / 1000).toFixed(1).replace('.', ',')} s`, w - 8, h - 6);
    }

    return { draw, duration };
})();
