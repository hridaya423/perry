import { ScrollTrigger } from 'gsap/ScrollTrigger';
import { createMascot } from './mascot.js';
import { perryAt } from './sentence.js';
import { sound } from './sound.js';

const clamp01 = (v) => (v < 0 ? 0 : v > 1 ? 1 : v);
const smooth = (t) => t * t * (3 - 2 * t);
const hash = (n) => { const s = Math.sin(n * 127.1) * 43758.5453; return s - Math.floor(s); };
const amp = (x) => {
  const swell = 0.25 + 0.75 * Math.pow(Math.sin(Math.min(1, x * 1.08) * Math.PI * 0.92 + 0.12), 0.7);
  const beat = Math.exp(-((x * 22) % 1) * 3.4);
  return Math.max(0.03, swell * (0.35 + 0.65 * beat) * (0.55 + 0.45 * hash(Math.floor(x * 900))));
};
const MSG = {
  stopped: 'Stopped. Mix.wav is exactly as it was.',
  crossed: 'Replaced. In the app, this is when Mix.wav would change. On this page, nothing on your Mac did.',
};

export function createGate(root, { reduced }) {
  const pin = root.querySelector('.gate__pin');
  const canvas = root.querySelector('[data-gate-wave]');
  const dialog = root.querySelector('[data-gate-dialog]');
  const after = root.querySelector('[data-gate-after]'), afterMsg = root.querySelector('[data-gate-msg]');
  const yet = root.querySelector('[data-gate-yet]'), fileTag = root.querySelector('[data-gate-file]');
  const lineEl = root.querySelector('.gate__line');
  const perry = createMascot(root.querySelector('[data-perry-gate]'));
  const btn = (k) => root.querySelector(`[data-gate="${k}"]`);

  let p = reduced ? 1 : 0, near = false, state = 'ask', at = 0, last = '';
  dialog.inert = true;
  const narrow = () => innerWidth <= 900;
  ScrollTrigger.create({ trigger: root, start: () => (narrow() ? 'top 75%' : 'top top'), end: () => (narrow() ? 'top 5%' : 'bottom bottom'), onUpdate: (s) => { if (!reduced) p = s.progress; }, onRefresh: (s) => { if (!reduced) p = s.progress; } });
  ScrollTrigger.create({ trigger: root, start: 'top bottom', end: 'bottom top', onToggle: (s) => { near = s.isActive; } });

  function set(next) {
    state = next; at = performance.now() / 1000;
    pin.classList.toggle('is-crossed', state === 'crossed');
    pin.classList.toggle('is-stopped', state === 'stopped');
    after.hidden = state === 'ask';
    afterMsg.textContent = MSG[state] || '';
    yet.textContent = state === 'crossed' ? 'Mix.wav, replaced.' : state === 'stopped' ? 'Nothing changed.' : 'Nothing changes yet.';
    fileTag.textContent = state === 'crossed' ? 'Replaced (demo)' : 'New bounce, 0:14';
    if (state !== 'ask') btn('again').focus({ preventScroll: true });
  }
  btn('stop').addEventListener('click', () => { set('stopped'); sound.play('hush'); });
  btn('go').addEventListener('click', () => { set('crossed'); sound.play('landed'); });
  btn('again').addEventListener('click', () => { set('ask'); btn('go').focus({ preventScroll: true }); });
  dialog.addEventListener('keydown', (e) => { if (e.key === 'Escape') { e.stopPropagation(); set('stopped'); } });

  function draw(front, cross, fade) {
    const r = canvas.getBoundingClientRect();
    const dpr = Math.min(2, devicePixelRatio || 1);
    const W = Math.round(r.width * dpr), H = Math.round(r.height * dpr);
    if (canvas.width !== W || canvas.height !== H) { canvas.width = W; canvas.height = H; }
    const g = canvas.getContext('2d');
    g.clearRect(0, 0, W, H);
    const lx = (lineEl.getBoundingClientRect().left - r.left) * dpr;
    const mid = H * 0.5, step = 2.6 * dpr;
    const fx = lx * front;
    const top = [], bot = [];
    const total = cross > 0 ? lx + (W - lx) * cross : fx;
    for (let x = 0; x <= total; x += step) {
      const u = x / Math.max(1, lx), h = amp(u * 0.92) * mid * 0.92;
      top.push([x, mid - h]); bot.push([x, mid + h * (0.86 + 0.14 * hash(x))]);
    }
    if (!top.length) return;
    const fill = (from, to, color, alpha) => {
      g.save();
      g.beginPath(); g.rect(from, 0, to - from, H); g.clip();
      g.globalAlpha = alpha; g.fillStyle = color;
      g.beginPath(); g.moveTo(0, mid);
      for (const [x, y] of top) g.lineTo(x, y);
      for (let i = bot.length - 1; i >= 0; i--) g.lineTo(bot[i][0], bot[i][1]);
      g.closePath(); g.fill();
      g.restore();
    };
    const ink = getComputedStyle(document.documentElement).getPropertyValue('--ink').trim() || '#1c1e1b';
    fill(0, Math.min(fx, lx - 3 * dpr), ink, 1);
    if (fade > 0) fill(lx * 0.78, lx, '#f5f3ee', fade * 0.75);
    if (cross > 0) fill(lx + 3 * dpr, total, '#7fb9a0', 1);
  }

  return {
    get needs() { return near && state === 'ask' && dialog.classList.contains('on'); },
    update(t, dt) {
      if (!near) { perry.set({ on: 0 }, t, dt); return; }
      const q = reduced ? 1 : p;
      const front = smooth(clamp01(q / 0.55));
      const since = t - at;
      const cross = state === 'crossed' ? (reduced ? 1 : smooth(clamp01(since / 1.6))) : 0;
      const fade = state === 'stopped' ? (reduced ? 1 : smooth(clamp01(since / 0.6))) : 0;
      const sig = `${front.toFixed(3)}|${cross.toFixed(3)}|${fade.toFixed(2)}|${innerWidth}x${innerHeight}`;
      if (sig !== last) { draw(front, cross, fade); last = sig; }
      lineEl.style.setProperty('--ly', (reduced ? 1 : smooth(clamp01(q / 0.25))).toFixed(3));
      const ready = front > 0.995 && state === 'ask';
      if (dialog.classList.contains('on') !== ready) {
        dialog.classList.toggle('on', ready);
        dialog.inert = !ready;
        if (ready) sound.play('perk');
      }

      const R = pin.getBoundingClientRect(), L = lineEl.getBoundingClientRect(), C = canvas.getBoundingClientRect(), D = dialog.getBoundingClientRect();
      const size = Math.max(46, Math.min(74, innerWidth * 0.048));
      const cx = L.left - R.left - size * (narrow() ? 0.7 : 0.75), cy = C.bottom - R.top - size * (narrow() ? 0.1 : 0.35);
      const mood = state === 'crossed' ? (since < 1.8 ? 'happy' : 'open') : state === 'stopped' ? 'open' : ready ? 'wide' : 'focus';
      perry.set({ ...perryAt(cx, cy, size), on: smooth(clamp01((front - 0.6) / 0.3)), size, mood, rot: reduced ? 0 : Math.sin(t * 1.5) * 2,
        look: ready ? { x: D.left - R.left + 20, y: D.top - R.top + D.height / 2 } : { x: L.left - R.left, y: cy - size } }, t, dt);
    },
  };
}
