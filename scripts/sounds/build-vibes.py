import math, re, sys
from pathlib import Path
import numpy as np
import soundfile as sf
import soxr
import pyloudnorm as pyln
from scipy.signal import butter, sosfilt

SR = 48000
SRC = Path(sys.argv[1])
OUT = Path(sys.argv[2])
NOTE = {"C": 0, "C#": 1, "D": 2, "D#": 3, "E": 4, "F": 5, "F#": 6, "G": 7, "G#": 8, "A": 9, "A#": 10, "B": 11}


def midi(name):
    m = re.fullmatch(r"([A-G]#?)(-?\d)", name)
    return 12 * (int(m.group(2)) + 1) + NOTE[m.group(1)]


def hz(m):
    return 440.0 * 2 ** ((m - 69) / 12)


def index(pattern):
    return [(midi(m.group(1)) + 12, p) for p in sorted(SRC.glob("Vibes_*.wav")) if (m := re.fullmatch(pattern, p.name))]


FAMILIES = {
    "soft": index(r"Vibes_soft_([A-G]#?\d)_v1_rr\d_Main\.wav"),
    "hard": index(r"Vibes_hard_([A-G]#?\d)_v2_rr\d_Main\.wav"),
}


def load(path):
    x, sr = sf.read(path, always_2d=True)
    if x.shape[1] == 1:
        x = np.repeat(x, 2, axis=1)
    x = soxr.resample(x, sr, SR)
    mono = x.mean(axis=1)
    on = int(np.argmax(np.abs(mono) > np.max(np.abs(mono)) * 0.01))
    return x[max(0, on - int(0.003 * SR)):]


def f0(x, nominal):
    seg = x.mean(axis=1)[int(0.04 * SR):int(0.30 * SR)]
    seg = seg * np.hanning(len(seg))
    n = 1 << 18
    spec = np.abs(np.fft.rfft(seg, n))
    freqs = np.fft.rfftfreq(n, 1 / SR)
    band = np.where((freqs > nominal * 2 ** (-0.7 / 12)) & (freqs < nominal * 2 ** (0.7 / 12)))[0]
    i = band[np.argmax(spec[band])]
    a, b, c = np.log(spec[i - 1:i + 2] + 1e-12)
    return (i + 0.5 * (a - c) / (a - 2 * b + c)) * SR / n


CACHE = {}


def note(family, name):
    key = (family, name)
    if key not in CACHE:
        target = midi(name)
        m, path = min(FAMILIES[family], key=lambda s: abs(s[0] - target))
        assert abs(m - target) <= 4, (family, name, path.name)
        x = load(path)
        y = soxr.resample(x, SR * hz(target) / f0(x, hz(m)), SR)
        cents = 1200 * math.log2(f0(y, hz(target)) / hz(target))
        assert abs(cents) < 3, (family, name, cents)
        CACHE[key] = (y, path.name)
    return CACHE[key]


def octave_down(name):
    m = re.fullmatch(r"([A-G]#?)(-?\d)", name)
    return f"{m.group(1)}{int(m.group(2)) - 1}"


def fade(y, length, tail):
    n = min(len(y), int(length * SR))
    y = y[:n].copy()
    f = min(n, int(tail * SR))
    y[n - f:] *= (0.5 * (1 + np.cos(np.linspace(0, math.pi, f))))[:, None]
    return y


def render(events, hard_db, body_db, scale, room_db):
    total = max(t * scale + length * scale for t, _, _, length in events) + 0.01
    out = np.zeros((int(total * SR), 2))
    sources = set()
    for t, name, gain, length in events:
        layers = [("soft", name, 0.0)]
        if hard_db is not None:
            layers.append(("hard", name, hard_db))
        if body_db is not None and (t, name) == (events[-1][0], events[-1][1]):
            layers.append(("soft", octave_down(name), body_db))
        for family, n, g in layers:
            y, src = note(family, n)
            sources.add(src)
            y = fade(y, length * scale, length * scale * 0.7) * 10 ** ((gain + g) / 20)
            i = int(t * scale * SR)
            out[i:i + len(y)] += y[:len(out) - i]
    out = sosfilt(butter(2, 70, "highpass", fs=SR, output="sos"), out, axis=0)
    out = gate(out)
    if room_db is not None:
        out = np.concatenate([out, np.zeros((int(0.25 * SR), 2))])
        wet = np.stack([np.convolve(out[:, c], IR[:, c])[:len(out)] for c in range(2)], axis=1)
        out = out + wet * 10 ** (room_db / 20)
        out = fade(out, len(out) / SR, 0.2)
    return out, sorted(sources)


def gate(x):
    env = np.sqrt(sosfilt(butter(1, 30, "lowpass", fs=SR, output="sos"), x.mean(axis=1) ** 2))
    rel = 20 * np.log10(env / env.max() + 1e-12)
    gain = np.clip((rel + 62) / 14, 0, 1)
    return x * gain[:, None]


def room():
    rng = np.random.default_rng(7)
    n = int(0.45 * SR)
    t = np.arange(n) / SR
    ir = rng.standard_normal((n, 2)) * np.exp(-6.9 * t / 0.35)[:, None]
    ir[:int(0.008 * SR)] = 0
    ir = sosfilt(butter(2, [300, 6000], "bandpass", fs=SR, output="sos"), ir, axis=0)
    return ir / np.sqrt(np.sum(ir ** 2, axis=0))


IR = room()


PLAN = {
    "wake": [(0, "E5", -5, 0.22), (0.045, "G5", 0, 0.42)],
    "send": [(0, "E6", 0, 0.22)],
    "receive": [(0, "G5", 0, 0.24), (0.10, "E5", -1, 0.55)],
    "done": [(0, "C5", -4, 0.20), (0.05, "E5", -3, 0.20), (0.10, "G5", 0, 0.75)],
    "fail": [(0, "F4", 0, 0.26), (0.13, "D4", -1, 0.55)],
}
LEVEL = {"wake": -24.0, "send": -29.0, "receive": -22.0, "done": -22.0, "fail": -23.0}
meter = pyln.Meter(SR, block_size=0.1)

OUT.mkdir(parents=True, exist_ok=True)
for cue, events in PLAN.items():
    y, sources = render(events, None, -10, 0.75, -20)
    y *= 10 ** ((LEVEL[cue] - meter.integrated_loudness(np.concatenate([y, np.zeros((int(0.2 * SR), 2))]))) / 20)
    peak = np.max(np.abs(y))
    if peak > 10 ** (-3 / 20):
        y *= 10 ** (-3 / 20) / peak
    sf.write(OUT / f"{cue}.wav", y.astype(np.float32), SR, subtype="PCM_24")
    print(cue, sources)
