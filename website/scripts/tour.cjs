// Screenshot the site at scroll positions. Usage: node scripts/tour.cjs <outdir> [w] [h] [reduced]
// Positions are "selector@fraction" of that element's scrollable span, or plain px.
const { chromium } = require(process.env.PW || '/Users/hridyaagrawal/Honey/silk-reel/node_modules/playwright');
const fs = require('node:fs');

const STOPS = (process.env.STOPS || 'hero@0,hero@0.3,hero@0.55,hero@0.95,.statement@0.5,stage@0.03,stage@0.12,stage@0.18,stage@0.3,stage@0.36,stage@0.42,stage@0.47,stage@0.52,stage@0.56,stage@0.6,stage@0.7,stage@0.75,stage@0.78,stage@0.82,stage@0.86,stage@0.88,stage@0.92,stage@0.97,.privacy@0.2,.privacy@0.6,night@0.0,night@0.3,night@0.75,end').split(',');

(async () => {
  const [out, w = 1440, h = 900, red] = process.argv.slice(2);
  fs.mkdirSync(out, { recursive: true });
  const b = await chromium.launch({ channel: 'chrome', args: ['--use-angle=metal', '--enable-gpu', '--ignore-gpu-blocklist'] });
  const mobile = +w < 600;
  const p = await b.newPage({ viewport: { width: +w, height: +h }, deviceScaleFactor: mobile ? 2 : 1, isMobile: mobile, hasTouch: mobile, reducedMotion: red ? 'reduce' : 'no-preference' });
  const errs = [];
  p.on('pageerror', (e) => errs.push(e.message));
  p.on('console', (m) => { if (['error', 'warning'].includes(m.type())) errs.push(m.text()); });
  await p.goto('http://127.0.0.1:8790/');
  await p.waitForTimeout(3200);
  let i = 0;
  for (const s of STOPS) {
    const y = await p.evaluate((s) => {
      const map = { hero: '.hero', stage: '.stage', night: '.finale__track' };
      if (s === 'end') return document.documentElement.scrollHeight;
      if (/^\d+$/.test(s)) return +s;
      const [sel, f] = s.split('@');
      const el = document.querySelector(map[sel] || sel);
      const top = el.getBoundingClientRect().top + scrollY;
      const pinned = ["hero","stage","night"].includes(sel); const span = pinned ? el.offsetHeight - innerHeight : el.offsetHeight * 0.6;
      return top + span * +f;
    }, s);
    await p.evaluate((y) => { window.scrollTo(0, y); }, y);
    await p.mouse.move(+w * 0.62, +h * 0.4);
    await p.waitForTimeout(+(process.env.SETTLE || 1100));
    await p.screenshot({ path: `${out}/${String(i++).padStart(2, '0')}-${s.replace(/[^a-z0-9.@]/gi, '')}.png` });
  }
  if (errs.length) console.log([...new Set(errs)].join('\n'));
  await b.close();
})();
