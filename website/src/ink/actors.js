// Perry the ink drop, and the guide marks he draws. Both are dabs in the shared field.
import { THRESHOLD, INFLUENCE, strokeWeight } from './engine.js';
import { strokeDabs } from './path.js';

const clamp01 = (v) => (v < 0 ? 0 : v > 1 ? 1 : v);

// Fill an ellipse with dabs so the iso-edge lands on its outline.
export function fillEllipse(ink, cx, cy, rx, ry, guide = 0, wet = 0) {
  const rd = Math.max(1.5, Math.min(rx, ry) * 0.34);
  const s = rd * 0.55;
  const R = rd * INFLUENCE;
  const w = (6 * THRESHOLD * s * s) / (Math.PI * R * R);
  const ex = rx - rd * 0.05, ey = ry - rd * 0.05;
  for (let y = -ey; y <= ey + 1e-6; y += s) {
    const span = ex * Math.sqrt(Math.max(0, 1 - (y * y) / (ey * ey)));
    for (let x = -span; x <= span + 1e-6; x += s) ink.dab(cx + x, cy + y, rd, w, guide, wet);
  }
}

// A tapered line of dabs from a to b (px), radius r0 -> r1.
export function line(ink, ax, ay, bx, by, r0, r1, guide = 0, bend = 0) {
  const len = Math.hypot(bx - ax, by - ay);
  if (len < 0.5) return;
  const rMin = Math.min(r0, r1);
  const sp = Math.max(0.6, rMin * 0.22);
  const n = Math.ceil(len / sp);
  const nx = -(by - ay) / len, ny = (bx - ax) / len;
  for (let i = 0; i <= n; i++) {
    const t = i / n;
    const off = Math.sin(t * Math.PI) * bend;
    const r = r0 + (r1 - r0) * t;
    ink.dab(ax + (bx - ax) * t + nx * off, ay + (by - ay) * t + ny * off, r, strokeWeight(sp, r), guide, 0);
  }
}

// Perry: body + eyes + arm + tether to the notch.
// st: { on, x, y, R, sx, sy, tether, armOn, ax, ay, lookX, lookY } in px
export function drawPerry(ink, st, notch, eyes) {
  if (!st || st.on <= 0.01) return;
  const R = st.R * st.on;
  const rx = R * st.sx, ry = R * st.sy;
  fillEllipse(ink, st.x, st.y, rx, ry);
  if (st.tether > 0.01) {
    // neck from the notch mouth into the top of the body; thins as tether drops, so it pinches off
    const top = st.y - ry * 0.6;
    const neck = R * 0.5 * st.tether;
    line(ink, notch.x, notch.y - 6, st.x, top, R * 0.55 * Math.min(1, st.tether * 1.4), neck * 0.7 + 0.01, 0);
  }
  if (st.armOn > 0.01) {
    const ang = Math.atan2(st.ay - st.y, st.ax - st.x);
    const sx0 = st.x + Math.cos(ang) * rx * 0.8, sy0 = st.y + Math.sin(ang) * ry * 0.8;
    const full = Math.hypot(st.ax - sx0, st.ay - sy0), reach = Math.min(full, R * 1.45) / (full || 1);
    const ex = sx0 + (st.ax - sx0) * reach * st.armOn, ey = sy0 + (st.ay - sy0) * reach * st.armOn;
    line(ink, sx0, sy0, ex, ey, R * 0.13, R * 0.085, 0, R * 0.12 * Math.sign(Math.cos(ang) || 1));
    fillEllipse(ink, ex, ey, R * 0.15, R * 0.15);
  }
  // eyes: two tall ovals, like the app's character
  const ex = rx * 0.34, ey = -ry * 0.12;
  for (const side of [-1, 1]) {
    const cx = st.x + side * ex, cy = st.y + ey;
    const erx = R * 0.17, ery = R * 0.25;
    const p = eyes.pupil(cx, cy, erx, ery, 0.5);
    ink.eye({ x: cx, y: cy, rx: erx, ry: ery * st.sy, open: eyes.open, px: p.x, py: p.y, ps: eyes.ps * 1.12, squint: eyes.squint, glow: 0, angle: 0 });
  }
}

// ---------- guide marks ----------
const cache = new Map();

function circlePath(cx, cy, rx, ry, seed) {
  // one loop and a bit, starting top-left, slightly spiralling like a quick hand
  const pts = [];
  const a0 = -2.2 + seed * 0.3, sweep = Math.PI * 2 * 1.06;
  for (let i = 0; i <= 56; i++) {
    const t = i / 56, a = a0 + sweep * t;
    const k = 1 + 0.03 * Math.sin(t * 5 + seed * 3) + 0.035 * t;
    pts.push([cx + Math.cos(a) * rx * k, cy + Math.sin(a) * ry * k]);
  }
  return 'M' + pts.map((p) => p.map((v) => v.toFixed(1)).join(',')).join(' L');
}

function boxPath(x, y, w, h, seed) {
  // a quick marker loop round a card: rounded corners, slight lean, overshoots its start
  const r = Math.min(22, h * 0.3, w * 0.12), pts = [];
  const sides = [w - 2 * r, (Math.PI / 2) * r, h - 2 * r, (Math.PI / 2) * r, w - 2 * r, (Math.PI / 2) * r, h - 2 * r, (Math.PI / 2) * r];
  const total = sides.reduce((a, b) => a + b, 0);
  const at = (d) => {
    d = ((d % total) + total) % total;
    const c = [[x + r, y, 1, 0], [x + w - r, y + r, 0, -Math.PI / 2], [x + w, y + r, 0, 1], [x + w - r, y + h - r, 0, 0], [x + w - r, y + h, -1, 0], [x + r, y + h - r, 0, Math.PI / 2], [x, y + h - r, 0, -1], [x + r, y + r, 0, Math.PI]];
    for (let i = 0; i < 8; i++) {
      if (d <= sides[i]) {
        const [px, py, a, b] = c[i];
        if (i % 2 === 0) return i % 4 === 0 ? [px + a * d, py] : [px, py + b * d];
        const ang = b + d / r;
        return [px + Math.cos(ang) * r, py + Math.sin(ang) * r];
      }
      d -= sides[i];
    }
    return [x + r, y];
  };
  const start = sides[0] * 0.22, len = total * 1.07, n = 72;
  for (let i = 0; i <= n; i++) {
    const t = i / n, [px, py] = at(start + len * t);
    const drift = 2.5 + 7 * t * t, wob = Math.sin(t * 7 + seed * 5) * 1.6;
    const cx = x + w / 2, cy = y + h / 2, dx = px - cx, dy = py - cy, dl = Math.hypot(dx, dy) || 1;
    pts.push([px + (dx / dl) * (drift * (t > 0.92 ? 1 : 0.35) + wob) - t * 3, py + (dy / dl) * (drift * 0.35 + wob) + (t - 0.5) * 2.5]);
  }
  return 'M' + pts.map((p) => p.map((v) => v.toFixed(1)).join(',')).join(' L');
}

const DIGITS = {
  1: 'M0.3,0.24 L0.58,0.04 L0.58,1',
  2: 'M0.14,0.28 C0.16,0.04 0.84,-0.02 0.84,0.3 C0.84,0.56 0.32,0.74 0.12,1 L0.9,1',
  4: 'M0.66,1 L0.66,0.04 L0.1,0.7 L0.92,0.7',
  3: 'M0.16,0.12 C0.42,-0.04 0.86,0.04 0.8,0.3 C0.76,0.48 0.52,0.5 0.42,0.5 C0.62,0.5 0.9,0.6 0.84,0.8 C0.78,1.02 0.34,1.04 0.12,0.9',
};

function scalePath(d, x, y, s) {
  return d.replace(/(-?\d*\.?\d+),(-?\d*\.?\d+)/g, (_, a, b) => `${(x + a * s).toFixed(1)},${(y + b * s).toFixed(1)}`);
}

function markDabs(m, R) {
  const key = Object.entries(m).filter(([k]) => k !== 'progress' && k !== 'key').map(([k, v]) => `${k}:${typeof v === 'number' ? Math.round(v) : v}`).join('|') + `|${R.toFixed(2)}`;
  let c = cache.get(key);
  if (c) return c;
  let strokes = [];
  if (m.kind === 'circle') strokes = [circlePath(m.x, m.y, m.rx, m.ry, m.seed || 0.3)];
  else if (m.kind === 'box') strokes = [boxPath(m.x, m.y, m.w, m.h, m.seed || 0.3)];
  else if (m.kind === 'digit') strokes = [scalePath(DIGITS[m.n], m.x, m.y, m.s)];
  else if (m.kind === 'arrow') {
    const { x0, y0, x1, y1 } = m;
    const k = m.bend ?? 0.25;
    const mx = (x0 + x1) / 2 - (y1 - y0) * k, my = (y0 + y1) / 2 + (x1 - x0) * k;
    const ang = Math.atan2(y1 - my, x1 - mx), h = R * 6;
    strokes = [
      `M${x0},${y0} Q${mx},${my} ${x1},${y1}`,
      `M${x1 - Math.cos(ang - 0.55) * h},${y1 - Math.sin(ang - 0.55) * h} L${x1},${y1} L${x1 - Math.cos(ang + 0.55) * h},${y1 - Math.sin(ang + 0.55) * h}`,
    ];
  } else if (m.kind === 'dash') {
    const n = m.n || 7;
    for (let i = 0; i < n; i++) {
      const a = m.y0 + ((m.y1 - m.y0) * i) / n, b = a + ((m.y1 - m.y0) / n) * 0.55;
      strokes.push(`M${m.x},${a} L${m.x + (i % 2 ? 0.6 : -0.6)},${b}`);
    }
  } else if (m.kind === 'arcArrow') {
    // an arc around (x, y) from a0 to a1 (radians), arrowhead at the end
    const pts = [];
    for (let i = 0; i <= 24; i++) { const a = m.a0 + (m.a1 - m.a0) * (i / 24); pts.push([m.x + Math.cos(a) * m.r, m.y + Math.sin(a) * m.r]); }
    const [ex, ey] = pts[pts.length - 1], [px, py] = pts[pts.length - 3];
    const ang = Math.atan2(ey - py, ex - px), h = R * 5.5;
    strokes = ['M' + pts.map((p) => p.map((v) => v.toFixed(1)).join(',')).join(' L'),
      `M${ex - Math.cos(ang - 0.6) * h},${ey - Math.sin(ang - 0.6) * h} L${ex},${ey} L${ex - Math.cos(ang + 0.6) * h},${ey - Math.sin(ang + 0.6) * h}`];
  } else if (m.kind === 'under') {
    const w = m.x1 - m.x0;
    strokes = [`M${m.x0},${m.y} C${m.x0 + w * 0.3},${m.y + 4} ${m.x0 + w * 0.62},${m.y - 3} ${m.x1},${m.y + 2}`];
  } else if (m.kind === 'check') {
    strokes = [`M${m.x - m.s * 0.5},${m.y} L${m.x - m.s * 0.12},${m.y + m.s * 0.4} L${m.x + m.s * 0.6},${m.y - m.s * 0.5}`];
  }
  const all = [];
  let total = 0;
  const loop = m.kind === 'circle' || m.kind === 'box';
  for (const d of strokes) {
    const { dabs, length } = strokeDabs({ d, p: loop ? [[0, 0.3], [0.08, 1], [0.86, 1], [1, 0.25]] : [[0, 0.75], [0.12, 1], [0.85, 1], [1, 0.8]] }, R, 0.22);
    for (const dd of dabs) all.push({ ...dd, at: total + dd.u * length });
    total += length;
  }
  for (const d of all) d.u = d.at / total;
  c = { dabs: all, sp: R * 0.22 };
  cache.set(key, c);
  if (cache.size > 200) cache.delete(cache.keys().next().value);
  return c;
}

// m: { kind, key, progress 0..1, ...geometry px }, R: brush radius px
export function drawMark(ink, m, R) {
  const p = clamp01(m.progress);
  if (p <= 0) return;
  const { dabs, sp } = markDabs(m, R);
  for (const d of dabs) {
    if (d.u > p) break;
    const wet = clamp01(1 - (p - d.u) * 5) * (m.wet ?? 1);
    ink.dab(d.x, d.y, d.r, strokeWeight(sp, d.r), 1, wet);
  }
}
