import { ScrollTrigger } from 'gsap/ScrollTrigger';
import { createMascot } from './mascot.js';
import { notchPanel } from './guide.js';
import { perryAt } from './sentence.js';
import { sound } from './sound.js';

const FILES = [
  { name: 'invoice-482.pdf', kind: 'pdf', title: 'Invoice', to: 'Receipts' },
  { name: 'invoice-483.pdf', kind: 'pdf', title: 'Invoice', to: 'Receipts' },
  { name: 'booking_confirmation.pdf', kind: 'pdf', title: 'Booking confirmation', to: 'Trip' },
  { name: 'train-ticket.pdf', kind: 'pdf', title: 'Train ticket', to: 'Trip' },
  { name: 'IMG_2784.jpg', kind: 'photo', to: 'Trip' },
  { name: 'IMG_2787.jpg', kind: 'photo', alt: true, to: 'Trip' },
  { name: 'Screenshot 2026-10-28.png', kind: 'shot', to: 'Screenshots' },
  { name: 'Screenshot 2026-10-29.png', kind: 'shot', alt: true, to: 'Screenshots' },
  { name: 'scan-copy.pdf', kind: 'scan', to: 'Needs a look' },
  { name: 'holiday-photos.zip', kind: 'zip', to: 'Trip' },
  { name: 'receipt-cafe.pdf', kind: 'pdf', title: 'Receipt', to: 'Receipts' },
  { name: 'hotel-booking.pdf', kind: 'pdf', title: 'Booking', to: 'Trip' },
];
const FOLDERS = ['Receipts', 'Trip', 'Screenshots', 'Needs a look'];
const LOOK = 'Needs a look';
const FOLDER_SVG = '<svg class="fold__icon" viewBox="0 0 26 21"><path d="M1 3.2C1 2 2 1 3.2 1h6.3l2.2 2.4h11.1C24 3.4 25 4.4 25 5.6V18c0 1.2-1 2-2.2 2H3.2C2 20 1 19.2 1 18z" fill="#5aa9ef" stroke="none"/><path d="M1 6.8h24V18c0 1.2-1 2-2.2 2H3.2C2 20 1 19.2 1 18z" fill="#7cc0f6" stroke="none"/></svg>';
const TRI = '<svg class="fold__tri" viewBox="0 0 12 12"><path d="m3 4.5 3 3 3-3" stroke-width="1.8"/></svg>';

const clamp01 = (v) => (v < 0 ? 0 : v > 1 ? 1 : v);
const icon = (f) => ({
  pdf: `<span class="fdoc"><b>${f.title}</b><i></i><i></i><i></i><em>PDF</em></span>`,
  scan: '<span class="fdoc fdoc--scan"><i></i><i></i><i></i><i></i><i></i><em>PDF</em></span>',
  zip: '<span class="fdoc fdoc--zip"><strong>ZIP</strong></span>',
  photo: `<span class="fphoto${f.alt ? ' fphoto--b' : ''}"></span>`,
  shot: `<span class="fshot${f.alt ? ' fshot--b' : ''}"><i></i><i></i><i></i></span>`,
}[f.kind]);
const mini = (f) => `<span class="fmini${f.kind === 'pdf' ? '' : ` fmini--${f.kind}`}"></span>`;

export function createSort(root, { reduced, notch, notchH }) {
  const $ = (s) => root.querySelector(s);
  const finder = $('[data-finder]'), grid = $('[data-grid]'), tree = $('[data-tree]'), head = $('[data-plan-head]');
  const inkSvg = $('[data-sort-ink]'), stripText = $('[data-strip-text]'), stripActs = $('[data-strip-acts]');
  const np = notch.querySelector('[data-np="bench"]');
  const npStep = np.querySelector('[data-bn-step]'), npText = np.querySelector('[data-bn-text]'), npActions = np.querySelector('[data-bn-actions]');
  const perry = createMascot(document.querySelector('[data-perry]'));

  const files = FILES.map((f, i) => {
    const li = document.createElement('li');
    li.className = 'ftile';
    li.innerHTML = `<span class="ftile__icon">${icon(f)}</span><span class="ftile__name">${f.name}</span>`;
    grid.append(li);
    return { ...f, i, tile: li, keep: true, moved: false };
  });
  const folders = FOLDERS.map((name) => {
    const el = document.createElement('div');
    el.className = `fold open${name === LOOK ? ' fold--look' : ''}`;
    el.innerHTML = `<button class="fold__head" type="button" aria-expanded="true">${TRI}${FOLDER_SVG}<span>${name}</span><span class="fold__count"></span></button><div class="fold__rows"></div>`;
    const btn = el.querySelector('.fold__head');
    btn.addEventListener('click', () => { const o = !el.classList.contains('open'); el.classList.toggle('open', o); btn.setAttribute('aria-expanded', String(o)); });
    tree.append(el);
    return { name, el, rows: el.querySelector('.fold__rows'), count: el.querySelector('.fold__count') };
  });
  files.forEach((f) => {
    const row = document.createElement('label');
    row.className = 'fold__row';
    row.innerHTML = `<input type="checkbox" checked aria-label="Move ${f.name}">${mini(f)}<span>${f.name}</span>`;
    f.row = row; f.check = row.querySelector('input');
    f.check.addEventListener('change', () => { f.keep = f.check.checked; row.classList.toggle('is-off', !f.keep); said = ''; counts(); strip(); });
    folders.find((d) => d.name === f.to).rows.append(row);
  });

  let state = 'idle', at = 0, cursor = -1, on = false, near = false, owns = false, said = '', shownW = 0, pos = null, hop = -10;
  let flights = [], arc = null;
  const movable = () => files.filter((f) => f.to !== LOOK && f.keep);
  const moved = () => files.filter((f) => f.moved);

  ScrollTrigger.create({ trigger: finder, start: 'top 70%', end: 'bottom 25%', onToggle: (s) => { on = s.isActive; if (on && state === 'idle') start(); } });
  ScrollTrigger.create({ trigger: root, start: 'top bottom', end: 'bottom top', onToggle: (s) => { near = s.isActive; } });

  function counts() {
    folders.forEach((d) => {
      const n = files.filter((f) => f.to === d.name && f.keep && f.row.classList.contains('on')).length;
      d.count.textContent = n ? String(n) : '';
      d.el.classList.toggle('on', n > 0);
    });
  }
  function setState(s) { state = s; at = performance.now() / 1000; finder.classList.toggle('is-review', s === 'review'); said = ''; strip(); }

  function reset() {
    flights.forEach((a) => a.cancel()); flights = [];
    document.querySelectorAll('.flier').forEach((n) => n.remove());
    files.forEach((f) => {
      f.moved = false; f.keep = true; f.check.checked = true;
      f.tile.className = 'ftile';
      f.row.className = 'fold__row';
    });
    inkSvg.replaceChildren(); arc = null;
    folders.forEach((d) => { d.el.classList.add('open'); d.el.querySelector('.fold__head').setAttribute('aria-expanded', 'true'); });
    folders[2].el.classList.remove('open');
    counts();
    head.textContent = 'Perry hasn’t looked yet.';
    cursor = -1;
  }
  function start() { reset(); setState('reading'); sound.play('wisp'); }

  function draw(f, keep) {
    const F = finder.getBoundingClientRect(), a = f.tile.querySelector('.ftile__icon').getBoundingClientRect();
    const target = f.row.classList.contains('on') && f.row.offsetParent ? f.row : f.row.closest('.fold').querySelector('.fold__head');
    const b = target.getBoundingClientRect();
    const x0 = a.right - F.left - 6, y0 = a.top - F.top + 10, x1 = b.left - F.left + 2, y1 = b.top - F.top + b.height / 2;
    const lift = Math.min(140, Math.abs(x1 - x0) * 0.35 + 30);
    const d = `M${x0} ${y0}C${x0 + (x1 - x0) * 0.3} ${Math.min(y0, y1) - lift} ${x1 - (x1 - x0) * 0.3} ${Math.min(y0, y1) - lift * 0.6} ${x1} ${y1}`;
    const p = document.createElementNS('http://www.w3.org/2000/svg', 'path');
    p.setAttribute('d', d); p.setAttribute('pathLength', '1');
    inkSvg.append(p);
    const h = document.createElementNS('http://www.w3.org/2000/svg', 'path');
    h.setAttribute('class', 'head'); h.setAttribute('d', `M${x1 - 12} ${y1 - 7}L${x1} ${y1}L${x1 - 12} ${y1 + 7}`); h.style.opacity = '0';
    inkSvg.append(h);
    return { p, h, born: performance.now() / 1000, keep };
  }

  function fly(f, back) {
    const src = f.tile.querySelector('.ftile__icon'), dst = f.row.querySelector('.fmini');
    const a = (back ? dst : src).getBoundingClientRect(), b = (back ? src : dst).getBoundingClientRect();
    const ghost = src.cloneNode(true);
    ghost.className = 'flier';
    const w = src.offsetWidth;
    ghost.style.width = `${w}px`; ghost.style.height = `${src.offsetHeight}px`;
    document.body.append(ghost);
    const s0 = a.width / w, sb = b.width / w;
    const mid = `translate(${(a.left + b.left) / 2}px, ${(a.top + b.top) / 2 - 90}px) scale(${(s0 + sb) / 2 + 0.08})`;
    const anim = ghost.animate([
      { transform: `translate(${a.left}px, ${a.top}px) scale(${s0})` },
      { transform: mid, offset: 0.5 },
      { transform: `translate(${b.left}px, ${b.top}px) scale(${sb})` },
    ], { duration: reduced ? 1 : 720, easing: 'cubic-bezier(0.45, 0, 0.2, 1)', fill: 'forwards' });
    flights.push(anim);
    return anim.finished.then(() => ghost.remove(), () => ghost.remove());
  }

  async function move() {
    setState('moving');
    sound.play('wisp');
    const list = movable();
    for (let k = 0; k < list.length; k++) {
      if (state !== 'moving') return;
      const f = list[k];
      f.tile.classList.add('is-gone');
      fly(f, false).then(() => { f.row.classList.add('is-moved', 'is-flash'); setTimeout(() => f.row.classList.remove('is-flash'), 500); sound.play('plop', { volume: 0.35, pitch: 1 + k * 0.04 }); });
      f.moved = true;
      await new Promise((r) => setTimeout(r, reduced ? 0 : 140));
    }
    await new Promise((r) => setTimeout(r, reduced ? 0 : 760));
    if (state !== 'moving') return;
    files.forEach((f) => { if (f.moved) f.tile.classList.add('is-hidden'); });
    files.find((f) => f.to === LOOK).tile.classList.add('is-left');
    folders[2].el.classList.add('open');
    hop = performance.now() / 1000;
    sound.play('landed');
    setState('done');
  }

  async function undo() {
    const list = moved();
    setState('undoing');
    list.forEach((f) => f.tile.classList.remove('is-hidden'));
    files.forEach((f) => f.tile.classList.remove('is-left'));
    await new Promise((r) => requestAnimationFrame(r));
    await Promise.all(list.map((f, k) => new Promise((r) => setTimeout(r, reduced ? 0 : k * 70)).then(() => {
      f.row.classList.remove('is-moved');
      return fly(f, true).then(() => { f.tile.classList.remove('is-gone'); f.moved = false; });
    })));
    setState('planned');
  }

  const ACT = {
    'Review moves': () => setState('review'),
    'Not now': () => { setState('declined'); sound.play('hush'); },
    Back: () => setState('planned'),
    Move: () => move(),
    Undo: () => undo(),
    Stop: () => { setState(moved().length ? 'stopped' : 'declined'); sound.play('hush'); },
    'Show the plan': () => setState('planned'),
    'Start over': () => start(),
  };

  function strip() {
    const m = movable().length, n = new Set(movable().map((f) => f.to)).size;
    const s = {
      idle: ['Downloads, as they are.', []],
      reading: ['Perry is reading what each file is for…', ['Stop']],
      planned: ['Move files into folders. No deletions in this plan.', ['Review moves', 'Not now']],
      review: [`${m} files into ${n} folders. Untick anything you’d rather keep here.`, ['Move', 'Back']],
      moving: ['Moving files…', ['Stop']],
      undoing: ['Putting everything back…', []],
      done: [`Moved ${moved().length} files. Nothing was deleted.`, ['Undo']],
      stopped: [`Stopped after ${moved().length} files. The rest stayed put.`, ['Undo']],
      declined: ['Nothing moved.', ['Show the plan', 'Start over']],
    }[state];
    stripText.textContent = s[0];
    stripActs.replaceChildren(...s[1].map((a, i) => {
      const b = document.createElement('button');
      b.type = 'button'; b.className = i === 0 && a !== 'Stop' && a !== 'Undo' ? 'go' : 'quiet';
      b.textContent = a === 'Move' ? `Move ${m} files` : a;
      b.addEventListener('click', ACT[a]);
      return b;
    }));
  }
  strip();

  function message() {
    const look = files.find((f) => f.to === LOOK).name;
    return {
      idle: null,
      reading: { text: 'Sort these by what they’re for. Leave anything you’re unsure about.', working: true, acts: ['Stop'] },
      planned: { text: `Here’s my plan. I’d leave ${look} for you.` },
      review: { text: 'Untick anything you want left where it is.' },
      moving: { text: 'Moving them now.', working: true, acts: ['Stop'] },
      undoing: { text: 'Putting everything back.', working: true },
      done: { text: `Done. ${look} is waiting for you.`, done: true, acts: ['Undo'] },
      stopped: { text: 'Stopped. Nothing else moved.', acts: ['Undo'] },
      declined: { text: 'Okay. Nothing moved.' },
    }[state];
  }
  function speak() {
    const m = message();
    if (!m) { release(); return; }
    const key = `${m.text}|${(m.acts || []).join()}`;
    if (key !== said) {
      said = key;
      npStep.textContent = '';
      npText.textContent = m.text;
      np.classList.toggle('is-working', !!m.working);
      np.classList.toggle('is-done', !!m.done);
      npActions.replaceChildren(...(m.acts || []).map((a) => {
        const b = document.createElement('button');
        b.type = 'button'; b.className = `np__btn${a === 'Undo' ? ' np__btn--ghost' : ''}`; b.textContent = a;
        b.addEventListener('click', ACT[a]);
        return b;
      }));
      shownW = Math.max(300, Math.min(560, 120 + m.text.length * 7.4 + (m.acts || []).length * 84));
    }
    if (!np.classList.contains('on') || !owns) {
      notch.querySelectorAll('.np.on').forEach((n) => { n.classList.remove('on'); n.inert = true; });
      np.classList.add('on'); np.inert = false;
    }
    notchPanel(notch, np, shownW, notchH);
    owns = true;
  }
  function release() {
    if (!owns) return;
    np.classList.remove('on'); np.inert = true;
    notchPanel(notch, null, 0, notchH);
    owns = false;
  }

  $('[data-sort-try]').addEventListener('click', () => {
    finder.scrollIntoView({ behavior: reduced ? 'auto' : 'smooth', block: 'center' });
    start();
  });

  function read(t) {
    const step = reduced ? 0.05 : 0.42;
    const k = Math.floor((t - at) / step);
    while (cursor < Math.min(k, files.length - 1)) {
      cursor++;
      const f = files[cursor];
      files.forEach((g) => g.tile.classList.remove('is-reading'));
      f.tile.classList.add('is-reading', f.to === LOOK ? 'is-unsure' : 'is-read');
      f.row.classList.add('on');
      head.textContent = 'Perry’s plan';
      counts();
      if (!reduced) {
        if (arc && !arc.keep) { const old = arc; old.p.style.opacity = '0'; old.h.style.opacity = '0'; setTimeout(() => { old.p.remove(); old.h.remove(); }, 600); }
        arc = draw(f, false);
      }
      sound.play('plop', { volume: 0.2, pitch: 1.2 + (cursor % 4) * 0.05 });
    }
    if (k >= files.length + 1) {
      files.forEach((g) => g.tile.classList.remove('is-reading'));
      if (arc) { arc.p.style.opacity = '0'; arc.h.style.opacity = '0'; }
      inkSvg.replaceChildren();
      arc = draw(files[0], true);
      arc.born -= 1;
      setState('planned');
    }
  }

  function perryAtTile(t) {
    const size = Math.max(40, Math.min(58, finder.clientWidth * 0.045));
    let el, dx = 0.85, dy = 0.15, mood = 'open';
    if (state === 'reading') { el = files[Math.max(0, cursor)].tile.querySelector('.ftile__icon'); mood = 'focus'; }
    else if (state === 'planned' || state === 'review' || state === 'declined') { el = files[0].tile.querySelector('.ftile__icon'); dx = 1.0; dy = 0.05; }
    else { el = folders[3].el.querySelector('.fold__head'); dx = 0.75; dy = -0.2; mood = state === 'done' && t - hop < 1.8 ? 'happy' : 'open'; }
    const r = el.getBoundingClientRect();
    return { x: r.left + r.width * dx, y: r.top + r.height * dy, size, mood };
  }

  return {
    get perry() { return pos && pos.on > 0.05 ? pos : null; },
    get on() { return false; },
    get near() { return near; },
    update(t, dt, ink, pointer, { guideActive, hold }) {
      if (!near) { perry.set({ on: 0 }, t, dt); pos = null; release(); return; }
      if (state === 'reading') read(t);
      if (arc) {
        const u = clamp01((t - arc.born) / 0.45);
        arc.p.style.setProperty('--d', u.toFixed(3));
        arc.h.style.opacity = u > 0.95 && arc.p.style.opacity !== '0' ? '1' : arc.h.style.opacity;
        if (arc.keep) arc.p.style.opacity = state === 'planned' || state === 'review' ? '1' : '0';
        if (arc.keep) arc.h.style.opacity = state === 'planned' || state === 'review' ? '1' : '0';
      }
      if (!on || guideActive || hold) release(); else speak();
      if (!on) { perry.set({ on: 0 }, t, dt); pos = null; return; }
      const g = perryAtTile(t);
      const k = 1 - Math.exp(-dt * (reduced ? 60 : 9));
      if (!pos) pos = { x: g.x, y: g.y, on: 0 };
      pos.x += (g.x - pos.x) * k; pos.y += (g.y - pos.y) * k;
      pos.on = Math.min(1, pos.on + dt * 3);
      const since = t - hop;
      const bounce = !reduced && since < 0.6 ? Math.sin((since / 0.6) * Math.PI) * 20 : 0;
      perry.set({ ...perryAt(pos.x, pos.y - bounce, g.size), on: pos.on, size: g.size, mood: g.mood, rot: reduced ? 0 : Math.sin(t * 2) * 3, look: pointer.seen ? pointer : { x: g.x - 100, y: g.y + 60 } }, t, dt);
    },
  };
}
