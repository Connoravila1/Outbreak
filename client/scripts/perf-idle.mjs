// Idle-screen activity in headless Chromium: what the app does when nothing is happening, in the
// foreground and while "backgrounded". Counts requestAnimationFrame callbacks, timer callbacks,
// running CSS animations and network requests per minute. See "Battery and performance" in MOBILE.md.
//
//   API=http://localhost:18504 WEB=http://localhost:5184 node scripts/perf-idle.mjs [human|zombie] [seconds]
//
// Headless has no GPU or battery, so this measures wake-ups (a proxy for energy), not milliwatts.
import { chromium } from 'playwright-core';

const API = process.env.API || 'http://localhost:18504';
const WEB = process.env.WEB || 'http://localhost:5184';
const side = process.argv[2] || 'human';
const secs = +(process.argv[3] || 30);
const exe = process.env.CHROME_PATH
  || `${process.env.HOME}/.cache/ms-playwright/chromium_headless_shell-1234/chrome-headless-shell-linux64/chrome-headless-shell`;
const HOME = { latitude: 47.6097, longitude: -122.3331 };

async function call(token, method, path, body) {
  const r = await fetch(API + path, {
    method,
    headers: { 'content-type': 'application/json', ...(token ? { authorization: 'Bearer ' + token } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  return r.json();
}
const { token } = await call(null, 'POST', '/api/register', {});
await call(token, 'POST', '/api/callsign', { callsign: (side === 'human' ? 'Idle' : 'Gnaw') + (Date.now() % 10000) });
await call(token, 'POST', '/api/faction', { faction: side });

const browser = await chromium.launch({
  executablePath: exe,
  args: ['--use-gl=swiftshader', '--enable-webgl', '--ignore-gpu-blocklist', '--enable-unsafe-swiftshader', '--mute-audio'],
});
const ctx = await browser.newContext({
  viewport: { width: 390, height: 844 }, deviceScaleFactor: 2.6, hasTouch: true, isMobile: true,
  geolocation: HOME, permissions: ['geolocation'],
});
const page = await ctx.newPage();
await page.addInitScript((t) => {
  localStorage.setItem('outbreak.token', t);
  localStorage.setItem('outbreak.briefed', '1');
  localStorage.setItem('outbreak.sound', '0');
  const c = (window.__perf = { raf: 0, timers: 0 });
  const raf = window.requestAnimationFrame.bind(window);
  window.requestAnimationFrame = (cb) => raf((t) => { c.raf++; cb(t); });
  for (const name of ['setTimeout', 'setInterval']) {
    const orig = window[name].bind(window);
    window[name] = (fn, ms, ...a) => orig(typeof fn === 'function' ? (...x) => { c.timers++; return fn(...x); } : fn, ms, ...a);
  }
}, token);

let requests = [];
page.on('request', (r) => {
  const u = new URL(r.url());
  requests.push(u.pathname.startsWith('/api/') ? 'api' + u.pathname : /openfreemap|\.pbf|\.pmtiles/.test(r.url()) ? 'tiles' : 'other');
});

await page.goto(WEB);
await page.waitForSelector('.tabbar', { timeout: 30000 });
// Clear takeovers (level-ups) and let the map load and settle.
for (let i = 0; i < 4; i++) {
  const b = page.locator('.levelup .btn, .battle-layer button.btn').last();
  if (await b.count()) await b.click().catch(() => undefined);
  await page.waitForTimeout(1500);
}
await page.waitForTimeout(8000);

async function window_(label, seconds) {
  requests = [];
  const before = await page.evaluate(() => ({ ...window.__perf }));
  await page.waitForTimeout(seconds * 1000);
  const after = await page.evaluate(() => ({ ...window.__perf, anims: document.getAnimations().filter((a) => a.playState === 'running').length, total: document.getAnimations().length }));
  const per = 60 / seconds;
  const by = {};
  for (const r of requests) by[r] = (by[r] || 0) + 1;
  const row = {
    window: label,
    raf_per_s: +((after.raf - before.raf) / seconds).toFixed(1),
    timers_per_s: +((after.timers - before.timers) / seconds).toFixed(1),
    css_animations_running: after.anims,
    css_animations_total: after.total,
    requests_per_min: Math.round(requests.length * per),
    by_kind_per_min: Object.fromEntries(Object.entries(by).map(([k, v]) => [k, Math.round(v * per)])),
  };
  console.log(JSON.stringify(row));
  return row;
}

await window_('foreground-idle', secs);
// "Backgrounded": the page reports hidden, the way a tab or the Android WebView does when you leave.
await page.evaluate(() => {
  Object.defineProperty(document, 'hidden', { configurable: true, get: () => true });
  Object.defineProperty(document, 'visibilityState', { configurable: true, get: () => 'hidden' });
  document.dispatchEvent(new Event('visibilitychange'));
});
await page.waitForTimeout(1500);
await window_('backgrounded', secs);
await browser.close();
