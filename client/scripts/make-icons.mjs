// Regenerates every app icon, splash and favicon from client/resources/*.svg using headless
// Chromium (playwright-core). Run: npm run icons
// Env: CHROME_PATH overrides the browser executable.
import { mkdirSync, readFileSync, writeFileSync, existsSync, rmSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve, join } from 'node:path';
import { chromium } from 'playwright-core';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const res = (f) => readFileSync(join(root, 'resources', f), 'utf8');
const exe = process.env.CHROME_PATH
  || `${process.env.HOME}/.cache/ms-playwright/chromium_headless_shell-1234/chrome-headless-shell-linux64/chrome-headless-shell`;
const NEUTRAL = '#0B0C0E';

const browser = await chromium.launch({ executablePath: exe });
const page = await browser.newPage();

// Render markup into a size x size transparent canvas and save it as a PNG.
async function render(html, size, out, height = size) {
  await page.setViewportSize({ width: size, height });
  await page.setContent(`<style>html,body{margin:0;background:transparent;overflow:hidden}svg{display:block}</style>${html}`);
  mkdirSync(dirname(out), { recursive: true });
  await page.screenshot({ path: out, omitBackground: true, clip: { x: 0, y: 0, width: size, height } });
}
const sized = (svg, size) => svg.replace('width="1024" height="1024"', `width="${size}" height="${size}"`);
// Centre an svg at `frac` of a larger square canvas.
const onCanvas = (svg, size, frac, bg) =>
  `<div style="width:${size}px;height:${size}px;background:${bg};display:flex;align-items:center;justify-content:center">${sized(svg, Math.round(size * frac))}</div>`;
const circle = (svg, size) => `<div style="width:${size}px;height:${size}px;border-radius:50%;overflow:hidden">${sized(svg, size)}</div>`;

const full = res('icon.svg'), bgSvg = res('icon-background.svg'), fgSvg = res('icon-foreground.svg');
const mono = res('icon-mono.svg'), splash = res('splash.svg');

// Android: legacy launcher icons (48dp) and adaptive layers (108dp) per density.
const dens = { mdpi: 1, hdpi: 1.5, xhdpi: 2, xxhdpi: 3, xxxhdpi: 4 };
const andRes = join(root, 'android/app/src/main/res');
for (const [d, k] of Object.entries(dens)) {
  const dir = join(andRes, `mipmap-${d}`);
  await render(sized(full, 48 * k), 48 * k, join(dir, 'ic_launcher.png'));
  await render(circle(full, 48 * k), 48 * k, join(dir, 'ic_launcher_round.png'));
  const a = 108 * k;
  await render(sized(bgSvg, a), a, join(dir, 'ic_launcher_bg.png'));
  await render(sized(fgSvg, a), a, join(dir, 'ic_launcher_fg.png'));
  await render(sized(mono, a), a, join(dir, 'ic_launcher_mono.png'));
}
// Android 12+ splash icon: 288dp canvas of which the central 2/3 (a 192dp disc) is visible.
await render(onCanvas(splash, 1152, 0.5, 'transparent'), 1152, join(andRes, 'drawable-nodpi/splash_icon.png'));
for (const f of ['drawable/ic_launcher_bg.png', 'drawable-v24/ic_launcher_foreground.xml']) {
  const p = join(andRes, f);
  if (existsSync(p)) rmSync(p);
}
const adaptive = `<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@mipmap/ic_launcher_bg" />
    <foreground android:drawable="@mipmap/ic_launcher_fg" />
    <monochrome android:drawable="@mipmap/ic_launcher_mono" />
</adaptive-icon>
`;
for (const n of ['ic_launcher.xml', 'ic_launcher_round.xml']) writeFileSync(join(andRes, 'mipmap-anydpi-v26', n), adaptive);

// iOS: one 1024 universal icon (opaque), launch image on the neutral colour.
const ios = join(root, 'ios/App/App/Assets.xcassets');
await render(sized(full, 1024), 1024, join(ios, 'AppIcon.appiconset/AppIcon-512@2x.png'));
for (const f of ['splash-2732x2732.png', 'splash-2732x2732-1.png', 'splash-2732x2732-2.png']) {
  await render(onCanvas(splash, 2732, 0.2, NEUTRAL), 2732, join(ios, 'Splash.imageset', f));
}

// Web: favicons, apple touch icon, PWA icons (maskable keeps the ring inside the 80% safe zone).
const pub = join(root, 'public');
for (const [n, s] of [['favicon-32.png', 32], ['favicon-48.png', 48], ['apple-touch-icon.png', 180], ['icon-192.png', 192], ['icon-512.png', 512]]) {
  await render(sized(full, s), s, join(pub, n));
}
await render(`<div style="position:relative;width:512px;height:512px">${sized(bgSvg, 512)}<div style="position:absolute;inset:0;display:flex;align-items:center;justify-content:center">${sized(fgSvg, 410)}</div></div>`, 512, join(pub, 'icon-maskable-512.png'));
writeFileSync(join(pub, 'favicon.svg'), full);

// Play Store listing icon (512, opaque) and a review sheet live with the sources (git-ignored).
await render(sized(full, 512), 512, join(root, 'resources/out/play-store-icon-512.png'));
for (const s of [48, 96, 192]) await render(sized(full, s), s, join(root, `resources/out/icon-${s}.png`));
await render(`<body style="margin:0;display:flex;gap:0;width:960px;height:560px;font:14px sans-serif"><div style="flex:1;background:linear-gradient(#e8e6df,#bdb9ac);display:flex;flex-wrap:wrap;gap:36px;padding:48px;align-content:flex-start">${[48, 96, 192].map((s) => sized(circle(full, s), s)).join('')}${[48, 96].map((s) => `<div style="border-radius:22%;overflow:hidden;width:${s}px;height:${s}px">${sized(full, s)}</div>`).join('')}</div><div style="flex:1;background:linear-gradient(#17202b,#07090c);display:flex;flex-wrap:wrap;gap:36px;padding:48px;align-content:flex-start">${[48, 96, 192].map((s) => sized(circle(full, s), s)).join('')}${[48, 96].map((s) => `<div style="border-radius:22%;overflow:hidden;width:${s}px;height:${s}px">${sized(full, s)}</div>`).join('')}</div></body>`, 960, join(root, 'resources/out/homescreen-mock.png'), 560);

await browser.close();
console.log('icons written');
