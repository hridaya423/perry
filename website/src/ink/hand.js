import { FELIX } from './felix.js';
import { strokeDabs } from './path.js';
import { strokeWeight } from './engine.js';

const clamp01 = (v) => (v < 0 ? 0 : v > 1 ? 1 : v);
const cache = new Map();
const LIFT = 26;
const SNUG = new Set([...".,:;'!?()"]);

function bounds(d) {
  const xs = [...d.matchAll(/(-?[\d.]+) (-?[\d.]+)/g)].map((m) => +m[1]);
  return [Math.min(...xs), Math.max(...xs)];
}

function chaikin(p) {
  if (p.length < 3) return p;
  const out = [p[0]];
  for (let k = 0; k < p.length - 1; k++) {
    const [ax, ay] = p[k], [bx, by] = p[k + 1];
    out.push([ax * 0.75 + bx * 0.25, ay * 0.75 + by * 0.25], [ax * 0.25 + bx * 0.75, ay * 0.25 + by * 0.75]);
  }
  out.push(p[p.length - 1]);
  return out;
}

function press(ds) {
  const n = ds.length, k = new Array(n).fill(1);
  for (let j = 0; j < n; j++) {
    const a = ds[Math.max(0, j - 2)], b = ds[Math.min(n - 1, j + 2)];
    const dx = b.x - a.x, dy = b.y - a.y, l = Math.hypot(dx, dy) || 1;
    k[j] = 1 + 0.38 * (dy / l) - 0.12 * Math.abs(dx / l);
  }
  for (let j = 0; j < n; j++) {
    let sum = 0, cnt = 0;
    for (let m = Math.max(0, j - 4); m <= Math.min(n - 1, j + 4); m++) { sum += k[m]; cnt++; }
    ds[j].r *= sum / cnt;
  }
}

function layout(text, size, R) {
  const key = `${text}|${size.toFixed(1)}|${R.toFixed(2)}`;
  let c = cache.get(key);
  if (c) return c;
  const s = size / 1000;
  const dabs = [];
  let pen = 0, total = 0;
  [...text].forEach((ch, i) => {
    const [adv, d] = FELIX[ch] || FELIX[' '];
    if (ch === ' ') { pen += 240; return; }
    let shift = 0, step = adv;
    if (SNUG.has(ch)) { const [l, r] = bounds(d); shift = 45 - l; step = r - l + 70; }
    pen += shift;
    const lift = Math.sin(i * 2.3) * 0.006 * size, lean = 0.07 + Math.sin(i * 1.7 + 1) * 0.012;
    const at = (a, b) => [(pen + a + b * lean) * s, -b * s + lift];
    for (const sub of d.split('M').filter((p) => p.trim())) {
      let path;
      if (sub.includes('C')) path = ('M' + sub).replace(/(-?[\d.]+) (-?[\d.]+)/g, (_, a, b) => at(+a, +b).map((v) => v.toFixed(2)).join(' '));
      else {
        const pts = chaikin(chaikin([...sub.matchAll(/(-?[\d.]+) (-?[\d.]+)/g)].map((m) => at(+m[1], +m[2]))));
        path = 'M' + pts.map((q) => q.map((v) => v.toFixed(2)).join(' ')).join(' L');
      }
      const { dabs: ds, length } = strokeDabs({ d: path, p: [[0, 0.55], [0.12, 1], [0.85, 0.95], [1, 0.5]] }, R, 0.22);
      press(ds);
      for (const dd of ds) dabs.push({ ...dd, at: total + dd.u * length });
      total += length + LIFT;
    }
    pen += step - shift;
  });
  for (const d of dabs) d.u = d.at / total;
  c = { dabs, sp: R * 0.22, width: pen * s, length: total };
  cache.set(key, c);
  return c;
}

export const writing = (text, size, R) => layout(text, size, R);

export function drawWriting(ink, { text, x, y, size, progress }, R) {
  const p = clamp01(progress);
  if (p <= 0) return;
  const { dabs, sp } = layout(text, size, R);
  for (const d of dabs) {
    if (d.u > p) break;
    ink.dab(x + d.x, y + d.y, d.r, strokeWeight(sp, d.r), 1, clamp01(1 - (p - d.u) * 4));
  }
}
