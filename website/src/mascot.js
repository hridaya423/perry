// Geometry mirrors PerryCharacterView in perry/Packages/PerryOverlay, in its unit square x100.

const NS = 'http://www.w3.org/2000/svg';
const SAGE = '#9ccbb6', CARBON = '#0c0d0e';
const TIP = [-30, -40], CENTER = [10.1, 12.4], RADIUS = 30, FACE = [9.6, 10.4];
const BOX = [-42, -50, 100];
const TIP_PCT = [((TIP[0] - BOX[0]) / BOX[2]) * 100, ((TIP[1] - BOX[1]) / BOX[2]) * 100];

const BODY = (() => {
  const L = Math.hypot(CENTER[0] - TIP[0], CENTER[1] - TIP[1]);
  const a = Math.atan2(CENTER[1] - TIP[1], CENTER[0] - TIP[0]) - Math.PI / 2;
  const r = RADIUS, k = 0.5523 * r, c = Math.cos(a), s = Math.sin(a);
  const P = (x, y) => `${(TIP[0] + x * c - y * s).toFixed(2)},${(TIP[1] + x * s + y * c).toFixed(2)}`;
  return `M${P(2.2, 3)} Q${P(0, -1.2)} ${P(-2.2, 3)} C${P(-13, 17)} ${P(-r, L - 24)} ${P(-r, L)} C${P(-r, L + k)} ${P(-k, L + r)} ${P(0, L + r)} C${P(k, L + r)} ${P(r, L + k)} ${P(r, L)} C${P(r, L - 20)} ${P(10, 14)} ${P(2.2, 3)} Z`;
})();

const vertical = (len, w) => ({ d: `M0,${-len / 2} L0,${len / 2}`, w });
const arc = (len, bend, w) => ({ d: `M${-len / 2},${bend / 2} Q0,${-bend * 1.5} ${len / 2},${bend / 2}`, w });
const FACES = {
  open: { eye: vertical(8.5, 7.2) },
  wide: { eye: vertical(12, 8.5) },
  focus: { eye: vertical(3.5, 7.2) },
  happy: { eye: arc(8.5, 4, 5.5), mouth: arc(10, -4, 4.5) },
  closed: { eye: arc(10, -4, 6.5) },
};

const el = (tag, attrs) => { const n = document.createElementNS(NS, tag); for (const k in attrs) n.setAttribute(k, attrs[k]); return n; };

export function createMascot(host) {
  const svg = el('svg', { viewBox: BOX.slice(0, 2).concat(BOX[2], BOX[2]).join(' ') });
  const rim = el('path', { d: BODY, fill: '#fff', stroke: '#fff', 'stroke-width': 14, 'stroke-linejoin': 'round' });
  rim.style.filter = 'drop-shadow(0 2.5px 4.5px rgba(0,0,0,.3))';
  const body = el('path', { d: BODY, fill: SAGE, stroke: CARBON, 'stroke-width': 5.5, 'stroke-linejoin': 'round' });
  const face = el('g', {});
  const stroke = { fill: 'none', stroke: CARBON, 'stroke-linecap': 'round' };
  const eyes = [-1, 1].map((side) => {
    const g = el('g', {});
    const p = el('path', stroke);
    g.append(p);
    face.append(g);
    return { side, g, p };
  });
  const mouth = el('path', stroke);
  face.append(mouth);
  svg.append(rim, body, face);
  host.append(svg);

  const st = { blink: 0, nextBlink: 1.5, v: 0, last: null, mood: null };

  return {
    set(s, t, dt) {
      const size = s.size || st.size || 60;
      if (s.size && s.size !== st.size) { host.style.setProperty('--ms', `${s.size}px`); st.size = s.size; }
      host.style.opacity = s.on > 0.01 ? Math.min(1, s.on * 1.4).toFixed(3) : '0';
      if (s.on <= 0.01) return;
      if (st.last && dt > 0) {
        const vx = (s.x - st.last.x) / dt, vy = (s.y - st.last.y) / dt;
        st.v += (Math.min(1, Math.hypot(vx, vy) / 2200) - st.v) * Math.min(1, dt * 14);
        st.ang = Math.atan2(vy, vx);
      }
      st.last = { x: s.x, y: s.y };
      const stretch = 1 + st.v * 0.32;
      const rot = (s.rot || 0) + st.v * 12 * Math.cos(st.ang || 0);
      const ox = s.x - (TIP_PCT[0] / 100) * size, oy = s.y - (TIP_PCT[1] / 100) * size;
      host.style.transformOrigin = `${TIP_PCT[0]}% ${TIP_PCT[1]}%`;
      host.style.transform = `translate(${ox.toFixed(1)}px, ${oy.toFixed(1)}px) rotate(${rot.toFixed(2)}deg) scale(${(s.on * (s.sx || 1) / Math.sqrt(stretch)).toFixed(3)}, ${(s.on * (s.sy || 1) * stretch).toFixed(3)})`;

      const mood = FACES[s.mood] ? s.mood : 'open';
      if (mood !== st.mood) {
        const f = FACES[mood];
        eyes.forEach((e) => { e.p.setAttribute('d', f.eye.d); e.p.setAttribute('stroke-width', f.eye.w); });
        mouth.setAttribute('d', f.mouth ? f.mouth.d : '');
        if (f.mouth) mouth.setAttribute('stroke-width', f.mouth.w);
        st.mood = mood;
      }
      if (t > st.nextBlink && st.blink <= 0) { st.blink = 0.16; st.nextBlink = t + 3.2 + Math.random() * 4.3; }
      st.blink = Math.max(0, st.blink - dt);
      const lid = st.blink > 0 ? Math.max(0.08, Math.abs((st.blink / 0.16) * 2 - 1)) : 1;
      let gx = 0, gy = 0;
      if (s.look) {
        const cx = ox + ((FACE[0] - BOX[0]) / BOX[2]) * size, cy = oy + ((FACE[1] - BOX[1]) / BOX[2]) * size;
        const dx = s.look.x - cx, dy = s.look.y - cy, d = Math.hypot(dx, dy) || 1, k = d / (d + 60);
        gx = (dx / d) * 3.5 * k; gy = (dy / d) * 3 * k;
      }
      const squash = mood === 'happy' || mood === 'closed' ? 1 : lid;
      eyes.forEach((e) => e.g.setAttribute('transform', `translate(${(FACE[0] + e.side * 8.5 + gx).toFixed(2)} ${(FACE[1] - 3 + gy).toFixed(2)}) scale(1.15 ${(1.15 * squash).toFixed(3)})`));
      mouth.setAttribute('transform', `translate(${(FACE[0] + gx * 0.6).toFixed(2)} ${(FACE[1] + 18 + gy * 0.6).toFixed(2)}) scale(1.15)`);
    },
  };
}
