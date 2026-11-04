import { drawMark } from './ink/actors.js';
import { mark } from './guide.js';
import { sound } from './sound.js';

const clamp01 = (v) => (v < 0 ? 0 : v > 1 ? 1 : v);
const smooth = (t) => t * t * (3 - 2 * t);

export function createSelection({ reduced, ask }) {
  const chip = document.createElement('button');
  chip.type = 'button';
  chip.className = 'sel-ask';
  chip.innerHTML = '<span class="sel-ask__eyes" aria-hidden="true"><i></i><i></i></span>Ask Perry';
  chip.hidden = true;
  document.body.append(chip);
  chip.addEventListener('pointerdown', (e) => e.preventDefault());
  chip.addEventListener('click', () => { getSelection().removeAllRanges(); ask(); });

  let range = null, at = 0, fade = null, settle = 0, last = null;

  function pick() {
    const s = getSelection();
    if (!s.rangeCount || s.isCollapsed) return null;
    const r = s.getRangeAt(0);
    const host = r.commonAncestorContainer.nodeType === 1 ? r.commonAncestorContainer : r.commonAncestorContainer.parentElement;
    if (!host?.closest('main') || host.closest('.notch, dialog, input, textarea, .win')) return null;
    if (s.toString().trim().length < 2) return null;
    return r.cloneRange();
  }

  document.addEventListener('selectionchange', () => {
    clearTimeout(settle);
    settle = setTimeout(() => {
      const next = pick();
      if (!next) { if (range) { fade = { at: performance.now() / 1000, from: last }; range = null; chip.hidden = true; } return; }
      const same = range && range.compareBoundaryPoints(Range.START_TO_START, next) === 0 && range.compareBoundaryPoints(Range.END_TO_END, next) === 0;
      if (same) return;
      range = next; at = performance.now() / 1000; fade = null;
      sound.play('scribble');
    }, 260);
  });

  function geometry() {
    const rects = [...range.getClientRects()].filter((b) => b.width > 1);
    if (!rects.length) return null;
    const l = Math.min(...rects.map((b) => b.left)), t = Math.min(...rects.map((b) => b.top));
    const r = Math.max(...rects.map((b) => b.right)), b = Math.max(...rects.map((b) => b.bottom));
    const lines = new Set(rects.map((b) => Math.round(b.top / 6))).size;
    const box = { left: l, top: t, right: r, bottom: b, width: r - l, height: b - t };
    return { m: mark(box, lines > 1 || box.width > innerWidth * 0.7), end: rects[rects.length - 1] };
  }

  return {
    get focus() {
      return range && last ? { x: last.cx, y: last.cy } : null;
    },
    update(t, ink) {
      const R = Math.max(1.6, Math.min(2.3, innerWidth * 0.0016)) * 1.1;
      if (fade) {
        const u = reduced ? 1 : clamp01((t - fade.at) / 0.35);
        if (u >= 1 || !fade.from) { fade = null; last = null; return; }
        const { tip, cx, cy, side, ...geo } = fade.from;
        drawMark(ink, { ...geo, seed: 0.3, progress: 1 - smooth(u) }, R);
        return;
      }
      if (!range) return;
      const g = geometry();
      if (!g) return;
      last = g.m;
      const { tip, cx, cy, side, ...geo } = g.m;
      drawMark(ink, { ...geo, seed: 0.3, progress: reduced ? 1 : smooth(clamp01((t - at) / 0.6)) }, R);
      const show = reduced || t - at > 0.45;
      if (chip.hidden === show) chip.hidden = !show;
      const below = g.m.kind === 'box' ? g.m.y + g.m.h : g.m.y + g.m.ry;
      const x = Math.max(12, Math.min(innerWidth - 140, g.end.right - 40));
      const y = Math.min(innerHeight - 48, below + 10);
      chip.style.transform = `translate(${x.toFixed(1)}px, ${y.toFixed(1)}px)`;
    },
  };
}
