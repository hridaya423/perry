# Perry website

Static site. `index.html` + `styles/site.css` + `src/main.js` bundled to `assets/site.js`.
Design contract: `DESIGN.md` (the inkwell concept). Product facts come from `../README.md`, `../PRD.md` and `../DESIGN.md`; never invent claims.

## Commands

```sh
npm run build      # src/main.js -> assets/site.js (run after every src edit)
npm run dev        # serve the source tree on :8790
npm run dist       # build, then scripts/dist.mjs writes the deployable site to dist/
npm run preview    # serve dist/ on :8791
npm run build:lab  # src/lab.js -> assets/lab.js; open /lab.html?drain=0.4&look=0.5,0&night=1 to tune the wordmark
node scripts/tour.cjs /tmp/out [w] [h] [reduced]   # screenshots at scroll stops
node scripts/shot.cjs <url> <png> [w] [h]           # single screenshot, prints console errors
```

Playwright is borrowed from `../../silk-reel/node_modules/playwright` (set `PW` to override).

## Launch and SEO

- `dist/` is the whole deployable site for `https://perry.hridya.tech/`. Host it as static files.
- `dist.mjs` reads the latest GitHub release and stamps its version and DMG URL into the CTAs, the FAQ and the JSON-LD. Do not hardcode a version. Rebuild after each release.
- The canonical origin is `SITE` in `dist.mjs` and the absolute URLs in the `index.html` head; change both together.
- The FAQ lives in `index.html` as `[data-qa]` items. It is the single source for the notch workspace (`src/workspace.js`), the FAQPage JSON-LD and `llms.txt`. Edit questions there; `KEYS` in `workspace.js` only holds match keywords.
- `dist.mjs` also writes `robots.txt`, `sitemap.xml` and `llms.txt`.
- Checks before launch: Lighthouse SEO 100 and accessibility 100 on mobile and desktop, zero messages from the W3C Nu checker, and `curl` of the built page containing every FAQ answer.

## Architecture

- `src/ink/engine.js`: one WebGL2 ink renderer with a Canvas2D fallback.
- `src/ink/glyphs.js` + `wordmark.js`: the brushed "perry", paint-in clock, genie drain into the notch.
- `src/ink/eyes.js`: gaze, saccades, blinks, moods. `src/mascot.js` mirrors PerryCharacterView.
- `src/sentence.js`, `sort.js`, `gate.js`, `route.js`, `workspace.js`: one module per section.
- `src/main.js`: Lenis + ScrollTrigger, the single gsap ticker loop (reads first, then writes), day-to-night.
