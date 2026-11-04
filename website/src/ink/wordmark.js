import { strokeDabs } from './path.js';
import { BRUSH, LETTERS, GAPS } from './glyphs.js';
import { strokeWeight } from './engine.js';

const SPACING = 0.2;
const clamp01 = (v) => (v < 0 ? 0 : v > 1 ? 1 : v);
const easeInQuad = (t) => t * t;
const smooth = (t) => t * t * (3 - 2 * t);
const fract = (v) => v - Math.floor(v);

// Prepares the wordmark once; draws it at any scale, paint clock and drain progress.
export class Wordmark {
  constructor() {
    this.strokes = [];
    this.eyeAnchors = [];
    let cursor = 0, prevRight = null;
    LETTERS.forEach((L, li) => {
      const cr = Math.cos(L.rot || 0), sr = Math.sin(L.rot || 0);
      const built = L.strokes.map((s) => {
        const { dabs, length } = strokeDabs(s, BRUSH, SPACING);
        for (const d of dabs) {
          const x = d.x - 45, y = d.y - 50;
          d.x = 45 + x * cr - y * sr; d.y = 50 + x * sr + y * cr + (L.dy || 0);
        }
        return { ...s, dabs, length, spacing: BRUSH * SPACING, letter: li };
      });
      let minX = Infinity, maxX = -Infinity;
      for (const s of built) for (const d of s.dabs) { minX = Math.min(minX, d.x - d.r); maxX = Math.max(maxX, d.x + d.r); }
      const dx = prevRight === null ? -minX : prevRight + GAPS[li - 1] - minX;
      for (const s of built) for (const d of s.dabs) d.x += dx;
      prevRight = maxX + dx;
      this.strokes.push(...built);
      if (L.eye) {
        const sh = built[built.length - 1];
        const ball = sh.dabs[sh.dabs.length - 1];
        const back = sh.dabs[sh.dabs.length - 6];
        const ux = ball.x - back.x, uy = ball.y - back.y, ul = Math.hypot(ux, uy) || 1;
        this.eyeAnchors.push({ x: ball.x - (ux / ul) * ball.r * 0.2, y: ball.y - (uy / ul) * ball.r * 0.2, r: ball.r, dab: ball });
      }
      cursor = prevRight;
    });
    let t = 0;
    for (const s of this.strokes) {
      s.start = t;
      s.dur = 0.07 + s.length / 980;
      t += s.dur * 0.6;
    }
    this.paintEnd = t + 0.1;
    let minY = Infinity, maxY = -Infinity;
    for (const s of this.strokes) for (const d of s.dabs) { minY = Math.min(minY, d.y - d.r); maxY = Math.max(maxY, d.y + d.r); }
    this.box = { x: 0, y: minY, w: cursor, h: maxY - minY };
    this.strokes.flatMap((s) => s.dabs).forEach((d, i) => { d.seed = fract(Math.sin(i * 12.9898) * 43758.5453); });
  }

  // place: {x, y, scale} maps letter units to CSS px. clock: seconds into paint (Infinity = done).
  // drain: 0..1 toward target {x, y} in CSS px.
  // touch: { x, y, r, s } pushes ink away from the pointer; wob: { x, t } a click ripple (seconds since).
  draw(ink, place, clock = Infinity, drain = 0, target = null, touch = null, wob = null) {
    const { x: ox, y: oy, scale } = place;
    const out = this.eyePlaces || (this.eyePlaces = this.eyeAnchors.map(() => ({ x: 0, y: 0, k: 1, r: 0 })));
    const draining = drain > 0 && target;
    const anticip = draining ? smooth(clamp01(drain / 0.12)) : 0;
    // Genie into the notch: a continuous warp, so the word bends like cloth instead of breaking.
    // Rows nearer the notch rise first; the funnel narrows everything toward the notch's width.
    const top = oy + this.box.y * scale, H = this.box.h * scale;
    const reach = draining ? Math.max(1, top + H - target.y) : 1;
    const F = reach * (0.06 + 1.1 * smooth(clamp01(drain * 1.25)));
    const halfW = (this.box.w * scale) / 2;
    const wMin = Math.min(0.5, (target.w || 90) / 2 / halfW);
    const push = (x, y) => {
      const dx = x - touch.x, dy = y - touch.y, d2 = dx * dx + dy * dy;
      const f = touch.s * Math.exp(-d2 / (touch.r * touch.r));
      if (f < 0.05) return [x, y];
      const d = Math.sqrt(d2) || 1;
      return [x + (dx / d) * f, y + (dy / d) * f];
    };
    const wobble = (x) => wob.a * Math.exp(-wob.t * 3.6) * Math.sin(wob.t * 17 - Math.abs(x - wob.x) * 0.012);
    const flow = (d, x, y) => {
      const yRel = clamp01((y - top) / H);
      const Ey = easeInQuad(clamp01((drain - yRel * 0.32) / 0.68));
      y -= anticip * scale * 5 * (1 - yRel);
      y += (target.y - y) * Ey;
      const dist = Math.max(0, y - target.y);
      const w = Math.pow(clamp01(dist / F), 0.75);
      const span = wMin + (1 - wMin) * w;
      x = target.x + (x - target.x) * span;
      const k = (0.5 + 0.5 * Math.sqrt(span)) * clamp01((dist - 4) / (reach * 0.08));
      return [x, y, k];
    };
    for (const s of this.strokes) {
      const local = clamp01((clock - s.start) / s.dur);
      if (local <= 0) continue;
      for (const d of s.dabs) {
        if (d.u > local) break;
        const age = clock - (s.start + d.u * s.dur);
        const bloom = clock === Infinity ? 1 : 0.8 + 0.2 * (1 - Math.exp(-age * 7));
        const wet = clock === Infinity ? 0 : Math.max(0, 1 - age / 1.9);
        let x = ox + d.x * scale, y = oy + d.y * scale, k = 1;
        if (touch) [x, y] = push(x, y);
        if (wob) y += wobble(x);
        if (draining) [x, y, k] = flow(d, x, y);
        const r = d.r * scale * bloom * k;
        ink.dab(x, y, r, strokeWeight(s.spacing * scale, r), 0, wet);
      }
    }
    this.eyeAnchors.forEach((a, i) => {
      let x = ox + a.x * scale, y = oy + a.y * scale, k = 1;
      if (touch) [x, y] = push(x, y);
      if (wob) y += wobble(x);
      if (draining) [x, y, k] = flow(a.dab, x, y);
      Object.assign(out[i], { x, y, k, r: a.r * scale * k });
    });
    return out;
  }
}
