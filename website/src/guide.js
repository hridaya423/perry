import { drawMark } from './ink/actors.js';
import { createMascot } from './mascot.js';
import { sound } from './sound.js';

const ASKS = {
  cost: { target: '[data-ask-target="cost"]', open: true },
  keep: { target: '[data-ask-target="keep"]', box: true },
  get: { target: '.finale .btn--big', end: true, box: true, bare: true },
};

const clamp01 = (v) => (v < 0 ? 0 : v > 1 ? 1 : v);
const smooth = (t) => t * t * (3 - 2 * t);
const inOut = (t) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2);

export function mark(r, box) {
  if (box) {
    const pad = Math.max(10, Math.min(18, r.height * 0.14));
    const m = { kind: 'box', x: r.left - pad, y: r.top - pad, w: r.width + pad * 2, h: r.height + pad * 2 };
    return { ...m, tip: { x: m.x + m.w + 4, y: m.y + m.h + 2 }, cx: m.x + m.w / 2, cy: m.y + m.h / 2 };
  }
  const hw = r.width / 2, hh = r.height / 2;
  const rx = Math.min(innerWidth * 0.47, hw + Math.max(20, r.height * 0.7));
  const ry = Math.min(hh * 2.4, hh / Math.sqrt(1 - (hw / rx) ** 2) * 1.06 + 4);
  const x = Math.max(rx + 10, Math.min(innerWidth - rx - 10, r.left + hw)), y = r.top + hh;
  return { kind: 'circle', x, y, rx, ry, tip: { x: x + rx * 0.72, y: y + ry * 0.74 }, side: { x: x + rx + 6, y }, cx: x, cy: y };
}

export const notchH = () => (innerWidth <= 900 ? 30 : 34);

export function notchPanel(notch, np, w, notchH) {
  const body = notch.querySelector('.notch__body');
  notch.classList.toggle('is-open', !!np);
  if (!np) { ['--nw', '--nh', '--nr'].forEach((p) => body.style.removeProperty(p)); return; }
  const nw = Math.min(w, innerWidth - 20);
  np.style.width = `${nw - 78}px`;
  body.style.setProperty('--nw', `${nw}px`);
  body.style.setProperty('--nh', `${notchH() + 14 + np.offsetHeight + 18}px`);
  body.style.setProperty('--nr', '26px');
}

export function createGuide(notch, { reduced, scrollTo, notchH }) {
  const button = notch.querySelector('.notch__ask');
  const menu = notch.querySelector('[data-np="ask"]');
  const said = notch.querySelector('[data-np="gq"]'), saidText = said.querySelector('.np__text');
  const reply = notch.querySelector('[data-np="ga"]'), replyText = reply.querySelector('.np__text');
  const again = reply.querySelector('[data-ask-again]');
  const hi = notch.querySelector('[data-np="hi"]'), talkNp = notch.querySelector('[data-np="talk"]');
  const chips = [...menu.querySelectorAll('[data-ask]')];
  const perry = createMascot(document.querySelector('[data-perry-guide]'));

  const range = document.createRange();
  let state = 'idle', at = 0, ask = null, answer = '', el = null, shown = null, shownW = 0, typed = '';
  let flyFrom = null, landAt = 0, leaveAt = 0, leaveFrom = null, pos = null;
  let buddy = null, hop = null;

  function panel(np, w) {
    shown = np; shownW = w;
    for (const n of [menu, said, reply, hi, talkNp]) { n.classList.toggle('on', n === np); n.inert = n !== np; }
    notchPanel(notch, np, w, notchH);
  }

  function open() {
    const t = performance.now() / 1000;
    if (state === 'wake') goHome(t);
    else if (state !== 'idle') leave(t);
    state = 'menu';
    sound.play('plop');
    notch.classList.add('is-guide');
    button.setAttribute('aria-expanded', 'true');
    panel(menu, 470);
    chips[0].focus({ preventScroll: true });
  }

  function close() {
    state = 'idle';
    notch.classList.remove('is-guide');
    button.setAttribute('aria-expanded', 'false');
    panel(null);
    if (el) el.classList.remove('is-asked');
    el = null; ask = null;
  }

  function goHome(t) {
    if (pos && pos.on > 0.05) hop = { at: t, from: { ...pos } };
    buddy = null;
  }

  function wake(t, pointer) {
    if (state === 'wake') { leave(t); return; }
    if (state !== 'idle') leave(t);
    if (state === 'leaving') return;
    state = 'wake'; at = t; hop = null;
    buddy = { x: innerWidth / 2, y: notchH() + 4, from: { x: innerWidth / 2, y: notchH() + 4 }, moved: t, px: pointer.x, py: pointer.y };
    notch.classList.add('is-guide');
    panel(hi, 400);
    sound.play('wisp');
  }

  function talk(on) {
    if (on) {
      if (state === 'wake') goHome(performance.now() / 1000);
      else if (state !== 'idle' && state !== 'menu') return;
      state = 'talk';
      notch.classList.add('is-guide');
      panel(talkNp, 400);
      sound.play('hail');
    } else if (state === 'talk') open();
  }

  function leave(t) {
    if (state === 'wake') { goHome(t); close(); return; }
    if (state === 'talk') { close(); return; }
    if (state === 'flying' || state === 'pointing' || state === 'answer') { state = 'leaving'; leaveAt = t; leaveFrom = pos; }
    else close();
  }

  function choose(chip) {
    const t = performance.now() / 1000;
    ask = ASKS[chip.dataset.ask];
    el = document.querySelector(ask.target);
    state = 'asking'; at = t; typed = chip.textContent.trim(); answer = chip.dataset.answer;
    saidText.textContent = '';
    panel(said, Math.max(300, Math.min(460, 140 + typed.length * 8.5)));
    button.focus({ preventScroll: true });
  }

  function go(t) {
    state = 'answer'; at = t; perch = null;
    replyText.textContent = answer;
    panel(reply, 470);
    if (ask.open) el.closest('details')?.setAttribute('open', '');
    const r = el.getBoundingClientRect();
    const y = ask.end ? document.documentElement.scrollHeight : r.top + scrollY + r.height / 2 - innerHeight * 0.48;
    scrollTo(Math.max(0, y), reduced ? 0 : 1.5);
    sound.play('wisp', { delay: 0.15 });
    flyFrom = { x: innerWidth / 2, y: notchH() + 4 };
  }

  button.addEventListener('click', () => (state === 'menu' || state === 'pointing' ? leave(performance.now() / 1000) : open()));
  chips.forEach((c) => c.addEventListener('click', () => choose(c)));
  again.addEventListener('click', () => { if (el) el.classList.remove('is-asked'); open(); });
  addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && state !== 'idle') { const was = state; leave(performance.now() / 1000); if (was !== 'wake') button.focus({ preventScroll: true }); }
    const typing = /^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement?.tagName);
    if (e.key === '/' && !typing && state === 'idle') { e.preventDefault(); open(); }
  });
  document.addEventListener('pointerdown', (e) => { if (state === 'menu' && !notch.contains(e.target)) close(); });
  const nudge = () => { if (state === 'pointing' && performance.now() / 1000 - landAt > 1.2) leave(performance.now() / 1000); };
  addEventListener('wheel', nudge, { passive: true });
  addEventListener('touchmove', nudge, { passive: true });
  document.querySelectorAll('[data-ask-open]').forEach((b) => b.addEventListener('click', open));

  const onText = (x, y) => {
    const hit = document.elementFromPoint(x, y);
    if (!hit || hit.closest('.notch, .finale__pin')) return false;
    if (hit.closest('.btn')) return true;
    const at = document.caretRangeFromPoint?.(x, y);
    if (!at || at.startContainer.nodeType !== 3) return false;
    const n = at.startContainer, o = Math.min(at.startOffset, n.length - 1);
    if (o < 0) return false;
    const g = document.createRange();
    g.setStart(n, o); g.setEnd(n, o + 1);
    const b = g.getBoundingClientRect();
    return x >= b.left - 6 && x <= b.right + 6 && y >= b.top - 4 && y <= b.bottom + 4;
  };
  const covers = (p, s) => [[0.3, 0.35], [0.75, 0.45], [0.45, 0.8], [0.85, 0.85]].some(([u, v]) => onText(p.x + s * u, p.y + s * v));
  let perch = null;
  function home(t, dt) {
    const u = reduced ? 1 : clamp01((t - hop.at) / 0.75);
    const e = inOut(u);
    const to = { x: innerWidth / 2, y: notchH() - 4 };
    const x = hop.from.x + (to.x - hop.from.x) * e, y = hop.from.y + (to.y - hop.from.y) * e - Math.sin(Math.PI * e) * 70;
    const on = 1 - smooth(clamp01((u - 0.7) / 0.3));
    pos = { x, y, on };
    perry.set({ x, y, on, size: hop.from.size || 48, mood: 'open', sx: u > 0.75 ? 0.8 : 1, sy: u > 0.75 ? 1.25 : 1, look: to }, t, dt);
    if (u >= 1) {
      hop = null; pos = null;
      sound.play('hush');
      notch.classList.remove('gulp'); void notch.offsetWidth; notch.classList.add('gulp');
    }
  }

  function follow(t, dt, pointer) {
    const size = Math.max(44, Math.min(56, innerWidth * 0.038));
    if (Math.hypot(pointer.x - buddy.px, pointer.y - buddy.py) > 2) { buddy.moved = t; buddy.px = pointer.x; buddy.py = pointer.y; }
    const to = { x: Math.min(innerWidth - size * 0.8, pointer.x + 16), y: Math.min(innerHeight - size * 0.9, pointer.y + 20) };
    const u = reduced ? 1 : clamp01((t - at) / 0.8);
    let sx = 1, sy = 1, mood = 'open', rot = 0;
    if (u < 1) {
      const e = inOut(u), f = buddy.from;
      const cx = f.x + (to.x - f.x) * 0.2, cy = f.y + Math.min(260, Math.hypot(to.x - f.x, to.y - f.y) * 0.6);
      buddy.x = (1 - e) * (1 - e) * f.x + 2 * (1 - e) * e * cx + e * e * to.x;
      buddy.y = (1 - e) * (1 - e) * f.y + 2 * (1 - e) * e * cy + e * e * to.y;
      if (u < 0.15) { sx = 0.82; sy = 1.22; }
    } else {
      if (!buddy.landed) { buddy.landed = true; sound.play('landed'); }
      const k = 1 - Math.exp(-dt * (reduced ? 60 : 7));
      buddy.x += (to.x - buddy.x) * k; buddy.y += (to.y - buddy.y) * k;
      const since = t - at - 0.8;
      if (since < 0.25) { sy = 1 - 0.2 * Math.sin((since / 0.25) * Math.PI); sx = 2 - sy; }
      mood = since > 0.2 && since < 1.5 ? 'happy' : 'open';
      rot = reduced ? 0 : Math.sin(t * 2.3) * 2.5;
    }
    const on = smooth(clamp01(u / 0.12));
    pos = { x: buddy.x, y: buddy.y, on, size };
    perry.set({ x: buddy.x, y: buddy.y, on, size, mood, rot, sx, sy, look: { x: pointer.x + (pointer.x - buddy.x) * 2, y: pointer.y + (pointer.y - buddy.y) * 2 } }, t, dt);
    if (t - buddy.moved > 6 && u >= 1) leave(t);
  }

  return {
    get active() { return state !== 'idle'; },
    wake: (pointer) => wake(performance.now() / 1000, pointer),
    talk,
    get perry() { return pos && pos.on > 0.05 ? pos : null; },
    open,
    update(t, dt, ink, pointer) {
      if (state === 'wake') { follow(t, dt, pointer); return; }
      if (hop && (state === 'idle' || state === 'menu' || state === 'asking' || state === 'talk')) { home(t, dt); return; }
      if (shown && !(shown.classList.contains('on') && notch.classList.contains('is-open'))) panel(shown, shownW);
      if (state === 'asking') {
        const n = reduced ? typed.length : Math.round(typed.length * clamp01((t - at) / 0.75));
        if (saidText.textContent.length !== n) saidText.textContent = typed.slice(0, Math.max(1, n));
        if (t - at > (reduced ? 0.3 : 1.15)) go(t);
      }
      if (!el || state === 'idle' || state === 'menu' || state === 'asking') { perry.set({ on: 0 }, t, dt); pos = null; return; }

      range.selectNodeContents(el);
      const c = mark(ask.box ? el.getBoundingClientRect() : range.getBoundingClientRect(), ask.box);
      const size = Math.max(42, Math.min(56, innerWidth * 0.04));
      const side = c.side && { x: c.side.x, y: c.side.y - size * 0.5 };
      const spot = (perch || (side && covers(c.tip, size) && !covers(side, size) ? 'side' : 'tip')) === 'side' ? side : c.tip;
      const tip = { x: Math.min(innerWidth - size * 0.9, spot.x), y: Math.min(innerHeight - size, spot.y) };
      let x, y, on = 1, mood = 'open', rot = 0, sx = 1, sy = 1, drawn = 0;

      if (state === 'answer' || state === 'flying') {
        state = 'flying';
        const u = reduced ? 1 : clamp01((t - at - 0.15) / 1.25);
        const e = inOut(u);
        const cx = flyFrom.x, cy = flyFrom.y + Math.min(320, Math.hypot(tip.x - flyFrom.x, tip.y - flyFrom.y) * 0.7);
        x = (1 - e) * (1 - e) * flyFrom.x + 2 * (1 - e) * e * cx + e * e * tip.x;
        y = (1 - e) * (1 - e) * flyFrom.y + 2 * (1 - e) * e * cy + e * e * tip.y;
        on = smooth(clamp01(u / 0.12));
        if (u < 0.15) { sx = 0.82; sy = 1.22; }
        if (u >= 1) { state = 'pointing'; landAt = t; sound.play('landed'); perch = spot === side ? 'side' : 'tip'; el.classList.add('is-asked'); }
      } else if (state === 'pointing') {
        x = tip.x; y = tip.y;
        const since = t - landAt;
        drawn = reduced ? 1 : smooth(clamp01((since - 0.05) / 0.7));
        mood = since > 0.55 && since < 1.6 ? 'happy' : 'open';
        rot = reduced ? 0 : Math.sin(since * 2.1) * 3 - (since < 0.4 ? (0.4 - since) * 30 : 0);
        sy = since < 0.25 ? 1 - 0.18 * Math.sin((since / 0.25) * Math.PI) : 1;
        sx = 2 - sy;
        if (since > 9) leave(t);
      } else if (state === 'leaving') {
        const u = reduced ? 1 : clamp01((t - leaveAt) / 0.9);
        const e = inOut(u);
        const home = { x: innerWidth / 2, y: notchH() - 4 };
        const from = leaveFrom || tip;
        x = from.x + (home.x - from.x) * e; y = from.y + (home.y - from.y) * e - Math.sin(Math.PI * e) * 60;
        on = 1 - smooth(clamp01((u - 0.7) / 0.3));
        if (u > 0.75) { sx = 0.8; sy = 1.25; }
        drawn = 1 - smooth(clamp01(u / 0.45));
        if (u >= 1) {
          close();
          sound.play('hush');
          notch.classList.remove('gulp'); void notch.offsetWidth; notch.classList.add('gulp');
        }
      }

      pos = { x, y, on };
      perry.set({ x, y, on, size, mood, rot, sx, sy, look: { x: c.cx, y: c.cy } }, t, dt);
      if (drawn > 0 && !ask.bare) {
        const R = Math.max(1.6, Math.min(2.3, innerWidth * 0.0016));
        const { tip: _, cx: __, cy: ___, ...geo } = c;
        drawMark(ink, { ...geo, seed: 0.45, progress: drawn }, R);
      }
    },
  };
}
