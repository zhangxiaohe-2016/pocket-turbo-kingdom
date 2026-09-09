import { chromium } from "@playwright/test";
import assert from "node:assert/strict";
import { mkdir } from "node:fs/promises";
const browser = await chromium.launch({
  channel: process.env.PTK_BROWSER_CHANNEL,
  headless: true,
  args: ["--enable-webgl", "--ignore-gpu-blocklist"],
});
const errors = [];
try {
  const p = await browser.newPage({ viewport: { width: 1440, height: 900 } });
  p.on("pageerror", (e) => errors.push(e.message));
  await p.goto("http://localhost:5173/?test=1");
  await p.waitForFunction(() => window.__PTK__);
  await p.locator("#play-btn").click();
  await p.locator('[data-mode="arena"]').click();
  assert.match(await p.locator(".track-meta h2").textContent(), /星火/);
  await p.locator("#start-btn").click();
  await p.waitForFunction(() => window.__PTK__.snapshot().state === "racing");
  assert.match(await p.locator("#lap").textContent(), /分/);
  assert.equal(await p.locator("#battle-board").isVisible(), true);
  await mkdir("test-results", { recursive: true });
  await p.screenshot({ path: "test-results/arena-desktop.png" });
  await p.evaluate(() => {
    window.__PTK__.manual(true);
    window.__PTK__.advance(11000);
  });
  await p.waitForFunction(() => window.__PTK__.snapshot().state === "finished");
  assert.match(await p.locator("#result-time").textContent(), /分/);
  const snapshot = await p.evaluate(() => window.__PTK__.snapshot());
  assert.equal(snapshot.elapsed, 180);
  assert.ok(snapshot.karts.some((k) => k.score > 0));
  await p.locator("#result-menu-btn").click();
  assert.equal(
    (await p.evaluate(() => window.__PTK__.snapshot())).arena,
    false,
  );
  await p.locator('[data-mode="quick"]').click();
  await p.locator("#start-btn").click();
  await p.evaluate(() => {
    window.__PTK__.manual(true);
    window.__PTK__.advance(230);
  });
  await p.waitForTimeout(150);
  assert.equal(await p.locator(".lap-card>span").textContent(), "LAP");
  assert.equal(await p.locator("#battle-board").isVisible(), false);
  const mobile = await browser.newContext({
    viewport: { width: 844, height: 390 },
    isMobile: true,
    hasTouch: true,
    deviceScaleFactor: 1,
  });
  const m = await mobile.newPage();
  m.on("pageerror", (e) => errors.push(e.message));
  await m.goto("http://localhost:5173/?test=1");
  await m.waitForFunction(() => window.__PTK__);
  await m.locator("#lan-btn").click();
  await m.locator("#lan-name").fill("手机玩家");
  assert.equal(
    await m
      .locator("#lan-name")
      .evaluate((el) =>
        el.dispatchEvent(
          new MouseEvent("contextmenu", { bubbles: true, cancelable: true }),
        ),
      ),
    true,
  );
  await m.locator("#lan-close").click();
  await m.evaluate(() => window.__PTK__.start("arena"));
  const button = m.locator('[data-control="throttle"]');
  await button.waitFor({ state: "visible" });
  const guards = await button.evaluate((el) => ({
    selection: getComputedStyle(el).userSelect,
    action: getComputedStyle(el).touchAction,
    menu: el.dispatchEvent(
      new MouseEvent("contextmenu", { bubbles: true, cancelable: true }),
    ),
    select: el.dispatchEvent(
      new Event("selectstart", { bubbles: true, cancelable: true }),
    ),
  }));
  assert.equal(guards.selection, "none");
  assert.equal(guards.action, "none");
  assert.equal(guards.menu, false);
  assert.equal(guards.select, false);
  await m.waitForFunction(() => window.__PTK__.snapshot().state === "racing");
  const gas = await button.boundingBox(),
    steer = await m.locator('[data-control="steer"]').boundingBox();
  const cdp = await mobile.newCDPSession(m);
  await cdp.send("Input.dispatchTouchEvent", {
    type: "touchStart",
    touchPoints: [
      { x: gas.x + gas.width / 2, y: gas.y + gas.height / 2, id: 1 },
      { x: steer.x + steer.width * 0.65, y: steer.y + steer.height / 2, id: 2 },
    ],
  });
  await m.waitForFunction(()=>window.__PTK__.snapshot().karts[0].speed>5,null,{timeout:10000});
  await m.waitForTimeout(1200);
  assert.equal(await m.evaluate(() => getSelection().toString()), "");
  await cdp.send("Input.dispatchTouchEvent", {
    type: "touchEnd",
    touchPoints: [],
  });
  await m.screenshot({ path: "test-results/arena-mobile.png" });
  assert.deepEqual(errors, []);
  console.log(
    "PASS: arena selection, 3-minute battle and scores, return to racing; mobile long press blocked, input editable, two-finger driving works",
  );
} finally {
  await browser.close();
}
