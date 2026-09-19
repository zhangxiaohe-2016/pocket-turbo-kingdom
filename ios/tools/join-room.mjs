// join-room.mjs —— 让 Mac 上的 Web 版加入 iPad 房间，跑一场并截图（验证「iPad 与 Web 版同房对战」）。
//   node ios/tools/join-room.mjs <6位房间码> [秒数]
import { chromium } from '@playwright/test';
import { mkdir } from 'node:fs/promises';

const code = process.argv[2];
const seconds = Number(process.argv[3] || 20);
if (!code || code.length !== 6) {
  console.error('用法: node ios/tools/join-room.mjs <6位房间码> [秒数]');
  process.exit(2);
}
await mkdir('/tmp/ptkshots', { recursive: true });
const browser = await chromium.launch({ args: ['--enable-webgl', '--ignore-gpu-blocklist'] });
const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
page.on('pageerror', (e) => console.log('PAGEERROR', e.message));
page.on('console', (m) => { if (m.type() === 'error') console.log('CONSOLE_ERROR', m.text()); });

await page.goto('http://localhost:5173/?test=1');
await page.waitForFunction(() => window.__PTK__, null, { timeout: 60000 });
await page.locator('#lan-btn').click();
await page.locator('#lan-name').fill('Mac浏览器');
await page.locator('#lan-code').fill(code);
await page.locator('#lan-join').click();
await page.waitForFunction(() => document.querySelectorAll('.lan-player').length >= 2, null, { timeout: 20000 });
console.log('已进入房间', code, '，人数 2，点击准备');
await page.locator('#lan-ready').click();
await page.waitForFunction(() => window.__PTK__.snapshot().state === 'racing', null, { timeout: 40000 });
console.log('比赛已开始（服务器发车），跟随', seconds, '秒');
// 让 Web 端自己开（?test=1 暴露的调试自动驾驶），这样是两台车真在跑
await page.evaluate(() => window.__PTK__.autopilot(true));
const t0 = Date.now();
while (Date.now() - t0 < seconds * 1000) {
  await page.waitForTimeout(1000);
  const s = await page.evaluate(() => window.__PTK__.snapshot());
  console.log(`  t=${((Date.now() - t0) / 1000).toFixed(0)}s elapsed=${s.elapsed.toFixed(1)} karts=${s.karts.length} ` +
    s.karts.map((k) => `[${k.rank}名 ${k.lap}圈 ${k.speed.toFixed(1)}m/s]`).join(' '));
}
const snap = await page.evaluate(() => window.__PTK__.snapshot());
await page.screenshot({ path: '/tmp/ptkshots/web-race.png' });
console.log('浏览器端最终:', JSON.stringify({
  state: snap.state, elapsed: +snap.elapsed.toFixed(1),
  karts: snap.karts.map((k) => ({ rank: k.rank, lap: k.lap, speed: +k.speed.toFixed(1),
    pos: [k.position.x, k.position.y, k.position.z].map((v) => +v.toFixed(1)) })),
}));
console.log('截图: /tmp/ptkshots/web-race.png');
await browser.close();
