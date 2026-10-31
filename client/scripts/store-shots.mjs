// Captures store screenshots from the web build in headless Chromium against a --dev server.
// See "Store screenshots" in client/MOBILE.md. Output goes to client/shots/ (git-ignored).
//
//   server/zig-out/bin/outbreak-server --dev --port 18504 --data /tmp/outbreak-shots
//   OUTBREAK_API=http://localhost:18504 npx vite --port 5184      (in client/)
//   npm run shots
//
// Env: API, WEB, OUT, SIZES (comma list of play,ios), CHROME_PATH. The map needs internet for tiles.
import { mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
import { chromium } from 'playwright-core';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const API = process.env.API || 'http://localhost:18504';
const WEB = process.env.WEB || 'http://localhost:5184';
const OUT = process.env.OUT || resolve(root, 'shots');
const exe = process.env.CHROME_PATH
  || `${process.env.HOME}/.cache/ms-playwright/chromium_headless_shell-1234/chrome-headless-shell-linux64/chrome-headless-shell`;
// CSS viewport x device scale = store pixels.
const ALL = {
  play: { w: 360, h: 640, dpr: 3 }, // 1080 x 1920
  ios: { w: 430, h: 932, dpr: 3 }, // 1290 x 2796 (6.7")
};
const sizes = (process.env.SIZES || 'play,ios').split(',').map((s) => s.trim()).filter((s) => ALL[s]);
// A residential spot (Wallingford, Seattle): downtown stacks too many place markers on the map.
const HOME = { latitude: 47.6615, longitude: -122.3340 };

async function call(token, method, path, body) {
  const r = await fetch(API + path, {
    method,
    headers: { 'content-type': 'application/json', ...(token ? { authorization: 'Bearer ' + token } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(`${method} ${path} ${r.status} ${JSON.stringify(j)}`);
  return j;
}

/** A fresh character with gear in every slot, healed. */
async function makePlayer(side, xp) {
  const { token } = await call(null, 'POST', '/api/register', { terms: 1 });
  const cs = (side === 'human' ? 'Warden' : 'Gnaw') + (Date.now() % 10000);
  await call(token, 'POST', '/api/callsign', { callsign: cs });
  await call(token, 'POST', '/api/faction', { faction: side });
  let me = (await call(token, 'POST', '/api/dev/grant', { xp })).me;
  const cat = await call(token, 'GET', '/api/catalog');
  for (const slot of ['weapon', 'armor', 'utility']) {
    const base = cat.items.filter((i) => i.slot === slot && i.req <= me.level).sort((a, b) => b.req - a.req)[0];
    if (base) await call(token, 'POST', '/api/dev/grant', { item: { base: base.id, rarity: slot === 'armor' ? 'rare' : 'uncommon' } });
  }
  me = await call(token, 'GET', '/api/me');
  for (const slot of ['weapon', 'armor', 'utility']) {
    const it = me.items.filter((i) => i.slot === slot).sort((a, b) => b.power - a.power)[0];
    if (it) await call(token, 'POST', '/api/equip', { uid: it.uid });
  }
  await call(token, 'POST', '/api/dev/heal', {});
  return { token, me: await call(token, 'GET', '/api/me') };
}

mkdirSync(OUT, { recursive: true });
const browser = await chromium.launch({
  executablePath: exe,
  args: ['--use-gl=swiftshader', '--enable-webgl', '--ignore-gpu-blocklist', '--enable-unsafe-swiftshader', '--autoplay-policy=no-user-gesture-required'],
});

async function newPage(sz, token) {
  const ctx = await browser.newContext({
    viewport: { width: sz.w, height: sz.h }, deviceScaleFactor: sz.dpr, hasTouch: true, isMobile: true,
    geolocation: HOME, permissions: ['geolocation'],
  });
  const page = await ctx.newPage();
  page.on('pageerror', (e) => console.log('pageerror', e.message));
  if (token) {
    await page.addInitScript((t) => {
      localStorage.setItem('outbreak.token', t);
      localStorage.setItem('outbreak.briefed', '1');
      localStorage.setItem('outbreak.sound', '0');
      localStorage.setItem('outbreak.guestNudge', '99'); // no account reminder over the map
      document.addEventListener('DOMContentLoaded', () => {
        const st = document.createElement('style');
        st.textContent = '.coach{display:none!important}'; // the first-fight hint covers the map
        document.head.append(st);
      });
    }, token);
  }
  return { ctx, page };
}

const settle = (page, ms) => page.waitForTimeout(ms);

/** Level-ups and fights from the setup grants take the screen over on first poll; click them away. */
async function dismiss(page) {
  await settle(page, 2500);
  for (let i = 0; i < 8; i++) {
    const btn = page.locator('.levelup .btn, .battle-layer button.btn').last();
    if (!(await btn.count())) { await settle(page, 1200); if (!(await btn.count())) return; }
    await btn.click({ timeout: 4000 }).catch(() => undefined);
    await settle(page, 1500);
  }
}

async function enemiesVisible(page) {
  for (let i = 0; i < 30; i++) {
    const n = await page.locator('.maplibregl-marker.mk-enemy, .mk-enemy').count();
    if (n >= 3) return n;
    await settle(page, 1000);
  }
  return 0;
}

for (const name of sizes) {
  const sz = ALL[name];
  const shot = (page, n) => page.screenshot({ path: `${OUT}/${name}-${n}.png` });
  console.log(`== ${name} ${sz.w * sz.dpr}x${sz.h * sz.dpr}`);

  // 1. The split-lens choice (fresh install, no token).
  {
    const { ctx, page } = await newPage(sz, null);
    await page.goto(WEB);
    await page.click('text=Tap to listen', { timeout: 30000 });
    await page.click('text=Allow location', { timeout: 40000 });
    await page.click('text=Look around', { timeout: 20000 });
    await page.waitForSelector('.split');
    await settle(page, 6000);
    await shot(page, '1-split-lens');
    await ctx.close();
  }

  // 2. Survey map with enemies (Human).
  const human = await makePlayer('human', 900);
  {
    const { ctx, page } = await newPage(sz, human.token);
    await page.goto(WEB);
    await page.waitForSelector('.tabbar', { timeout: 30000 });
    await dismiss(page);
    await enemiesVisible(page);
    await settle(page, 3500);
    await shot(page, '2-survey-map');

    // 4. A fight: walk onto the nearest enemy, engage, capture mid-fight and the result.
    const w = await call(human.token, 'POST', '/api/location', { lat: HOME.latitude, lon: HOME.longitude, acc: 8, sanctuary: false, places: [] });
    const foe = [...w.enemies].sort((a, b) => Math.hypot(a.lat - HOME.latitude, a.lon - HOME.longitude) - Math.hypot(b.lat - HOME.latitude, b.lon - HOME.longitude))[0];
    if (foe) {
      await ctx.setGeolocation({ latitude: foe.lat, longitude: foe.lon, accuracy: 8 });
      await settle(page, 4000);
      // Other markers are made click-through while we pick an enemy (a landmark can sit on top of one).
      const hide = await page.addStyleTag({ content: '.mk:not(.mk-enemy){visibility:hidden!important;pointer-events:none!important}' });
      const pts = await page.evaluate(() => {
        const vp = document.querySelector('.maplibregl-map').getBoundingClientRect();
        const cx = vp.left + vp.width / 2, cy = vp.top + vp.height / 2;
        return [...document.querySelectorAll('.maplibregl-marker')].filter((e) => /mk-enemy/.test(e.className))
          .map((e) => { const r = e.getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2, d: Math.hypot(r.left + r.width / 2 - cx, r.top + r.height / 2 - cy) }; })
          .sort((a, b) => a.d - b.d).slice(0, 5);
      });
      let engaged = false;
      for (const pt of pts) {
        await page.mouse.click(pt.x, pt.y);
        await settle(page, 900);
        const btn = page.locator('button:has-text("Engage")').first();
        if (!(await btn.count()) || !(await btn.isEnabled())) { await page.mouse.click(6, 6).catch(() => undefined); continue; }
        await btn.click({ force: true, timeout: 5000 }).catch(() => undefined);
        engaged = await page.waitForSelector('.battle-layer', { timeout: 8000 }).then(() => true, () => false);
        if (engaged) break;
        await page.mouse.click(6, 6).catch(() => undefined);
      }
      await hide.evaluate((e) => e.remove());
      if (engaged) {
        await settle(page, 900);
        await shot(page, '4-fight');
        await page.waitForSelector('.result', { timeout: 60000 }).catch(() => console.log('no result card'));
        await settle(page, 3500);
        await shot(page, '5-loot-result');
        await dismiss(page);
      } else console.log('no enemy could be engaged');
    }

    // 5b. Level up: a big grant, so the card shows a title and several unlocks.
    await call(human.token, 'POST', '/api/dev/grant', { xp: 3500 });
    await page.waitForSelector('.levelup', { timeout: 20000 }).catch(() => console.log('no level-up card'));
    await settle(page, 3500);
    await shot(page, '6-level-up');
    await ctx.close();
  }

  // 3. Heat map (Zombie).
  const zombie = await makePlayer('zombie', 900);
  {
    const { ctx, page } = await newPage(sz, zombie.token);
    await page.goto(WEB);
    await page.waitForSelector('.tabbar', { timeout: 30000 });
    await dismiss(page);
    await enemiesVisible(page);
    await settle(page, 3500);
    await shot(page, '3-heat-map');
    await ctx.close();
  }

  // 6. The PvP stage: a bot Contact against a stronger Human.
  const duel = await makePlayer('human', 6000);
  {
    const { ctx, page } = await newPage(sz, duel.token);
    await page.goto(WEB);
    await page.waitForSelector('.tabbar', { timeout: 30000 });
    await dismiss(page);
    await call(duel.token, 'POST', '/api/dev/bot_contact', { rarity: 'rare' });
    await page.waitForSelector('.pvp-arena', { timeout: 30000 }).catch(() => console.log('no pvp stage'));
    await settle(page, 4500);
    await shot(page, '7-pvp-stage');
    await ctx.close();
  }
}
await browser.close();
console.log('shots in', OUT);
