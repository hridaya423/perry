// One ink for the whole page: dabs are splatted into an additive metaball field,
// then a composite pass turns the field into wet brush ink on paper.
// Falls back to a Canvas2D circle union when WebGL2 is unavailable.

export const THRESHOLD = 0.494;
export const INFLUENCE = 1.35; // dab field reaches this many radii
// Weight that puts the edge of a long straight stroke exactly at the dab radius.
const K = INFLUENCE * (16 / 15) * Math.pow(1 - 1 / (INFLUENCE * INFLUENCE), 2.5);
export const strokeWeight = (spacing, r) => (THRESHOLD / K) * (spacing / r);
const FLOATS = 8; // x, y, R, weight, ink, guide, wet, unused
const MAX_DABS = 16000;
export const MAX_EYES = 4;

const VERT_DAB = `#version 300 es
layout(location=0) in vec2 corner;
layout(location=1) in vec4 a;      // x, y, influence radius, weight
layout(location=2) in vec4 b;      // ink, guide, wet, -
uniform vec2 uRes;
out vec2 vLocal; out vec4 vB; out float vW;
void main(){
  vLocal = corner; vB = b; vW = a.w;
  vec2 p = a.xy + corner * a.z;
  gl_Position = vec4(p / uRes * 2.0 - 1.0, 0.0, 1.0);
  gl_Position.y = -gl_Position.y;
}`;

const FRAG_DAB = `#version 300 es
precision highp float;
in vec2 vLocal; in vec4 vB; in float vW;
out vec4 o;
void main(){
  float d2 = dot(vLocal, vLocal);
  if (d2 >= 1.0) discard;
  float f = (1.0 - d2); f *= f; f *= vW;
  o = vec4(f * vB.x, f * vB.y, f * vB.z, 0.0);
}`;

const VERT_FULL = `#version 300 es
const vec2 P[3] = vec2[3](vec2(-1.,-1.), vec2(3.,-1.), vec2(-1.,3.));
void main(){ gl_Position = vec4(P[gl_VertexID], 0., 1.); }`;

const FRAG_COMP = `#version 300 es
precision highp float;
#define OCT __OCT__
uniform sampler2D uField;
uniform vec2 uRes;
uniform float uScale;       // field scale (FBO px per css px * dpr)
uniform float uT;
uniform float uFieldMul;    // 1/encode scale
uniform vec3 uInk, uGuide, uEmber;
uniform float uNight;
uniform vec4 uEye[${MAX_EYES}];    // cx, cy, rx, ry (device px)
uniform vec4 uEyeS[${MAX_EYES}];   // open, pupilX, pupilY, pupilScale (pupil offsets in device px)
uniform vec4 uEyeM[${MAX_EYES}];   // squint, glow, angle, enabled
out vec4 o;

float h21(vec2 p){ p = fract(p * vec2(123.34, 456.21)); p += dot(p, p + 45.32); return fract(p.x * p.y); }
float vnoise(vec2 p){
  vec2 i = floor(p), f = fract(p); f = f * f * f * (f * (f * 6. - 15.) + 10.);
  return mix(mix(h21(i), h21(i + vec2(1,0)), f.x), mix(h21(i + vec2(0,1)), h21(i + vec2(1,1)), f.x), f.y);
}
float fbm(vec2 p){ float s = 0., a = .5; for (int i = 0; i < OCT; i++){ s += a * vnoise(p); p = p * 2.03 + 17.1; a *= .5; } return s; }

void main(){
  vec2 px = gl_FragCoord.xy; px.y = uRes.y - px.y;
  vec2 uv = px / uRes;
  vec4 F = texture(uField, vec2(uv.x, 1.0 - uv.y)) * uFieldMul;
  float fi = F.r, fg = F.g;
  float s = uScale;
  // fibre noise roughens the edge like ink catching paper tooth
  float n1 = fbm(px / (9.0 * s));
  float n2 = vnoise(px / (3.4 * s));
  float rough = (n1 - .5) * .1 + (n2 - .5) * .03;
  float gi = length(vec2(dFdx(fi), dFdy(fi)));
  float gg = length(vec2(dFdx(fg), dFdy(fg)));
  float ei = fi + rough * gi * 7.0 * s;
  float eg = fg + rough * gg * 7.0 * s;
  float wi = max(fwidth(ei) * .85, .002);
  float wg = max(fwidth(eg) * .85, .002);
  float ai = smoothstep(uT - wi, uT + wi, ei);
  float ag = smoothstep(uT - wg, uT + wg, eg);

  // ink body: pooled darker rim, slightly lifted granular interior
  float rim = 1.0 - smoothstep(uT, uT * 1.9, fi);
  float gran = fbm(px / (2.4 * s) + 9.0);
  float lift = (1.0 - rim) * (.06 + .05 * gran) * (1.0 - uNight);
  vec3 ink = mix(uInk, uInk + vec3(.09, .085, .07), lift);
  ink = mix(ink, uInk * .7, rim * .5 * (1.0 - uNight));

  // wet sheen from field gradient, light from upper left
  float wet = clamp(F.b / max(fi, 1e-3), 0., 1.) * ai;
  vec2 g = vec2(dFdx(fi), dFdy(fi)) / max(s, .5);
  vec3 nrm = normalize(vec3(-g * 26.0, 1.0));
  float spec = pow(max(dot(nrm, normalize(vec3(-.55, -.65, .55))), 0.), 40.) * wet;
  ink = mix(ink, uInk * .55, wet * .5 * (1.0 - uNight));
  ink += spec * .32 * (.25 + .75 * rim);

  vec3 col = ink; float a = ai;
  col = mix(col, uGuide * (1.0 - rim * .25), ag * (1.0 - ai * .0));
  a = max(a, ag);

  // eyes cut into the ink: paper by day, ember by night
  for (int k = 0; k < ${MAX_EYES}; k++){
    vec4 E = uEye[k]; vec4 S = uEyeS[k]; vec4 M = uEyeM[k];
    if (M.w < .5) continue;
    bool cap = M.w > 1.5;
    vec2 d = px - E.xy - (cap ? S.yz : vec2(0.));
    float ca = cos(M.z), sa = sin(M.z);
    d = vec2(ca * d.x + sa * d.y, -sa * d.x + ca * d.y);
    float wob = (vnoise(d / (E.z * .5) + float(k) * 7.) - .5) * .05;
    float open = max(S.x, .0);
    // lids: top lid comes down; squint pushes the lower lid up into a smile curve
    vec2 q = d / E.zw;
    float ell = length(q) - 1.0 + wob;
    if (cap) { vec2 dc = vec2(d.x, d.y / max(open, .06)); ell = (length(vec2(dc.x, max(abs(dc.y) - (E.w - E.z), 0.))) - E.z) / E.z + wob * .4; }
    float lidTop = -1.0 + 2.0 * (1.0 - open) + .32 * q.x * q.x * (1.0 - open) * step(.05, 1.0 - open);
    float smileLid = 1.0 - M.x * (1.25 - .55 * q.x * q.x);
    float inside = step(ell, 0.) * step(lidTop, q.y) * step(q.y, smileLid);
    float aa = 1.2 / (cap ? E.z : E.w);
    inside = smoothstep(aa, -aa, ell) * (cap ? step(.04, open) : smoothstep(-aa, aa, q.y - lidTop)) * smoothstep(-aa, aa, smileLid - q.y);
    vec2 pd = (d - S.yz) / (E.zw * .52 * S.w);
    float pupil = cap ? 0. : smoothstep(1.0 + aa * 2., 1.0 - aa * 2., length(pd));
    vec2 hd = (d - S.yz - E.zw * vec2(.2, -.24) * S.w) / (E.w * .13);
    float shine = smoothstep(1.1, .8, length(hd));
    float white = inside * (1.0 - pupil * .985) + inside * pupil * shine;
    float glow = M.y;
    // day: punch to paper. night: ember light.
    vec3 emberC = uEmber;
    col = mix(col, emberC, white * glow);
    a = mix(a, glow > .5 ? 1.0 : 0.0, white);
    // halo around lit eyes
    float halo = exp(-max(ell, 0.) * 2.2) * glow * uNight * .55 * open;
    col = mix(col, uGuide, halo * .7 * (1.0 - inside) * a);
    // pupils stay ink inside the cut
    col = mix(col, uInk * (1. - uNight) + vec3(.05, .03, .02) * uNight, inside * pupil * (1.0 - shine));
    a = max(a, inside * pupil * (1.0 - shine));
  }
  o = vec4(col * a, a);
}`;

function compile(gl, type, src) {
  const s = gl.createShader(type);
  gl.shaderSource(s, src);
  gl.compileShader(s);
  if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s));
  return s;
}
function program(gl, vs, fs) {
  const p = gl.createProgram();
  gl.attachShader(p, compile(gl, gl.VERTEX_SHADER, vs));
  gl.attachShader(p, compile(gl, gl.FRAGMENT_SHADER, fs));
  gl.linkProgram(p);
  if (!gl.getProgramParameter(p, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(p));
  return p;
}

const hex = (h) => [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16) / 255);

export class Ink {
  constructor(canvas, { dprCap = 1.75, low = false } = {}) {
    this.low = low;
    this.canvas = canvas;
    this.dprCap = dprCap;
    this.data = new Float32Array(MAX_DABS * FLOATS);
    this.count = 0;
    this.eyes = [];
    this.night = 0;
    this.onDark = false;
    this.colors = { ink: hex('#1c1e1b'), guide: hex('#3c7765'), guideOnDark: hex('#9ccbb6'), ember: hex('#f4f1e8'), ivory: hex('#f3f0e8') };
    try { this.initGL(); } catch (e) { console.warn('ink: falling back to 2D', e); this.gl = null; this.init2D(); }
    this.resize();
  }

  initGL() {
    const gl = this.canvas.getContext('webgl2', { premultipliedAlpha: true, antialias: false, alpha: true });
    if (!gl) throw new Error('no webgl2');
    this.gl = gl;
    this.half = !!gl.getExtension('EXT_color_buffer_float') || !!gl.getExtension('EXT_color_buffer_half_float');
    this.encode = this.half ? 1 : 0.125;
    this.pDab = program(gl, VERT_DAB, FRAG_DAB);
    this.pComp = program(gl, VERT_FULL, FRAG_COMP.replace('__OCT__', this.low ? '2' : '4'));
    this.vao = gl.createVertexArray();
    gl.bindVertexArray(this.vao);
    const quad = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, quad);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW);
    gl.enableVertexAttribArray(0);
    gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
    this.inst = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, this.inst);
    gl.bufferData(gl.ARRAY_BUFFER, this.data.byteLength, gl.DYNAMIC_DRAW);
    gl.enableVertexAttribArray(1);
    gl.vertexAttribPointer(1, 4, gl.FLOAT, false, FLOATS * 4, 0);
    gl.vertexAttribDivisor(1, 1);
    gl.enableVertexAttribArray(2);
    gl.vertexAttribPointer(2, 4, gl.FLOAT, false, FLOATS * 4, 16);
    gl.vertexAttribDivisor(2, 1);
    gl.bindVertexArray(null);
    this.u = {};
    for (const n of ['uField', 'uRes', 'uScale', 'uT', 'uFieldMul', 'uInk', 'uGuide', 'uEmber', 'uNight', 'uEye', 'uEyeS', 'uEyeM']) {
      this.u[n] = gl.getUniformLocation(this.pComp, n.startsWith('uEye') ? `${n}[0]` : n);
    }
    this.uDabRes = gl.getUniformLocation(this.pDab, 'uRes');
    this.tex = gl.createTexture();
    this.fbo = gl.createFramebuffer();
    canvas_lost(this.canvas, () => { this.lost = true; });
  }

  init2D() { this.ctx = this.canvas.getContext('2d'); }

  resize() {
    const dpr = Math.min(window.devicePixelRatio || 1, this.dprCap);
    const w = Math.max(1, Math.round(this.canvas.clientWidth * dpr));
    const h = Math.max(1, Math.round(this.canvas.clientHeight * dpr));
    this.dpr = dpr;
    if (this.canvas.width === w && this.canvas.height === h) return;
    this.canvas.width = w; this.canvas.height = h;
    const gl = this.gl;
    if (!gl) return;
    gl.bindTexture(gl.TEXTURE_2D, this.tex);
    if (this.half) gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA16F, w, h, 0, gl.RGBA, gl.HALF_FLOAT, null);
    else gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, w, h, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.bindFramebuffer(gl.FRAMEBUFFER, this.fbo);
    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, this.tex, 0);
    gl.bindFramebuffer(gl.FRAMEBUFFER, null);
  }

  begin() { this.count = 0; this.eyes.length = 0; }

  // x, y, r in CSS px. weight: spacing / r for strokes. ink/guide channel weights, wet 0..1
  dab(x, y, r, weight, guide = 0, wet = 0) {
    if (this.count >= MAX_DABS || r <= 0.05) return;
    const o = this.count++ * FLOATS, d = this.data;
    d[o] = x; d[o + 1] = y; d[o + 2] = r * INFLUENCE; d[o + 3] = weight;
    d[o + 4] = guide ? 0 : 1; d[o + 5] = guide ? 1 : 0; d[o + 6] = wet; d[o + 7] = r;
  }

  // eye: {x, y, rx, ry, open, px, py, ps, squint, glow, angle}
  eye(e) { if (this.eyes.length < MAX_EYES) this.eyes.push(e); }

  render() {
    if (this.gl) this.renderGL(); else this.render2D();
  }

  renderGL() {
    const gl = this.gl, dpr = this.dpr, W = this.canvas.width, H = this.canvas.height;
    if (this.lost) return;
    const d = this.data;
    for (let i = 0; i < this.count; i++) {
      const o = i * FLOATS;
      d[o] *= dpr; d[o + 1] *= dpr; d[o + 2] *= dpr; d[o + 3] *= this.encode;
    }
    gl.bindFramebuffer(gl.FRAMEBUFFER, this.fbo);
    gl.viewport(0, 0, W, H);
    gl.clearColor(0, 0, 0, 0);
    gl.clear(gl.COLOR_BUFFER_BIT);
    if (this.count) {
      gl.useProgram(this.pDab);
      gl.uniform2f(this.uDabRes, W, H);
      gl.enable(gl.BLEND);
      gl.blendFunc(gl.ONE, gl.ONE);
      gl.bindVertexArray(this.vao);
      gl.bindBuffer(gl.ARRAY_BUFFER, this.inst);
      gl.bufferSubData(gl.ARRAY_BUFFER, 0, d, 0, this.count * FLOATS);
      gl.drawArraysInstanced(gl.TRIANGLE_STRIP, 0, 4, this.count);
      gl.bindVertexArray(null);
    }
    gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    gl.viewport(0, 0, W, H);
    gl.disable(gl.BLEND);
    gl.clear(gl.COLOR_BUFFER_BIT);
    gl.useProgram(this.pComp);
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, this.tex);
    gl.uniform1i(this.u.uField, 0);
    gl.uniform2f(this.u.uRes, W, H);
    gl.uniform1f(this.u.uScale, dpr);
    gl.uniform1f(this.u.uT, THRESHOLD);
    gl.uniform1f(this.u.uFieldMul, 1 / this.encode);
    const c = this.colors, n = this.night;
    const ink = c.ink.map((v, i) => v + (c.ivory[i] - v) * n);
    gl.uniform3fv(this.u.uInk, ink);
    gl.uniform3fv(this.u.uGuide, this.onDark ? c.guideOnDark : c.guide);
    gl.uniform3fv(this.u.uEmber, c.ember);
    gl.uniform1f(this.u.uNight, n);
    const E = new Float32Array(MAX_EYES * 4), S = new Float32Array(MAX_EYES * 4), M = new Float32Array(MAX_EYES * 4);
    this.eyes.forEach((e, k) => {
      E.set([e.x * dpr, e.y * dpr, e.rx * dpr, e.ry * dpr], k * 4);
      S.set([e.open, e.px * dpr, e.py * dpr, e.ps], k * 4);
      M.set([e.squint || 0, e.glow || 0, e.angle || 0, e.capsule ? 2 : 1], k * 4);
    });
    gl.uniform4fv(this.u.uEye, E);
    gl.uniform4fv(this.u.uEyeS, S);
    gl.uniform4fv(this.u.uEyeM, M);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
  }

  render2D() {
    const ctx = this.ctx, dpr = this.dpr, d = this.data;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, this.canvas.width, this.canvas.height);
    const c = this.colors, n = this.night;
    const rgb = (a) => `rgb(${a.map((v) => Math.round(v * 255)).join(',')})`;
    const ink = rgb(c.ink.map((v, i) => v + (c.ivory[i] - v) * n));
    for (let i = 0; i < this.count; i++) {
      const o = i * FLOATS;
      ctx.fillStyle = d[o + 5] > 0.5 ? rgb(this.onDark ? c.guideOnDark : c.guide) : ink;
      ctx.beginPath();
      ctx.arc(d[o], d[o + 1], d[o + 7] * 0.98, 0, Math.PI * 2);
      ctx.fill();
    }
    for (const e of this.eyes) {
      ctx.save();
      ctx.translate(e.x, e.y);
      ctx.rotate(e.angle || 0);
      ctx.beginPath();
      ctx.ellipse(0, 0, e.rx, e.ry * Math.max(e.open, 0.06), 0, 0, Math.PI * 2);
      ctx.globalCompositeOperation = n > 0.5 ? 'source-over' : 'destination-out';
      ctx.fillStyle = n > 0.5 ? rgb(c.ember) : '#000';
      ctx.fill();
      ctx.globalCompositeOperation = 'source-over';
      if (e.open > 0.25) {
        ctx.beginPath();
        ctx.ellipse(e.px, e.py, e.rx * 0.52 * e.ps, e.ry * 0.52 * e.ps * Math.min(1, e.open * 1.4), 0, 0, Math.PI * 2);
        ctx.fillStyle = n > 0.5 ? '#1a1208' : ink;
        ctx.fill();
      }
      ctx.restore();
    }
  }
}

function canvas_lost(canvas, cb) {
  canvas.addEventListener('webglcontextlost', (e) => { e.preventDefault(); cb(); });
}
