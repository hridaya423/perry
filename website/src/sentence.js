import { ScrollTrigger } from 'gsap/ScrollTrigger';
import { createMascot } from './mascot.js';

const clamp01 = (v) => (v < 0 ? 0 : v > 1 ? 1 : v);
const smooth = (t) => t * t * (3 - 2 * t);
const hash = (n) => { const s = Math.sin(n * 127.1) * 43758.5453; return s - Math.floor(s); };
const DEG = Math.PI / 180;
export const dialAngle = (v) => (90 + (-25 - v) * 5.3) * DEG;
export const perryAt = (cx, cy, size) => ({ x: cx - 0.4 * size, y: cy - 0.52 * size });

function wave(canvas, kind, depth) {
  const r = canvas.getBoundingClientRect();
  const dpr = Math.min(2, devicePixelRatio || 1);
  const W = Math.max(1, Math.round(r.width * dpr)), H = Math.max(1, Math.round(r.height * dpr));
  if (canvas.width !== W || canvas.height !== H) { canvas.width = W; canvas.height = H; }
  const g = canvas.getContext('2d');
  g.clearRect(0, 0, W, H);
  g.fillStyle = '#86c5a4';
  const mid = H / 2, bars = Math.max(60, Math.round(W / (3 * dpr)));
  const bw = W / bars;
  for (let i = 0; i < bars; i++) {
    const x = i / bars;
    let a;
    if (kind === 'kick') {
      const hit = (x * 3) % 1;
      a = Math.exp(-hit * 6.5) * (0.85 + 0.15 * hash(i)) * (0.6 + 0.4 * Math.abs(Math.sin(i * 1.7)));
    } else {
      const beat = (x * 4) % 1, note = (x * 8) % 1;
      a = (0.55 + 0.3 * hash(Math.floor(x * 8))) * (note < 0.85 ? 1 : (1 - note) * 6.6) * (0.45 + 0.55 * Math.abs(Math.sin(i * 0.9 + hash(i) * 3)));
      a *= 1 - depth * 0.86 * Math.exp(-beat * 4.2);
    }
    const h = Math.max(dpr, a * mid * 0.9);
    g.fillRect(i * bw + bw * 0.18, mid - h, Math.max(1, bw * 0.64), h * 2);
  }
}

export function createSentence(root, { reduced }) {
  const pin = root.querySelector('.sentence__pin');
  const words = [...root.querySelectorAll('.sw')];
  const frags = [...root.querySelectorAll('.frag')];
  const [fBass, fKick, fComp] = frags;
  const bassC = root.querySelector('[data-wave-frag="bass"]'), kickC = root.querySelector('[data-wave-frag="kick"]');
  const ph = root.querySelector('.frag__ph');
  const val = root.querySelector('[data-frag-val]');
  const dial = root.querySelector('.frag__dial');
  const arc = dial.querySelector('.frag__arc'), needle = dial.querySelector('.frag__needle');
  const ticks = dial.querySelector('.frag__ticks');
  const path = root.querySelector('.sentence__path'), under = root.querySelector('.sentence__under');
  const dots = [...root.querySelectorAll('.sentence__dot')];
  const kicker = root.querySelector('.sentence__kicker'), foot = root.querySelector('.sentence__foot');
  const host = root.querySelector('[data-perry-sentence]');
  const perry = createMascot(host);
  under.setAttribute('pathLength', '1');

  ticks.innerHTML = Array.from({ length: 31 }, (_, i) => {
    const a = dialAngle(-40 + i * (30 / 30) * 1), long = i % 5 === 0;
    const r0 = long ? 78 : 82, r1 = 90;
    return `<path d="M${(r0 * Math.cos(a)).toFixed(1)} ${(-r0 * Math.sin(a)).toFixed(1)}L${(r1 * Math.cos(a)).toFixed(1)} ${(-r1 * Math.sin(a)).toFixed(1)}"/>`;
  }).join('');

  let p = reduced ? 1 : 0, near = false, lastDepth = -1, lastV = 99, sized = 0;
  ScrollTrigger.create({ trigger: root, start: 'top top', end: 'bottom bottom', onUpdate: (s) => { if (!reduced) p = s.progress; }, onRefresh: (s) => { if (!reduced) p = s.progress; } });
  ScrollTrigger.create({ trigger: root, start: 'top bottom', end: 'bottom top', onToggle: (s) => { near = s.isActive; } });
  addEventListener('resize', () => { sized = 0; });

  function setDial(v) {
    const a = dialAngle(v), a0 = dialAngle(0);
    const p0 = [70 * Math.cos(a), -70 * Math.sin(a)], p1 = [70 * Math.cos(a0), -70 * Math.sin(a0)];
    arc.setAttribute('d', v > -0.2 ? 'M0 0' : `M${p0[0].toFixed(1)} ${p0[1].toFixed(1)}A70 70 0 0 1 ${p1[0].toFixed(1)} ${p1[1].toFixed(1)}`);
    needle.setAttribute('x1', (26 * Math.cos(a)).toFixed(1)); needle.setAttribute('y1', (-26 * Math.sin(a)).toFixed(1));
    needle.setAttribute('x2', (54 * Math.cos(a)).toFixed(1)); needle.setAttribute('y2', (-54 * Math.sin(a)).toFixed(1));
    val.textContent = `${v < -0.05 ? '−' : ''}${Math.abs(v).toFixed(1)} dB`;
  }
  setDial(0);

  return {
    update(t, dt, pointer) {
      if (!near) { perry.set({ on: 0 }, t, dt); return; }
      const q = reduced ? 1 : p;
      kicker.style.setProperty('--ko', smooth(clamp01(q / 0.05 + 0.3)).toFixed(3));
      words.forEach((w, i) => w.style.setProperty('--o', smooth(clamp01((q - 0.02 - i * 0.12) / 0.1)).toFixed(3)));
      frags.forEach((f, i) => f.style.setProperty('--r', smooth(clamp01((q - 0.07 - i * 0.12) / 0.14)).toFixed(3)));
      const v = -24 * smooth(clamp01((q - 0.7) / 0.16));
      const depth = -v / 24;
      if (Math.abs(v - lastV) > 0.05) { setDial(v); lastV = v; }
      if (Math.abs(depth - lastDepth) > 0.015 || sized < 2) { wave(bassC, 'bass', depth); lastDepth = depth; }
      if (sized < 2) { wave(kickC, 'kick', 0); sized++; }

      const R = pin.getBoundingClientRect(), rb = fBass.getBoundingClientRect(), rk = fKick.getBoundingClientRect(), rd = dial.getBoundingClientRect();
      const beat = reduced ? 1.4 : (t * 124) / 60;
      ph.style.setProperty('--ph', `${(((beat / 4) % 1) * rb.width).toFixed(1)}px`);
      const s = rd.width / 260, a = dialAngle(v);
      const P = [
        { x: rb.left - R.left + rb.width * 0.56, y: rb.top - R.top + rb.height * 0.63 },
        { x: rk.left - R.left + rk.width * 0.035, y: rk.top - R.top + rk.height * 0.63 },
        { x: rd.left - R.left + (130 + 62 * Math.cos(a)) * s, y: rd.top - R.top + (130 - 62 * Math.sin(a)) * s },
      ];
      const narrow = innerWidth <= 900;
      const d = narrow
        ? `M${P[0].x} ${P[0].y}C${P[0].x} ${P[0].y + 60} ${P[1].x + 40} ${P[1].y - 60} ${P[1].x} ${P[1].y}C${P[1].x - 30} ${P[1].y + 70} ${P[2].x - 60} ${P[2].y - 70} ${P[2].x} ${P[2].y}`
        : `M${P[0].x} ${P[0].y}C${P[0].x} ${P[0].y + (P[1].y - P[0].y) * 0.7} ${P[1].x - 70} ${P[0].y + (P[1].y - P[0].y) * 0.45} ${P[1].x - 70} ${(P[0].y + P[1].y) / 2 + 30}S${P[1].x - 10} ${P[1].y} ${P[1].x} ${P[1].y}C${P[1].x} ${P[1].y + (P[2].y - P[1].y) * 0.6} ${P[2].x - (P[2].x - P[1].x) * 0.35} ${P[2].y - 70} ${P[2].x} ${P[2].y}`;
      path.setAttribute('d', d); under.setAttribute('d', d);
      const drawn = smooth(clamp01((q - 0.46) / 0.26));
      path.style.setProperty('--d', drawn.toFixed(4)); under.style.setProperty('--dash', drawn.toFixed(4));
      under.style.strokeDasharray = `${drawn.toFixed(4)} 2`;
      dots.forEach((c, i) => {
        c.setAttribute('cx', P[i].x.toFixed(1)); c.setAttribute('cy', P[i].y.toFixed(1));
        c.classList.toggle('on', drawn > [0.01, 0.5, 0.98][i]);
      });
      foot.style.setProperty('--fo', smooth(clamp01((q - 0.84) / 0.08)).toFixed(3));

      const on = smooth(clamp01((q - 0.84) / 0.06));
      const size = Math.max(46, Math.min(78, innerWidth * 0.05));
      const happy = q > 0.9 && (t % 5) < 1.4;
      const spot = perryAt(P[2].x + size * 0.85, P[2].y - size * 0.55, size);
      perry.set({ ...spot, on, size, mood: happy ? 'happy' : 'open', rot: reduced ? 0 : Math.sin(t * 1.7) * 4, look: { x: pointer.seen ? pointer.x - R.left : P[2].x, y: pointer.seen ? pointer.y - R.top : P[2].y } }, t, dt);
    },
  };
}
