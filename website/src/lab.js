import { Ink } from './ink/engine.js';
import { Wordmark } from './ink/wordmark.js';

const canvas = document.querySelector('canvas');
const ink = new Ink(canvas);
const wm = new Wordmark();
const q = new URLSearchParams(location.search);
const clockAt = q.has('t') ? parseFloat(q.get('t')) : Infinity;
const drain = parseFloat(q.get('drain') || '0');
const night = parseFloat(q.get('night') || '0');
const look = (q.get('look') || '0,0').split(',').map(Number);

function frame() {
  ink.resize();
  const W = canvas.clientWidth, H = canvas.clientHeight;
  const scale = (W * 0.86) / wm.box.w;
  const place = { x: (W - wm.box.w * scale) / 2, y: H * 0.5 - (wm.box.y + wm.box.h / 2) * scale, scale };
  ink.begin();
  ink.night = night;
  const eyes = wm.draw(ink, place, clockAt, drain, { x: W / 2, y: 0 });
  eyes.forEach((e) => {
    const rx = e.r * 0.5, ry = e.r * 0.58;
    ink.eye({ x: e.x, y: e.y, rx, ry, open: 1, px: look[0] * rx * 0.42, py: look[1] * ry * 0.4, ps: 1.18, squint: parseFloat(q.get('squint') || '0'), glow: 1, angle: -0.08 });
  });
  ink.render();
}
frame();
addEventListener('resize', frame);
window.__frame = frame;
