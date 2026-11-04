import { ScrollTrigger } from 'gsap/ScrollTrigger';
import { createMascot } from './mascot.js';
import { perryAt } from './sentence.js';
import { sound } from './sound.js';

const clamp01 = (v) => (v < 0 ? 0 : v > 1 ? 1 : v);
const smooth = (t) => t * t * (3 - 2 * t);
const NS = 'http://www.w3.org/2000/svg';
const COPY = {
  cloud: {
    far: 'Your chosen AI.',
    note: 'No Perry server in between.',
    detail: 'Requests go straight from your Mac to the provider you pick. You pay that provider, if anything.',
    sr: 'Your Mac talks straight to your chosen AI. No Perry server in between.',
  },
  local: {
    far: 'A model on this Mac.',
    note: 'Nothing leaves your Mac.',
    detail: 'Local models are experimental. Perry offers one only when your Mac meets its hardware floor.',
    sr: 'Your Mac talks to a model on this Mac. Nothing leaves your Mac.',
  },
};

export function createRoute(root, { reduced }) {
  const svg = root.querySelector('[data-route-svg]');
  const path = root.querySelector('[data-route-path]'), head = root.querySelector('[data-route-head]');
  const packetsG = root.querySelector('[data-route-packets]');
  const far = root.querySelector('[data-route-far]'), note = root.querySelector('[data-route-note]');
  const detail = root.querySelector('[data-route-detail]'), sr = root.querySelector('[data-route-sr]');
  const below = root.querySelector('.route__below');
  const perry = createMascot(root.querySelector('[data-perry-route]'));
  const radios = [...root.querySelectorAll('input[name="route"]')];
  path.setAttribute('pathLength', '1');

  const packets = Array.from({ length: 6 }, (_, i) => {
    const c = document.createElementNS(NS, 'circle');
    c.setAttribute('r', i % 2 ? '4' : '5.5');
    c.setAttribute('class', `route__packet${i % 2 ? ' route__packet--back' : ''}`);
    packetsG.append(c);
    return c;
  });

  let mode = 'cloud', shown = 'cloud', swapAt = -10, near = false, drawIn = reduced ? 1 : 0, box = '', len = 1;
  ScrollTrigger.create({ trigger: root, start: 'top bottom', end: 'bottom top', onToggle: (s) => { near = s.isActive; } });
  ScrollTrigger.create({ trigger: root, start: 'top 75%', end: 'top 25%', onUpdate: (s) => { if (!reduced) drawIn = s.progress; }, onRefresh: (s) => { if (!reduced) drawIn = s.progress; } });

  radios.forEach((r) => r.addEventListener('change', () => {
    if (!r.checked || r.value === mode) return;
    mode = r.value; swapAt = performance.now() / 1000;
    far.classList.add('is-swap');
    sound.play('wisp');
  }));

  function geometry(which, W, H, vertical) {
    if (vertical) {
      const x = W / 2;
      return which === 'cloud'
        ? { d: `M${x} 6L${x} ${H - 8}`, head: `M${x - 9} ${H - 20}L${x} ${H - 7}L${x + 9} ${H - 20}` }
        : { d: `M${x} 6L${x} ${H * 0.45}C${x} ${H * 0.72} ${x + W * 0.9} ${H * 0.72} ${x + W * 0.9} ${H * 0.4}L${x + W * 0.9} 22`, head: `M${x + W * 0.9 - 9} 34L${x + W * 0.9} 21L${x + W * 0.9 + 9} 34` };
    }
    const y = H / 2;
    return which === 'cloud'
      ? { d: `M6 ${y}L${W - 8} ${y}`, head: `M${W - 22} ${y - 11}L${W - 7} ${y}L${W - 22} ${y + 11}` }
      : { d: `M6 ${y}L${W * 0.5} ${y}C${W * 0.94} ${y} ${W * 0.94} ${H * 1.05} ${W * 0.5} ${H * 1.05}L30 ${H * 1.05}`, head: `M43 ${H * 1.05 - 11}L28 ${H * 1.05}L43 ${H * 1.05 + 11}` };
  }

  return {
    update(t, dt, pointer) {
      if (!near) { perry.set({ on: 0 }, t, dt); return; }
      const r = svg.getBoundingClientRect();
      const vertical = r.height > r.width;
      const since = t - swapAt;
      if (shown !== mode && (reduced || since > 0.32)) {
        shown = mode;
        const c = COPY[mode];
        far.textContent = c.far; note.textContent = c.note; detail.textContent = c.detail; sr.textContent = c.sr;
        far.classList.remove('is-swap');
        box = '';
      }
      const key = `${r.width.toFixed(0)}x${r.height.toFixed(0)}${shown}${vertical}`;
      if (key !== box) {
        svg.setAttribute('viewBox', `0 0 ${r.width} ${r.height}`);
        const g = geometry(shown, r.width, r.height, vertical);
        path.setAttribute('d', g.d); head.setAttribute('d', g.head);
        len = path.getTotalLength();
        box = key;
      }
      const swapK = reduced ? 1 : since < 0.32 ? 1 - smooth(since / 0.32) : smooth(clamp01((since - 0.32) / 0.5));
      const drawn = smooth(clamp01(drawIn)) * (swapAt > 0 ? swapK : 1);
      path.style.setProperty('--rd', drawn.toFixed(4));
      head.style.opacity = clamp01((drawn - 0.9) / 0.1).toFixed(3);

      let nearest = null, best = Infinity;
      const B = below.getBoundingClientRect();
      const size = Math.max(54, Math.min(80, innerWidth * 0.055));
      const pc = { x: B.width / 2 + (vertical ? -B.width * 0.3 : 0), y: 42 };
      packets.forEach((c, i) => {
        const back = i % 2 === 1 && shown === 'cloud';
        const speed = shown === 'cloud' ? 0.32 : 0.42;
        let u = ((t * speed + i / packets.length) % 1);
        if (back) u = 1 - u;
        const vis = drawn > 0.98 && !reduced ? Math.min(1, Math.sin(u * Math.PI) * 4) : 0;
        const pt = path.getPointAtLength(u * len);
        c.setAttribute('cx', pt.x.toFixed(1)); c.setAttribute('cy', pt.y.toFixed(1));
        c.style.opacity = vis.toFixed(2);
        const sx = r.left + pt.x - B.left, sy = r.top + pt.y - B.top;
        const d = Math.hypot(sx - pc.x, sy - pc.y);
        if (vis > 0.5 && d < best) { best = d; nearest = { x: sx, y: sy }; }
      });
      const look = nearest || (pointer.seen ? { x: pointer.x - B.left, y: pointer.y - B.top } : { x: pc.x, y: -40 });
      perry.set({ ...perryAt(pc.x, pc.y, size), on: smooth(clamp01((drawIn - 0.5) / 0.4)), size, mood: shown === 'local' && since < 1.6 ? 'happy' : 'open', rot: reduced ? 0 : Math.sin(t * 1.3) * 2, look }, t, dt);
    },
  };
}
