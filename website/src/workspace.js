// Mirrors NotchWorkspaceView and NotchShape in perry/App.
import { ScrollTrigger } from 'gsap/ScrollTrigger';
import { createMascot } from './mascot.js';
import { sound } from './sound.js';

const KEYS = {
  what: ['what is perry', 'what does perry', 'what does it do', 'about perry', 'explain', 'who are you', 'what are you'],
  how: ['how do i', 'use it', 'talk', 'voice', 'type', 'shortcut', 'hotkey', 'open it', 'start', 'speak'],
  cost: ['cost', 'price', 'pay', 'free', 'money', 'subscription', 'plan', 'open source', 'license', 'account', 'chatgpt'],
  macs: ['mac', 'intel', 'silicon', 'macos', 'sonoma', 'notch', 'run on', 'require', 'compatib', 'm1', 'm2', 'm3', 'm4', 'windows'],
  see: ['see', 'screen', 'watch', 'record', 'access', 'permission', 'look', 'spy', 'bank', 'password'],
  keep: ['screenshot', 'keep', 'save', 'store', 'disk', 'retain', 'memory'],
  route: ['server', 'provider', 'key', 'api', 'data', 'privacy', 'private', 'cloud', 'where', 'openai', 'anthropic', 'claude', 'gemini', 'telemetry', 'track', 'model', 'ollama'],
  asks: ['without asking', 'approv', 'confirm', 'delete', 'buy', 'purchase', 'send', 'act on', 'do things', 'control', 'click for me', 'safe', 'undo'],
  out: ['out yet', 'release', 'download', 'beta', 'available', 'launch', 'when', 'get it', 'install', 'waitlist', 'ship', 'version', 'update'],
};
const QA = [...document.querySelectorAll('[data-qa]')].map((el) => ({
  id: el.dataset.qa,
  q: el.querySelector('h3').textContent.trim(),
  a: el.querySelector('p').textContent.trim().replace(/\s+/g, ' '),
  k: KEYS[el.dataset.qa] || [],
}));
const FALLBACK = 'Here I can only answer questions about Perry itself. In the app, I’d look at the window you’re in and answer about that.';
const HELLO = 'Hi. Ask me anything about Perry, or pick a question on the left.';

const words = (s) => s.toLowerCase().replace(/[’']/g, '').replace(/[^a-z0-9 ]/g, ' ');
function answer(text) {
  const s = ` ${words(text)} `;
  if (/^\s*(hi|hello|hey|yo|sup)\b/.test(s)) return { a: HELLO };
  let best = null, score = 0;
  for (const item of QA) {
    const n = item.k.reduce((sum, k) => sum + (s.includes(k) ? (k.length > 5 ? 2 : 1) : 0), 0);
    if (n > score) { best = item; score = n; }
  }
  return best ? { a: best.a, id: best.id } : { a: FALLBACK, miss: true };
}

export function createWorkspace(root, { reduced, notch }) {
  const html = document.documentElement;
  const ws = root.querySelector('[data-ws]');
  const panel = ws.querySelector('.ws__panel');
  const toggle = ws.querySelector('[data-ws-toggle]');
  const rest = ws.querySelector('[data-ws-rest]'), focus = ws.querySelector('[data-ws-focus]');
  const title = ws.querySelector('[data-ws-title]'), body = ws.querySelector('[data-ws-body]');
  const list = ws.querySelector('[data-ws-threads]'), none = ws.querySelector('[data-ws-none]');
  const search = ws.querySelector('[data-ws-search]');
  const forms = [...ws.querySelectorAll('[data-ws-form]')];
  const dock = ws.querySelector('[data-ws-form="focus"]');
  const links = [...ws.querySelectorAll('[data-ws-page]')];
  const greeting = ws.querySelector('[data-ws-greeting]');
  const main = ws.querySelector('.ws__main');
  const chars = [];
  const charIn = (host, size, mood = 'open') => {
    const el = document.createElement('div');
    el.className = 'mascot';
    host.append(el);
    const c = { m: createMascot(el), host, size, mood };
    chars.push(c);
    return c;
  };
  const brand = charIn(ws.querySelector('[data-ws-char]'), 20);
  const big = charIn(ws.querySelector('[data-ws-bigchar]'), 40);
  body.setAttribute('data-lenis-prevent', '');
  ws.querySelector('.ws__threads').setAttribute('data-lenis-prevent', '');

  const threads = QA.map((x) => ({ id: x.id, title: x.q, turns: [{ q: x.q, a: x.a, shown: false }] }));
  let selected = null, open = false, dismissed = false, inside = false, armedTimer = 0, streaming = null, page = null, thinkUntil = 0;

  const mobileQ = document.createElement('div');
  mobileQ.className = 'ws__mobile-q';
  mobileQ.setAttribute('role', 'group');
  mobileQ.setAttribute('aria-label', 'Questions');
  main.prepend(mobileQ);

  const hour = new Date().getHours();
  greeting.textContent = hour >= 5 && hour < 12 ? 'Morning.' : hour >= 12 && hour < 17 ? 'Afternoon.' : 'Evening.';

  function size() {
    const narrow = innerWidth <= 900;
    const w = narrow ? innerWidth - 12 : Math.min(980, innerWidth - 96);
    const h = narrow ? Math.min(innerHeight * 0.7, 620) : Math.max(480, Math.min(660, innerHeight - 230));
    ws.style.setProperty('--open-w', `${Math.round(w)}px`);
    ws.style.setProperty('--open-h', `${Math.round(h)}px`);
  }
  size();
  addEventListener('resize', size);

  function renderList() {
    const f = search.value.trim().toLowerCase();
    const shown = threads.filter((t) => !f || t.title.toLowerCase().includes(f));
    list.replaceChildren(...shown.map((t) => {
      const li = document.createElement('li');
      const b = document.createElement('button');
      b.type = 'button'; b.className = 'ws__row'; b.textContent = t.title; b.title = t.title;
      if (t.fresh) { b.classList.add('is-new'); t.fresh = false; }
      if (selected === t) b.setAttribute('aria-current', 'page');
      b.addEventListener('click', () => select(t));
      li.append(b);
      return li;
    }));
    none.hidden = !(f && !shown.length);
    none.textContent = `No matches for “${search.value.trim()}”`;
    mobileQ.replaceChildren(...threads.slice(0, 8).map((t) => {
      const b = document.createElement('button');
      b.type = 'button'; b.textContent = t.title;
      if (selected === t) b.setAttribute('aria-current', 'page');
      b.addEventListener('click', () => select(t));
      return b;
    }));
  }

  function showPage(which) {
    const enter = which === 'rest' ? rest : focus;
    const leave = which === 'rest' ? focus : rest;
    if (!enter.hidden) return;
    leave.hidden = true; enter.hidden = false;
    if (!reduced) { enter.classList.remove('is-entering'); void enter.offsetWidth; enter.classList.add('is-entering'); }
  }

  function turnEl(turn) {
    const wrap = document.createElement('div');
    wrap.className = 'turn';
    const q = document.createElement('p');
    q.className = 'turn__q'; q.textContent = turn.q;
    const a = document.createElement('p');
    a.className = 'turn__a';
    wrap.append(q, a);
    return { wrap, a };
  }

  function more(exclude) {
    const box = document.createElement('div');
    box.className = 'turn__more';
    const at = Math.max(0, QA.findIndex((x) => x.id === exclude));
    [1, 2, 3].map((n) => QA[(at + n) % QA.length]).forEach((x) => {
      const b = document.createElement('button');
      b.type = 'button'; b.textContent = x.q;
      b.addEventListener('click', () => select(threads.find((t) => t.id === x.id)));
      box.append(b);
    });
    return box;
  }

  function stream(a, text, done) {
    if (streaming) streaming.finish();
    const parts = text.split(' ');
    if (reduced) { a.textContent = text; done(); return; }
    a.innerHTML = '<span class="turn__think" aria-label="Thinking"><i></i><i></i><i></i></span>';
    thinkUntil = performance.now() / 1000 + 0.55;
    let i = 0, timer = 0;
    const finish = () => { clearTimeout(timer); a.textContent = text; streaming = null; done(); };
    const tick = () => {
      if (i === 0) a.textContent = '';
      const n = Math.min(parts.length, i + 2);
      for (; i < n; i++) {
        const w = document.createElement('span');
        w.className = 'w'; w.textContent = (i ? ' ' : '') + parts[i];
        a.append(w);
      }
      body.scrollTop = body.scrollHeight;
      if (i < parts.length) timer = setTimeout(tick, 55); else finish();
    };
    timer = setTimeout(tick, 550);
    streaming = { finish };
  }

  function renderThread(t) {
    body.replaceChildren();
    t.turns.forEach((turn, n) => {
      const { wrap, a } = turnEl(turn);
      body.append(wrap);
      const last = n === t.turns.length - 1;
      if (turn.shown) { a.textContent = turn.a; if (last) wrap.append(more(t.id)); return; }
      turn.shown = true;
      stream(a, turn.a, () => { if (last) wrap.append(more(t.id)); });
    });
    body.scrollTop = body.scrollHeight;
  }

  function select(t) {
    selected = t; page = null;
    links.forEach((l) => l.removeAttribute('aria-current'));
    title.textContent = t.title;
    dock.hidden = false;
    showPage('focus');
    renderThread(t);
    renderList();
    sound.play('plop', { volume: 0.6 });
  }

  function openPage(name) {
    selected = null; page = name;
    if (streaming) streaming.finish();
    links.forEach((l) => (l.dataset.wsPage === name ? l.setAttribute('aria-current', 'page') : l.removeAttribute('aria-current')));
    title.textContent = name;
    dock.hidden = true;
    body.replaceChildren();
    const empty = document.createElement('div');
    empty.className = 'empty';
    empty.innerHTML = '<span class="empty__char"></span><h4>This lives in the app.</h4><p>You’re on Perry’s website, so there’s nothing here yet. Ask about Perry instead.</p>';
    const b = document.createElement('button');
    b.type = 'button'; b.className = 'ink-btn ink-btn--secondary'; b.textContent = 'Ask a question';
    b.style.marginTop = '8px';
    b.addEventListener('click', () => home(true));
    empty.append(b);
    body.append(empty);
    charIn(empty.querySelector('.empty__char'), 34, 'closed');
    showPage('focus');
    renderList();
  }

  function home(focusInput) {
    selected = null; page = null;
    links.forEach((l) => l.removeAttribute('aria-current'));
    showPage('rest');
    renderList();
    if (focusInput) rest.querySelector('textarea').focus({ preventScroll: true });
  }

  function ask(text, form) {
    const q = text.trim();
    if (!q) return;
    const res = answer(q);
    let t = selected;
    if (!t || form.dataset.wsForm === 'rest') {
      t = { id: `u${threads.length}`, title: q.length > 42 ? `${q.slice(0, 40)}…` : q, turns: [], fresh: true };
      threads.unshift(t);
    }
    t.turns.push({ q, a: res.a, shown: false });
    select(t);
    dock.querySelector('textarea').focus({ preventScroll: true });
  }

  forms.forEach((form) => {
    const ta = form.querySelector('textarea');
    const sync = () => {
      form.classList.toggle('is-empty', !ta.value.trim());
      ta.style.height = 'auto';
      if (ta.scrollHeight) ta.style.height = `${Math.min(108, ta.scrollHeight)}px`;
    };
    sync();
    ta.addEventListener('input', sync);
    ta.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' && !e.shiftKey && !e.isComposing) { e.preventDefault(); form.requestSubmit(); }
    });
    form.addEventListener('submit', (e) => {
      e.preventDefault();
      const v = ta.value;
      ta.value = ''; sync();
      ask(v, form);
    });
  });

  search.addEventListener('input', renderList);
  ws.querySelector('[data-ws-home]').addEventListener('click', () => home(false));
  ws.querySelector('[data-ws-new]').addEventListener('click', () => home(true));
  links.forEach((l) => l.addEventListener('click', () => openPage(l.dataset.wsPage)));
  ws.querySelectorAll('[data-ws-close]').forEach((b) => b.addEventListener('click', () => { dismissed = true; setOpen(false); toggle.focus({ preventScroll: true }); }));
  toggle.addEventListener('click', () => { dismissed = false; setOpen(true); });
  ws.addEventListener('keydown', (e) => {
    if (!open || !(e.metaKey || e.ctrlKey)) return;
    if (e.key === 'n') { e.preventDefault(); home(true); }
    if (e.key === '[') { e.preventDefault(); home(false); }
    if (e.key === 'f') { e.preventDefault(); search.focus(); }
  });
  addEventListener('keydown', (e) => {
    if (e.key !== 'Escape' || !open) return;
    if (document.activeElement === search && search.value) { search.value = ''; renderList(); return; }
    dismissed = true; setOpen(false);
    if (ws.contains(document.activeElement)) toggle.focus({ preventScroll: true });
  });
  notch.querySelector('.notch__ask').addEventListener('click', (e) => {
    if (!inside || open) return;
    e.stopImmediatePropagation();
    dismissed = false; setOpen(true);
  }, true);

  function setOpen(v) {
    if (v === open) return;
    open = v;
    clearTimeout(armedTimer);
    if (v) {
      size();
      ws.classList.add('is-armed');
      void ws.offsetWidth;
      ws.classList.add('is-open');
      html.classList.add('ws-open');
      sound.play('plop');
    } else {
      ws.classList.remove('is-open');
      if (!inside) armedTimer = setTimeout(() => { if (!open) { ws.classList.remove('is-armed'); html.classList.remove('ws-open'); } }, 420);
      else html.classList.add('ws-open');
    }
    panel.inert = !v;
    toggle.setAttribute('aria-expanded', String(v));
  }

  ScrollTrigger.create({
    trigger: root, start: 'top top', end: 'bottom bottom',
    onToggle: (s) => {
      inside = s.isActive;
      if (inside) { ws.classList.add('is-armed'); html.classList.add('ws-open'); if (!dismissed) setOpen(true); }
      else { dismissed = false; setOpen(false); }
    },
  });
  panel.inert = true;
  renderList();

  return {
    get open() { return open; },
    get inside() { return inside; },
    reveal() { dismissed = false; setOpen(true); setTimeout(() => rest.hidden ? dock.querySelector('textarea').focus({ preventScroll: true }) : rest.querySelector('textarea').focus({ preventScroll: true }), 120); },
    update(t, dt, pointer) {
      if (!open) return;
      const busy = t < thinkUntil || !!streaming;
      chars.forEach((c) => {
        if (!c.host.isConnected) return;
        const r = c.host.getBoundingClientRect();
        c.m.set({ x: r.left + 0.12 * c.size, y: r.top + 0.1 * c.size, on: 1, size: c.size, mood: busy && c !== brand ? 'focus' : c.mood, look: pointer.seen ? pointer : { x: r.left, y: r.top + 200 } }, t, dt);
      });
    },
  };
}
