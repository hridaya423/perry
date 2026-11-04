// Note recipes from Bencho sounds (MIT, © 2026 Lorenzo Cabra); plop is rebuilt from cuelume
// (MIT, © 2026 Daniel Belyi). https://github.com/cabralorenzo/bencho/blob/main/sounds/sounds.ts

const SOUNDS = {
  plop: [
    { hz: 480, to: 300, glide: 18, ms: 23, gain: 0.064, atk: 1 },
    { hz: 600, to: 900, glide: 40, ms: 61, gain: 0.015, atk: 12 },
    { hz: 960, to: 600, glide: 18, ms: 18, gain: 0.016, atk: 1 },
  ],
  landed: [
    { hz: 330, to: 620, ms: 120, gain: 0.018, wave: 'triangle', cut: 1400, atk: 30 },
    { hz: 784, ms: 120, gain: 0.04, wave: 'sine', cut: 2600, atk: 4, at: 70 },
    { hz: 1047, ms: 130, gain: 0.04, wave: 'sine', cut: 2800, atk: 4, at: 140 },
    { hz: 1319, ms: 520, gain: 0.044, wave: 'sine', cut: 3000, atk: 5, at: 210 },
    { hz: 2638, ms: 320, gain: 0.007, wave: 'sine', atk: 8, at: 215 },
  ],
  wisp: [{ hz: 660, to: 720, ms: 38, gain: 0.028, wave: 'sine' }],
  hush: [{ hz: 330, to: 247, ms: 88, gain: 0.03, wave: 'sine', cut: 720, atk: 8 }],
  perk: [{ hz: 330, ms: 360, gain: 0.053, wave: 'sine', cut: 560, atk: 90 }],
  hail: [{ hz: 392, ms: 360, gain: 0.051, wave: 'sine', cut: 560, atk: 90 }],
  bump: [{ hz: 208, to: 165, ms: 120, gain: 0.03, wave: 'sine', cut: 520, atk: 10 }],
  latch: [{ hz: 256, ms: 90, gain: 0.058, wave: 'square', cut: 2400, atk: 10 }],
  tick: [{ hz: 196, to: 130, ms: 150, gain: 0.07, wave: 'sine', cut: 900 }],
  glide: [{ hz: 397, to: 276, ms: 205, gain: 0.065, wave: 'sine', cut: 820, atk: 90 }],
  clack: [
    { hz: 1900, ms: 22, gain: 0.05, noise: 'bandpass', q: 3, atk: 1 },
    { hz: 420, to: 300, ms: 40, gain: 0.03, wave: 'triangle', cut: 1600, atk: 1 },
  ],
  crinkle: Array.from({ length: 14 }, (_, i) => ({ hz: 2600 + ((i * 1777) % 3000), ms: 18 + ((i * 7) % 22), gain: 0.03 + ((i * 13) % 5) * 0.006, noise: 'bandpass', q: 1.4, atk: 1, at: i * 34 + ((i * 29) % 17) })),
  scribble: [
    { hz: 1800, to: 3400, ms: 300, gain: 0.018, noise: 'bandpass', q: 2.2, atk: 30 },
    { hz: 3000, to: 1700, ms: 320, gain: 0.016, noise: 'bandpass', q: 2.2, atk: 30, at: 290 },
  ],
};

const KEY = 'perry:sound';
let ctx = null, noise = null, on = false;
try { on = localStorage.getItem(KEY) === '1'; } catch {}
const listeners = new Set();

function noiseBuffer(c) {
  if (noise) return noise;
  noise = c.createBuffer(1, c.sampleRate * 2, c.sampleRate);
  const d = noise.getChannelData(0);
  for (let i = 0; i < d.length; i++) d[i] = Math.random() * 2 - 1;
  return noise;
}

function schedule(c, notes, when, volume, bend) {
  for (const n of notes) {
    const t0 = when + (n.at ?? 0) / 1000, t1 = t0 + n.ms / 1000, tg = n.glide ? t0 + n.glide / 1000 : t1;
    let src, head;
    if (n.noise) {
      src = c.createBufferSource();
      src.buffer = noiseBuffer(c);
      src.loop = true;
      head = c.createBiquadFilter();
      head.type = n.noise;
      head.frequency.setValueAtTime(n.hz * bend, t0);
      if (n.to) head.frequency.exponentialRampToValueAtTime(n.to * bend, tg);
      if (n.q !== undefined) head.Q.value = n.q;
      src.connect(head);
    } else {
      src = head = c.createOscillator();
      src.type = n.wave ?? 'sine';
      src.frequency.setValueAtTime(n.hz * bend, t0);
      if (n.to) src.frequency.exponentialRampToValueAtTime(n.to * bend, tg);
    }
    const g = c.createGain();
    const atk = Math.min((n.atk ?? 4) / 1000, (n.ms / 1000) * 0.6);
    g.gain.setValueAtTime(0.0001, t0);
    g.gain.exponentialRampToValueAtTime((n.gain ?? 0.05) * volume, t0 + atk);
    g.gain.exponentialRampToValueAtTime(0.0001, t1);
    let tail = head;
    if (n.cut) { tail = c.createBiquadFilter(); tail.type = 'lowpass'; tail.frequency.value = n.cut; head.connect(tail); }
    tail.connect(g).connect(c.destination);
    if (n.noise) src.start(t0, Math.random() * 1.5); else src.start(t0);
    src.stop(t1 + 0.02);
  }
}

export const sound = {
  get on() { return on; },
  set(v) {
    on = v;
    try { localStorage.setItem(KEY, v ? '1' : '0'); } catch {}
    listeners.forEach((f) => f(on));
  },
  watch(f) { listeners.add(f); f(on); },
  play(name, { volume = 1, pitch = 1, delay = 0 } = {}) {
    if (!on || document.hidden) return;
    ctx ??= new AudioContext();
    if (ctx.state === 'suspended') ctx.resume();
    schedule(ctx, SOUNDS[name], ctx.currentTime + 0.005 + delay, volume, pitch);
  },
};
