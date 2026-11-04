import { gsap } from 'gsap';
import { ScrollTrigger } from 'gsap/ScrollTrigger';
import Lenis from 'lenis';
import { Ink } from './ink/engine.js';
import { Wordmark } from './ink/wordmark.js';
import { Eyes } from './ink/eyes.js';
import { createGuide, notchH } from './guide.js';
import { createNotes } from './notes.js';
import { createKeys } from './keys.js';
import { createSelection } from './selection.js';
import { createSentence } from './sentence.js';
import { createSort } from './sort.js';
import { createGate } from './gate.js';
import { createRoute } from './route.js';
import { createWorkspace } from './workspace.js';
import { sound } from './sound.js';

gsap.registerPlugin(ScrollTrigger);

const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;
const touch = matchMedia('(hover: none)').matches;
const html = document.documentElement;
const clamp01 = (v) => (v < 0 ? 0 : v > 1 ? 1 : v);
const smooth = (t) => t * t * (3 - 2 * t);

// ---------- scroll ----------
let lenis = null;
if (!reduced) {
  lenis = new Lenis({ lerp: 0.11, wheelMultiplier: 0.9 });
  lenis.on('scroll', ScrollTrigger.update);
  gsap.ticker.add((t) => lenis.raf(t * 1000));
  gsap.ticker.lagSmoothing(0);
}
const scrollTo = (y, duration = 1.6) => (lenis ? lenis.scrollTo(y, { duration, immediate: !duration }) : scrollTo_(y));
const scrollTo_ = (y) => window.scrollTo({ top: y, behavior: 'auto' });

// ---------- ink ----------
const canvas = document.querySelector('.ink');
const ink = new Ink(canvas, { dprCap: innerWidth < 700 ? 1.5 : 2, low: innerWidth < 700 || (navigator.hardwareConcurrency || 8) <= 4 });
const word = new Wordmark();
const wordEyes = new Eyes();
wordEyes.awake = false;
const notchEyes = new Eyes();
const notch = document.querySelector('.notch');
const nav = document.querySelector('.nav');
const menuBtn = nav.querySelector('[data-menu-btn]'), menuList = nav.querySelector('[data-menu-list]');
const setMenu = (open) => { menuList.hidden = !open; menuBtn.setAttribute('aria-expanded', String(open)); if (open) menuList.querySelector('[role="menuitem"]').focus({ preventScroll: true }); };
menuBtn.addEventListener('click', () => setMenu(menuList.hidden));
menuList.addEventListener('click', () => setMenu(false));
document.addEventListener('pointerdown', (e) => { if (!menuList.hidden && !e.target.closest('[data-menu]')) setMenu(false); });
addEventListener('keydown', (e) => {
  if (e.key === 'Escape' && !menuList.hidden) { setMenu(false); menuBtn.focus(); }
  if (e.key === 'q' && e.metaKey) { e.preventDefault(); quit(); }
});
const clockEl = nav.querySelector('[data-clock]');
const clockFmt = new Intl.DateTimeFormat(undefined, { weekday: 'short', day: 'numeric', month: 'short', hour: 'numeric', minute: '2-digit' });
const tickClock = () => { clockEl.textContent = clockFmt.format(new Date()).replace(/,/g, ''); };
tickClock();
setInterval(tickClock, 15000);
const barEyes = [...nav.querySelectorAll('.menubar__perry i')];
let quitAt = -10;
function quit() {
  quitAt = performance.now() / 1000;
  notch.classList.remove('nope'); void notch.offsetWidth; notch.classList.add('nope');
}
nav.querySelector('[data-quit]').addEventListener('click', quit);
const notchEyeEls = [...notch.querySelectorAll('.notch__eye')];

const pointer = { x: innerWidth * 0.5, y: innerHeight * 0.55, seen: false, moved: 0, inside: true };
addEventListener('pointermove', (e) => {
  pointer.x = e.clientX; pointer.y = e.clientY; pointer.seen = true; pointer.moved = performance.now() / 1000; pointer.inside = true;
}, { passive: true });
document.addEventListener('pointerleave', () => { pointer.inside = false; });
let curious = null, scrolled = 0, startledAt = -10, dozing = false;
document.addEventListener('pointerover', (e) => {
  const el = e.target.closest('a, button, summary, input, label, .fact');
  curious = el && !el.closest('.notch, .menubar__perry') ? el : null;
}, { passive: true });
addEventListener('scroll', () => { scrolled = performance.now() / 1000; }, { passive: true });
function startle(t) {
  startledAt = t;
  notchEyes.blinkNow();
  notch.classList.remove('startle'); void notch.offsetWidth; notch.classList.add('startle');
}
addEventListener('pointerdown', (e) => {
  pointer.x = e.clientX; pointer.y = e.clientY; pointer.moved = performance.now() / 1000;
  if (heroP < 0.1 && !reduced) { wordEyes.blinkNow(true); poke = performance.now() / 1000; pokeX = e.clientX; }
});

// ---------- hero ----------
const heroEl = document.querySelector('.hero');
const markEl = document.querySelector('[data-mark]');
const heroTitle = document.querySelector('.hero__title');
const heroCta = document.querySelector('.hero__cta');
let heroP = 0, poke = -10, pokeX = 0, hoverCta = null;
const touchPt = { x: -999, y: -999, s: 0 };
const t0 = performance.now() / 1000 + 0.35;
const skipPaint = reduced || scrollY > innerHeight * 0.5;

document.querySelectorAll('[data-get]').forEach((b) => {
  b.addEventListener('pointerenter', () => { hoverCta = b; });
  b.addEventListener('pointerleave', () => { if (hoverCta === b) hoverCta = null; });
  b.addEventListener('focus', () => { hoverCta = b; });
  b.addEventListener('blur', () => { if (hoverCta === b) hoverCta = null; });
  b.addEventListener('pointermove', (e) => {
    const r = b.getBoundingClientRect();
    b.style.setProperty('--fx', `${e.clientX - r.left}px`);
    b.style.setProperty('--fy', `${e.clientY - r.top}px`);
  });
});

function placeIn(r) {
  const b = word.box;
  const scale = Math.min(r.width / b.w, r.height / b.h);
  return { x: r.left + (r.width - b.w * scale) / 2 - b.x * scale, y: r.top + (r.height - b.h * scale) / 2 - b.y * scale, scale };
}

ScrollTrigger.create({
  trigger: heroEl, start: 'top top', end: 'bottom bottom',
  onUpdate: (s) => { heroP = s.progress; },
});

let wander = { at: 0, x: 0, y: 0 };
function actHero(t) {
  // Where do the eyes look, and how do they feel about it?
  const eyesAt = word.eyePlaces || [{ x: innerWidth / 2, y: innerHeight / 2 }];
  const cx = (eyesAt[0].x + eyesAt[eyesAt.length - 1].x) / 2, cy = eyesAt[0].y;
  let tx = pointer.x, ty = pointer.y, squint = 0, ps = 1, open = 1;
  const idle = t - pointer.moved;
  if (hoverCta && actHero.cta) {
    const r = actHero.cta;
    tx = r.left + r.width / 2; ty = r.top + r.height / 2; ps = 1.3; squint = 0.42;
  } else if (!pointer.inside) {
    tx = cx - 200; ty = cy + 320;
    if (idle > 6) open = 0.5;
  } else if (!pointer.seen || idle > 4.5) {
    if (t > wander.at) {
      wander = { at: t + 1.2 + Math.random() * 1.8, x: cx + (Math.random() - 0.5) * innerWidth * 0.9, y: cy + (Math.random() - 0.3) * innerHeight * 0.7 };
    }
    tx = wander.x; ty = wander.y;
    if (idle > 14) open = 0.55;
  }
  // too close: being poked
  const near = Math.min(...eyesAt.map((e) => Math.hypot(pointer.x - e.x, pointer.y - e.y) / (e.r || 30)));
  if (pointer.seen && near < 1.6) squint = 0.95;
  if (t - poke < 0.5) squint = Math.max(squint, 0.7);
  // as the drain starts, look home first
  const up = smooth(clamp01(heroP / 0.08));
  tx += (innerWidth / 2 - tx) * up; ty += (0 - ty) * up;
  wordEyes.lookAt(tx, ty);
  wordEyes.mood({ squint, ps, open });
}

// ---------- the middle ----------
const guide = createGuide(notch, { reduced, scrollTo, notchH });
const wakeHere = () => guide.wake(pointer.seen ? pointer : { x: innerWidth * 0.62, y: innerHeight * 0.4 });
const home = createWorkspace(document.querySelector('.home'), { reduced, notch });
createKeys({ ask: () => (home.inside ? home.reveal() : guide.open()), wake: wakeHere, talk: guide.talk });
document.querySelector('[data-wake]').addEventListener('click', wakeHere);
const selection = createSelection({ reduced, ask: () => guide.open() });
const sentence = createSentence(document.querySelector('.sentence'), { reduced });
const sorter = createSort(document.querySelector('.sort'), { reduced, notch, notchH });
const gate = createGate(document.querySelector('.gate'), { reduced });
const route = createRoute(document.querySelector('.route'), { reduced });

// ---------- finale: night ----------
const finale = document.querySelector('.finale');
const finTrack = finale.querySelector('.finale__track');
const finTitle = finale.querySelector('.finale__title');
const finCta = finale.querySelector('.btn--big');
const finEyeEls = [...finale.querySelectorAll('.finale__eye')];
const notchBody = notch.querySelector('.notch__body');
const finEyes = new Eyes();
finEyes.awake = false;
let pourP = 0, revealP = 0, finNear = false, finSo = 0;
ScrollTrigger.create({ trigger: finTrack, start: 'top bottom', end: 'top 22%', onUpdate: (s) => { pourP = s.progress; }, onRefresh: (s) => { pourP = s.progress; } });
ScrollTrigger.create({ trigger: finTrack, start: 'top 30%', end: 'top -55%', onUpdate: (s) => { revealP = s.progress; }, onRefresh: (s) => { revealP = s.progress; } });
ScrollTrigger.create({ trigger: finTrack, start: 'top bottom', end: 'bottom top', onToggle: (s) => { finNear = s.isActive; } });
if (reduced) finale.classList.add('is-static');
finTitle.innerHTML = `<span class="sr-only">${finTitle.textContent}</span><span aria-hidden="true">${finTitle.textContent.split(' ').map((w) => `<span class="w">${w}</span>`).join(' ')}</span>`;
const finWords = [...finTitle.querySelectorAll('.w')];

// night falls over the page, and the notch's eyes close as the finale's open
function pour() {
  const q = reduced || !finNear ? 0 : pourP;
  notch.classList.toggle('is-pouring', q > 0);
  html.classList.toggle('is-pouring', q > 0);
  const g = smooth(clamp01((q - 0.12) / 0.8));
  html.style.setProperty('--dusk', g.toFixed(3));
  notch.style.setProperty('--pe', (1 - smooth(clamp01(g / 0.4))).toFixed(3));
  return g;
}

// the ink is liquid: it leans away from the pointer, and ripples when you click
function liquid(pl, t) {
  if (reduced || touch) return null;
  const k = 1 - Math.exp(-(t - (liquid.t || t)) * 14);
  liquid.t = t;
  touchPt.x += (pointer.x - touchPt.x) * k;
  touchPt.y += (pointer.y - touchPt.y) * k;
  const target = pointer.inside && pointer.seen ? 1 : 0;
  touchPt.s += (target - touchPt.s) * k * 0.5;
  return { x: touchPt.x, y: touchPt.y, r: 70 * pl.scale / 3, s: 16 * (pl.scale / 3) * touchPt.s };
}
function ripple(pl, t) {
  const age = t - poke;
  return !reduced && age < 1.4 ? { x: pokeX, t: age, a: 9 * (pl.scale / 3) } : null;
}

const soundBtn = nav.querySelector('[data-sound]');
sound.watch((on) => soundBtn.setAttribute('aria-pressed', String(on)));
soundBtn.addEventListener('click', () => { sound.set(!sound.on); sound.play('perk'); });

// the tab icon is Perry too: it blinks, and sleeps while you're away
const icon = document.querySelector('link[rel="icon"]');
const face = (lid) => 'data:image/svg+xml,' + encodeURIComponent(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="15" fill="#1c1e1b"/>${[23, 41].map((x) => (lid < 0.3 ? `<path d="M${x - 6} 33q6 4 12 0" stroke="#f4f1e8" stroke-width="4" stroke-linecap="round" fill="none"/>` : `<rect x="${x - 4.5}" y="${32 - 11 * lid}" width="9" height="${22 * lid}" rx="4.5" fill="#f4f1e8"/>`)).join('')}</svg>`);
const faces = { open: face(1), shut: face(0) };
let iconBlink = 0, awayAt = 0;
const setIcon = (f) => { if (icon.href !== f) icon.href = f; };
setIcon(faces.open);
function blinkIcon() {
  clearTimeout(iconBlink);
  iconBlink = setTimeout(() => {
    if (document.hidden) return;
    setIcon(faces.shut);
    setTimeout(() => { if (!document.hidden) setIcon(faces.open); blinkIcon(); }, 140);
  }, 2600 + Math.random() * 4200);
}
blinkIcon();
document.addEventListener('visibilitychange', () => {
  if (document.hidden) { awayAt = performance.now() / 1000; setIcon(faces.shut); return; }
  setIcon(faces.open);
  blinkIcon();
  if (performance.now() / 1000 - awayAt > 2.5) { welcomeAt = performance.now() / 1000 + 0.25; }
});
let welcomeAt = -10;
const notes = createNotes({ reduced });


// ---------- the one loop ----------
let lastT = performance.now() / 1000, gulped = false, lastSig = -1;
function tick() {
  const t = performance.now() / 1000;
  const dt = Math.min(0.05, t - lastT);
  lastT = t;
  ink.resize();
  ink.begin();
  const W = innerWidth;
  // reads first, so the frame costs one layout
  const rMark = heroP < 0.999 ? markEl.getBoundingClientRect() : null;
  const rFinEyes = finNear ? finEyeEls.map((el) => el.getBoundingClientRect()) : null;
  const rCta = hoverCta ? hoverCta.getBoundingClientRect() : null;
  const rFinCta = finNear ? finCta.getBoundingClientRect() : null;
  const rNotch = notchBody.getBoundingClientRect();
  const rEyes = notchEyeEls.map((el) => el.getBoundingClientRect());
  const rCur = curious && !touch ? curious.getBoundingClientRect() : null;
  const notchPt = { x: W / 2, y: notchH() * 0.45, w: W <= 900 ? 124 : 196 };

  // hero wordmark
  const heroVisible = heroP < 0.999;
  nav.classList.toggle('is-solid', heroP > 0.998 && !(finNear && pourP > 0.05));
  nav.classList.toggle('is-tucked', W <= 900 && notch.classList.contains('is-open'));
  let drain = reduced ? (heroP > 0.45 ? 1 : 0) : smooth(clamp01((heroP - 0.04) / 0.84));
  if (heroVisible && drain < 1) {
    const clock = skipPaint ? Infinity : t - t0;
    if (clock > word.paintEnd + 0.15 && !wordEyes.awake) { wordEyes.awake = true; wordEyes.blinkAt = t + 0.4; }
    if (skipPaint) wordEyes.awake = true;
    actHero.cta = rCta;
    actHero(t);
    wordEyes.update(t, dt);
    const pl = placeIn(rMark);
    const eyes = word.draw(ink, pl, clock, drain, notchPt, liquid(pl, t), ripple(pl, t));
    eyes.forEach((e) => {
      const rx = e.r * 0.27, ry = e.r * 0.47;
      const p = wordEyes.pupil(e.x, e.y, e.r, e.r, 0.3);
      ink.eye({ x: e.x, y: e.y, rx, ry, open: wordEyes.open * (e.k > 0.2 ? 1 : 0), px: p.x, py: p.y, ps: 1, squint: wordEyes.squint, glow: 0, angle: 0, capsule: true });
    });
  }
  const opacityHero = 1 - smooth(clamp01((heroP - 0.02) / 0.16));
  heroTitle.style.opacity = heroCta.style.opacity = opacityHero.toFixed(3);
  heroCta.style.visibility = opacityHero < 0.02 ? 'hidden' : '';
  const eyesHome = drain > 0.86 || heroP >= 0.999;
  if (eyesHome && !gulped && !reduced) { notch.classList.remove('gulp'); void notch.offsetWidth; notch.classList.add('gulp'); }
  gulped = eyesHome;
  notch.classList.toggle('has-eyes', eyesHome);


  // finale
  const grown = pour();
  ink.onDark = sorter.on || (finNear && grown > 0.55);
  html.classList.toggle('is-night', finNear && (reduced ? pourP > 0.6 : grown > 0.55));
  if (finNear) {
    const rv = reduced ? 1 : revealP;
    const eo = smooth(clamp01((rv - 0.02) / 0.22));
    finale.style.setProperty('--glow', smooth(clamp01(rv / 0.5)).toFixed(3));
    finale.style.setProperty('--eo', eo.toFixed(3));
    const n = clamp01((rv - 0.16) / 0.42) * (finWords.length + 1.5);
    finWords.forEach((w, i) => w.style.setProperty('--o', smooth(clamp01(n - i)).toFixed(3)));
    const so = smooth(clamp01((rv - 0.55) / 0.22));
    finale.style.setProperty('--so', so.toFixed(3));
    finale.style.setProperty('--fo', smooth(clamp01((rv - 0.72) / 0.22)).toFixed(3));
    finCta.style.visibility = so < 0.02 ? 'hidden' : '';
    finSo = so;
    // the notch's own eyes open inside it, then follow you
    if (!finEyes.awake && rv > 0.1) { finEyes.awake = true; finEyes.blinkAt = t + 0.9; }
    if (rv <= 0.05) finEyes.awake = false;
    const happy = hoverCta === finCta;
    finale.classList.toggle('is-happy', happy);
    if (happy && rCta) finEyes.lookAt(rCta.left + rCta.width / 2, rCta.top + rCta.height / 2); else finEyes.lookAt(pointer.x, pointer.y);
    finEyes.mood({ open: 1 });
    finEyes.update(t, dt);
    finEyeEls.forEach((el, i) => {
      const r = rFinEyes[i];
      const pp = finEyes.pupil(r.left + r.width / 2, r.top + r.height / 2, r.width * 1.2, r.height * 0.6, 0.6);
      el.style.setProperty('--px', `${pp.x.toFixed(2)}px`);
      el.style.setProperty('--py', `${pp.y.toFixed(2)}px`);
      el.style.setProperty('--lid', Math.max(0.06, happy ? Math.min(finEyes.open, 0.62) : finEyes.open).toFixed(3));
    });
  }
  guide.update(t, dt, ink, pointer);
  sentence.update(t, dt, pointer);
  sorter.update(t, dt, ink, pointer, { guideActive: guide.active, hold: home.open });
  gate.update(t, dt);
  route.update(t, dt, pointer);
  home.update(t, dt, pointer);
  selection.update(t, ink);
  notes.update(t, ink, { cta: finNear && finSo > 0.95 ? rFinCta : null, notch: rNotch });

  // notch eyes: watch Perry when he's out, else you
  if (welcomeAt > 0 && t > welcomeAt) { welcomeAt = -10; if (!reduced) startle(t); notchEyes.blinkNow(true); sound.play('perk'); }
  const p = guide.perry || sorter.perry;
  const seen = selection.focus;
  const idle = t - Math.max(pointer.moved, scrolled);
  if (dozing && idle < 0.3) { notchEyes.blinkNow(true); if (!reduced) startle(t); }
  dozing = eyesHome && idle > 22;
  if (!reduced && eyesHome && Math.abs(lenis?.velocity || 0) > 70 && t - startledAt > 2.5) startle(t);
  const shocked = t - startledAt < 0.8;
  const peek = !p && rCur && rCur.bottom > 0 && rCur.top < innerHeight;
  if (p && p.on > 0.05) notchEyes.lookAt(p.x, p.y);
  else if (seen) notchEyes.lookAt(seen.x, seen.y);
  else if (peek) notchEyes.lookAt(rCur.left + rCur.width / 2, rCur.top + rCur.height / 2);
  else notchEyes.lookAt(pointer.x, pointer.y);
  notchEyes.mood({ open: shocked ? 1 : dozing ? 0.14 : idle > 9 ? 0.55 : 1 });
  notch.classList.toggle('is-curious', !!peek && !shocked && !dozing);
  if (!shocked) notch.classList.remove('startle');
  notch.classList.toggle('is-dozing', dozing);
  const np = notch.querySelector('.np.on')?.dataset.np;
  const mood = gate.needs ? 'needs' : ['gq', 'talk', 'bench'].includes(np) ? 'listening' : 'resting';
  if (notch.dataset.mood !== mood) notch.dataset.mood = mood;
  notchEyes.update(t, dt);
  const rBar = barEyes[0].getBoundingClientRect();
  const sulk = t - quitAt < 1.6;
  const bdx = pointer.x - rBar.right, bdy = pointer.y - rBar.top, bd = Math.hypot(bdx, bdy) || 1;
  barEyes.forEach((el) => {
    el.style.setProperty('--px', `${(sulk ? 0 : (bdx / bd) * 1.6).toFixed(2)}px`);
    el.style.setProperty('--py', `${(sulk ? 1 : (bdy / bd) * 1.4).toFixed(2)}px`);
    el.style.setProperty('--lid', (sulk ? 0.3 : Math.max(0.12, notchEyes.open)).toFixed(3));
  });
  notchEyeEls.forEach((el, i) => {
    const r = rEyes[i];
    const pp = notchEyes.pupil(r.left + r.width / 2, r.top + r.height / 2, 5.5, 7, 0.55);
    el.style.setProperty('--px', `${pp.x.toFixed(2)}px`);
    el.style.setProperty('--py', `${pp.y.toFixed(2)}px`);
    el.style.setProperty('--lid', Math.max(0.08, notchEyes.open).toFixed(3));
  });

  // skip the GPU when the frame would be identical
  let sig = ink.count * 7.1 + W + innerHeight * 1.7;
  const d = ink.data;
  for (let i = 0; i < ink.count; i += 37) sig += d[i * 8] * 0.31 + d[i * 8 + 1] * 0.17 + d[i * 8 + 2] * 0.07 + d[i * 8 + 6];
  for (const e of ink.eyes) sig += e.x * 0.13 + e.y * 0.11 + e.open * 5 + e.px * 3 + e.py * 2 + e.squint * 7 + e.ps;
  if (sig !== lastSig) ink.render();
  lastSig = sig;
}
gsap.ticker.add(tick);

addEventListener('resize', () => { ink.resize(); ScrollTrigger.refresh(); });
document.fonts?.ready.then(() => ScrollTrigger.refresh());
document.querySelectorAll('a[href^="#"]:not(.skip)').forEach((a) => a.addEventListener('click', (e) => {
  const id = a.getAttribute('href');
  const el = id === '#top' ? document.body : document.querySelector(id);
  if (!el) return;
  e.preventDefault();
  scrollTo(id === '#top' ? 0 : el.getBoundingClientRect().top + scrollY - (id === '#help' ? 0 : 40));
}));
if (touch) html.classList.add('touch');
