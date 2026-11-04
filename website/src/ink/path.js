// Minimal SVG path sampler (absolute M, L, C, Q only) and brush-dab generation.

const lerp = (a, b, t) => a + (b - a) * t;

function parse(d) {
  const tokens = d.match(/[MLCQ]|-?\d*\.?\d+(?:e-?\d+)?/gi);
  const segs = [];
  let cmd = null, i = 0, cx = 0, cy = 0, sx = 0, sy = 0;
  const num = () => parseFloat(tokens[i++]);
  while (i < tokens.length) {
    if (/[MLCQ]/i.test(tokens[i])) cmd = tokens[i++].toUpperCase();
    if (cmd === 'M') { cx = sx = num(); cy = sy = num(); cmd = 'L'; continue; }
    if (cmd === 'L') { const x = num(), y = num(); segs.push([cx, cy, cx, cy, x, y, x, y]); cx = x; cy = y; }
    else if (cmd === 'C') { const a = [num(), num(), num(), num(), num(), num()]; segs.push([cx, cy, ...a]); cx = a[4]; cy = a[5]; }
    else if (cmd === 'Q') {
      const qx = num(), qy = num(), x = num(), y = num();
      segs.push([cx, cy, cx + (2 / 3) * (qx - cx), cy + (2 / 3) * (qy - cy), x + (2 / 3) * (qx - x), y + (2 / 3) * (qy - y), x, y]);
      cx = x; cy = y;
    }
  }
  void sx; void sy;
  return segs;
}

function bez(s, t) {
  const u = 1 - t;
  return [
    u * u * u * s[0] + 3 * u * u * t * s[2] + 3 * u * t * t * s[4] + t * t * t * s[6],
    u * u * u * s[1] + 3 * u * u * t * s[3] + 3 * u * t * t * s[5] + t * t * t * s[7],
  ];
}

// Returns evenly spaced points [{x, y, u}] along the path, spacing in path units.
export function samplePath(d, spacing) {
  const fine = [];
  for (const s of parse(d)) for (let k = fine.length ? 1 : 0; k <= 40; k++) fine.push(bez(s, k / 40));
  const cum = [0];
  for (let k = 1; k < fine.length; k++) cum.push(cum[k - 1] + Math.hypot(fine[k][0] - fine[k - 1][0], fine[k][1] - fine[k - 1][1]));
  const total = cum[cum.length - 1];
  const n = Math.max(2, Math.ceil(total / spacing) + 1);
  const out = [];
  let j = 0;
  for (let k = 0; k < n; k++) {
    const L = (k / (n - 1)) * total;
    while (j < cum.length - 2 && cum[j + 1] < L) j++;
    const t = cum[j + 1] === cum[j] ? 0 : (L - cum[j]) / (cum[j + 1] - cum[j]);
    out.push({ x: lerp(fine[j][0], fine[j + 1][0], t), y: lerp(fine[j][1], fine[j + 1][1], t), u: k / (n - 1) });
  }
  return { points: out, length: total };
}

// Piecewise-linear pressure profile: [[u, k], ...]
export function profileAt(profile, u) {
  if (!profile) return 1;
  if (u <= profile[0][0]) return profile[0][1];
  for (let i = 1; i < profile.length; i++) {
    if (u <= profile[i][0]) {
      const [u0, k0] = profile[i - 1], [u1, k1] = profile[i];
      const t = (u - u0) / (u1 - u0);
      return lerp(k0, k1, t * t * (3 - 2 * t));
    }
  }
  return profile[profile.length - 1][1];
}

// A stroke becomes dabs: {x, y, r, u} in its own units.
export function strokeDabs(stroke, radius, spacingRatio = 0.22) {
  const spacing = radius * spacingRatio;
  const { points, length } = samplePath(stroke.d, spacing);
  return {
    length,
    dabs: points.map((p) => ({ x: p.x, y: p.y, u: p.u, r: radius * profileAt(stroke.p, p.u) })),
  };
}
