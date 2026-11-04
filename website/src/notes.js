import { drawMark } from './ink/actors.js';
import { drawWriting, writing } from './ink/hand.js';

const clamp01 = (v) => (v < 0 ? 0 : v > 1 ? 1 : v);

export function createNotes({ reduced }) {
  const notes = [
    {
      text: "it's free & oss :)",
      place(c) {
        const r = c.cta;
        if (!r) return null;
        const x = r.right + 40, y = r.top + r.height * 0.36;
        const w = writing(this.text, c.size, c.R).width;
        if (x + w > innerWidth - 16) return { marks: [], x: r.left + (r.width - w) / 2, y: r.bottom + c.size * 1.05 };
        return { marks: [{ kind: 'arrow', x0: x + c.size * 1.25, y0: y + c.size * 0.42, x1: r.right + 14, y1: r.top + r.height * 0.6, bend: -0.42 }], x, y, after: true };
      },
    },
  ];
  for (const n of notes) n.at = -1;

  return {
    update(t, ink, c) {
      c.size = Math.max(42, Math.min(60, innerWidth * 0.038));
      c.R = Math.max(1.6, Math.min(2.3, innerWidth * 0.0016));
      for (const n of notes) {
        const g = n.place(c);
        if (!g) continue;
        if (n.at < 0) n.at = t;
        const since = reduced ? 99 : t - n.at;
        const { length } = writing(n.text, c.size, c.R);
        const writeFor = 0.35 + length / 1100;
        const markFor = 0.45;
        const writeAt = g.after ? 0.1 : g.marks.length * markFor * 0.8;
        g.marks.forEach((m, i) => {
          const start = g.after ? writeAt + writeFor + i * markFor : i * markFor * 0.8;
          drawMark(ink, { ...m, progress: clamp01((since - start) / markFor) }, c.R * 1.15);
        });
        drawWriting(ink, { text: n.text, x: g.x, y: g.y, size: c.size, progress: (since - writeAt) / writeFor }, c.R);
      }
    },
  };
}
