import { readFileSync, writeFileSync, mkdirSync, cpSync, rmSync } from 'node:fs';
import { buildSync } from 'esbuild';

const SITE = 'https://perry.hridya.tech/';
const REPO = 'hridaya423/perry';
const OUT = 'dist';
// The portfolio's Person node; every hridya.tech product site names it as author.
const AUTHOR = 'https://www.hridya.tech/#person';
const WRITEUP = 'https://www.hridya.tech/projects/perry';

const res = await fetch(`https://api.github.com/repos/${REPO}/releases/latest`, {
  headers: process.env.GITHUB_TOKEN ? { authorization: `Bearer ${process.env.GITHUB_TOKEN}` } : {},
});
if (!res.ok) throw new Error(`GitHub releases API returned ${res.status}`);
const release = await res.json();
const version = release.tag_name.replace(/^v/, '');
const dmg = release.assets.find((a) => a.name.endsWith('.dmg'));
if (!dmg) throw new Error(`Release ${release.tag_name} has no .dmg asset`);
const published = release.published_at.slice(0, 10);
const today = new Date().toISOString().slice(0, 10);

const text = (s) => s.replace(/<[^>]+>/g, '').replace(/&amp;/g, '&').replace(/\s+/g, ' ').trim();
let html = readFileSync('index.html', 'utf8')
  .replaceAll(`href="https://github.com/${REPO}/releases/latest" data-get`, `href="${dmg.browser_download_url}" data-get`)
  .replace(/(<span data-version>)[^<]*(<\/span>)/g, `$1${version}$2`);

const faq = [...html.matchAll(/data-qa="[^"]+"><h3>(.*?)<\/h3><p>(.*?)<\/p>/g)].map(([, q, a]) => ({ q: text(q), a: text(a) }));
if (faq.length < 5) throw new Error(`Found only ${faq.length} FAQ items in index.html`);
const description = text(html.match(/<meta name="description" content="([^"]+)"/)[1]);
const shot = (file, caption) => ({ '@type': 'ImageObject', url: `https://raw.githubusercontent.com/${REPO}/main/.github/assets/${file}`, caption });

const graph = {
  '@context': 'https://schema.org',
  '@graph': [
    {
      '@type': 'WebSite', '@id': `${SITE}#website`, url: SITE, name: 'Perry', inLanguage: 'en',
      publisher: { '@id': AUTHOR },
    },
    {
      '@type': 'Person', '@id': AUTHOR, name: 'Hridya Agrawal', url: 'https://www.hridya.tech',
      sameAs: ['https://github.com/hridaya423', 'https://www.linkedin.com/in/hridya-agrawal-067236317/', 'https://x.com/AgrawalHridaya'],
    },
    {
      '@type': 'WebPage', '@id': `${SITE}#webpage`, url: SITE, name: text(html.match(/<title>(.*?)<\/title>/)[1]),
      description, inLanguage: 'en', isPartOf: { '@id': `${SITE}#website` }, about: { '@id': `${SITE}#app` },
      primaryImageOfPage: { '@type': 'ImageObject', url: `${SITE}assets/og.png`, width: 1200, height: 630 },
      dateModified: today,
    },
    {
      '@type': 'SoftwareApplication', '@id': `${SITE}#app`, name: 'Perry', url: SITE, description,
      applicationCategory: 'UtilitiesApplication', applicationSubCategory: 'AI assistant',
      operatingSystem: 'macOS 14 or later', processorRequirements: 'Apple silicon (arm64)',
      softwareVersion: version, datePublished: published, releaseNotes: release.html_url,
      downloadUrl: dmg.browser_download_url, installUrl: dmg.browser_download_url, fileSize: `${Math.round(dmg.size / 1048576)} MB`,
      license: 'https://www.gnu.org/licenses/agpl-3.0.html', isAccessibleForFree: true,
      offers: { '@type': 'Offer', price: '0', priceCurrency: 'USD', availability: 'https://schema.org/InStock' },
      author: { '@id': AUTHOR }, image: `${SITE}assets/og.png`,
      screenshot: [
        shot('hero.png', 'The Perry workspace opened from the notch'),
        shot('guide.png', 'A guide step in the notch with Done and Do it for me buttons'),
        shot('task.png', 'A running task in the notch with Pause, Take over and Stop'),
      ],
      featureList: [
        'Points at each control in any Mac app, one step at a time',
        'Does the task for you while you watch, with a stop button in reach',
        'Answers questions about the window in front of you',
        'Saves a task you show it once as a routine',
        'Works with a ChatGPT or Claude plan, an API key, or a model on your Mac',
        'Asks once before any action you cannot undo',
      ],
      sameAs: [`https://github.com/${REPO}`, WRITEUP],
      subjectOf: { '@type': 'TechArticle', url: WRITEUP },
    },
    {
      '@type': 'FAQPage', '@id': `${SITE}#faq`, isPartOf: { '@id': `${SITE}#webpage` },
      mainEntity: faq.map(({ q, a }) => ({ '@type': 'Question', name: q, acceptedAnswer: { '@type': 'Answer', text: a } })),
    },
  ],
};
html = html.replace(/<script type="application\/ld\+json" data-ld>\{\}<\/script>/, `<script type="application/ld+json">${JSON.stringify(graph).replace(/</g, '\\u003c')}</script>`);
if (html.includes('data-ld>')) throw new Error('JSON-LD placeholder not replaced');

rmSync(OUT, { recursive: true, force: true });
mkdirSync(`${OUT}/styles`, { recursive: true });
writeFileSync(`${OUT}/index.html`, html);
buildSync({ entryPoints: ['styles/site.css'], outfile: `${OUT}/styles/site.css`, minify: true, logLevel: 'warning' });
for (const f of ['site.js', 'favicon.svg', 'apple-touch-icon.png', 'og.png', 'fonts/young-serif-400-normal.woff2', 'fonts/bricolage-grotesque-200_800-normal.woff2']) {
  cpSync(`assets/${f}`, `${OUT}/assets/${f}`);
}
// Name the search and AI crawlers so a blanket rule upstream cannot shadow them.
const BOTS = ['Googlebot', 'Bingbot', 'Applebot', 'DuckDuckBot', 'OAI-SearchBot', 'ChatGPT-User', 'GPTBot', 'Claude-SearchBot', 'Claude-User', 'ClaudeBot', 'PerplexityBot', 'Perplexity-User', 'Google-Extended', 'Applebot-Extended', 'CCBot'];
writeFileSync(`${OUT}/robots.txt`, `User-agent: *\nAllow: /\n\n${BOTS.map((b) => `User-agent: ${b}`).join('\n')}\nAllow: /\n\nSitemap: ${SITE}sitemap.xml\n`);
writeFileSync(`${OUT}/sitemap.xml`, `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url><loc>${SITE}</loc><lastmod>${today}</lastmod></url>
</urlset>
`);
writeFileSync(`${OUT}/llms.txt`, `# Perry

> ${description}

Perry is a macOS app by Hridya Agrawal (https://www.hridya.tech). How it works: ${WRITEUP}. Version ${version} is a public beta, released ${published}, signed with a Developer ID and notarized by Apple. It is free and open source under AGPL-3.0.

- Download: ${dmg.browser_download_url}
- Requirements: a Mac with Apple silicon, macOS 14 or later
- Talk: hold Control and Option. Type: double-tap Control.
- Brains: a ChatGPT plan, a Claude plan with Claude Code, an API key (OpenAI, Anthropic, Gemini, OpenRouter and others), or a model on the Mac
- Privacy: no Perry server, no telemetry, screenshots in memory only, API keys in the macOS Keychain

## Questions

${faq.map(({ q, a }) => `### ${q}\n\n${a}`).join('\n\n')}

## Docs

- [README](https://github.com/${REPO}/blob/main/README.md): install, features, brains and privacy
- [Release notes](${release.html_url}): what changed in ${version}
- [Product contract](https://github.com/${REPO}/blob/main/PRD.md): architecture and trust tiers
- [Source code](https://github.com/${REPO}): Swift and SwiftUI, AGPL-3.0
`);
console.log(`dist: ${SITE} v${version} ${faq.length} questions`);
