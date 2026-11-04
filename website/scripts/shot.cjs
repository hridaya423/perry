const { chromium } = require(process.env.PW || '/Users/hridyaagrawal/Honey/silk-reel/node_modules/playwright');
(async () => {
  const [url, out, w = 1440, h = 900] = process.argv.slice(2);
  const b = await chromium.launch({ channel: 'chrome', args: ['--use-angle=metal', '--enable-gpu', '--ignore-gpu-blocklist'] });
  const p = await b.newPage({ viewport: { width: +w, height: +h }, deviceScaleFactor: 2 });
  const errs = [];
  p.on('pageerror', (e) => errs.push(e.message));
  p.on('console', (m) => { if (['error', 'warning'].includes(m.type())) errs.push(m.text()); });
  await p.goto(url);
  await p.waitForTimeout(+(process.env.WAIT || 600));
  await p.screenshot({ path: out });
  if (errs.length) console.log(errs.join('\n'));
  await b.close();
})();
