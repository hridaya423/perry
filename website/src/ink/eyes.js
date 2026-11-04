// A pair of eyes that act: saccades toward an aim point, blinks, moods.
// Positions are CSS px. Output pupil offsets are fractions of the eye radii.

const rand = (a, b) => a + Math.random() * (b - a);
const approach = (v, to, k) => v + (to - v) * k;

export class Eyes {
  constructor() {
    this.aim = { x: 0, y: 0 };
    this.target = { x: 0, y: 0 };
    this.open = 0;          // drawn lid opening
    this.openBase = 1;      // mood: 1 awake, ~0.5 sleepy
    this.squint = 0;
    this.squintTo = 0;
    this.ps = 1;
    this.psTo = 1;
    this.blinkAt = 1.2;
    this.blink = -1;        // seconds into a blink, -1 idle
    this.awake = true;
    this.last = 0;
    this.changed = true;
  }

  lookAt(x, y) { this.target.x = x; this.target.y = y; }
  mood({ squint = 0, ps = 1, open = 1 } = {}) { this.squintTo = squint; this.psTo = ps; this.openBase = open; }
  blinkNow(double = false) { this.blink = 0; this.double = double; }

  update(t, dt) {
    const before = this.aim.x + this.aim.y * 7 + this.open * 13 + this.squint * 17 + this.ps * 19;
    // saccade: big jumps snap, small drift glides
    const dx = this.target.x - this.aim.x, dy = this.target.y - this.aim.y;
    const far = Math.hypot(dx, dy) > 40;
    const k = 1 - Math.exp(-dt * (far ? 26 : 9));
    this.aim.x += dx * k; this.aim.y += dy * k;

    if (this.blink < 0 && t > this.blinkAt) { this.blink = 0; this.double = Math.random() < 0.18; }
    let lid = 1;
    if (this.blink >= 0) {
      this.blink += dt;
      const b = this.blink, dur = 0.17;
      lid = b < dur * 0.4 ? 1 - b / (dur * 0.4) : b < dur ? (b - dur * 0.4) / (dur * 0.6) : 1;
      if (b >= dur) {
        if (this.double) { this.double = false; this.blink = -0.06 + 0; this.blink = 0; this.blinkAt = t; }
        else { this.blink = -1; this.blinkAt = t + rand(2.4, 5.6); }
        lid = 1;
      }
    }
    this.squint = approach(this.squint, this.squintTo, 1 - Math.exp(-dt * 12));
    this.ps = approach(this.ps, this.psTo, 1 - Math.exp(-dt * 8));
    const openTarget = this.awake ? this.openBase : 0;
    this.lidBase = approach(this.lidBase ?? 0, openTarget, 1 - Math.exp(-dt * 10));
    this.open = this.lidBase * lid;
    const after = this.aim.x + this.aim.y * 7 + this.open * 13 + this.squint * 17 + this.ps * 19;
    this.changed = Math.abs(after - before) > 0.002;
    return this.changed;
  }

  // Pupil offset for an eye at (cx, cy) with radii (rx, ry), as px.
  pupil(cx, cy, rx, ry, reach = 0.42) {
    const vx = this.aim.x - cx, vy = this.aim.y - cy;
    const d = Math.hypot(vx, vy);
    const s = d / (d + Math.max(rx, ry) * 5);
    const nx = d ? vx / d : 0, ny = d ? vy / d : 0;
    return { x: nx * s * rx * reach, y: ny * s * ry * reach * 0.9 };
  }
}
