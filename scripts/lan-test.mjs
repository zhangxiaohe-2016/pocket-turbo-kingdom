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
  const a = await browser.newPage({ viewport: { width: 1440, height: 900 } }),
    b = await browser.newPage({ viewport: { width: 1440, height: 900 } });
  for (const p of [a, b]) {
    p.on("pageerror", (e) => errors.push(e.message));
    await p.goto("http://localhost:5173/?test=1");
    await p.waitForFunction(() => window.__PTK__);
    await p.locator("#lan-btn").click();
  }
  await a.locator("#lan-name").fill("主机车手");
  await a.locator("#lan-create").click();
  await a.waitForFunction(
    () => document.querySelector("#lan-room-code").textContent.length === 6,
  );
  const code = await a.locator("#lan-room-code").textContent();
  await b.locator("#lan-name").fill("<朋友>");
  await b.locator("#lan-kart").selectOption("2");
  await b.locator("#lan-code").fill(code);
  await b.locator("#lan-join").click();
  await a.waitForFunction(
    () => document.querySelectorAll(".lan-player").length === 2,
  );
  await b.waitForFunction(
    () => document.querySelectorAll(".lan-player").length === 2,
  );
  if (process.env.PTK_LAN_MODE === "arena") {
    await a.locator("#lan-mode").selectOption("arena");
    await b.waitForFunction(
      () => document.querySelector("#lan-mode").value === "arena",
    );
    assert.equal(await b.locator("#lan-mode").isDisabled(), true);
  }
  assert.equal(await a.locator("#lan-start").isDisabled(), true);
  await a.locator("#lan-ready").click();
  await b.locator("#lan-ready").click();
  await a.locator("#lan-start").click();
  for (const p of [a, b])
    await p.waitForFunction(() => window.__PTK__.snapshot().state === "racing");
  await b.keyboard.down("w");
  await b.waitForFunction(() => window.__PTK__.snapshot().karts[0].speed > 10);
  await b.keyboard.up("w");
  const sa = await a.evaluate(() => window.__PTK__.snapshot()),
    sb = await b.evaluate(() => window.__PTK__.snapshot());
  assert.equal(
    sa.mode,
    process.env.PTK_LAN_MODE === "arena" ? "arena" : "quick",
  );
  assert.equal(sb.mode, sa.mode);
  assert.equal(sa.karts.length, 2);
  assert.equal(sb.karts.length, 2);
  assert.ok(Math.abs(sa.karts[1].position.x - sb.karts[0].position.x) < 4);
  assert.ok(sb.karts[0].speed > 10);
  assert.ok(Math.abs(sa.elapsed - sb.elapsed) < 0.3);
  await b.keyboard.press("Escape");
  assert.equal(await b.locator("#pause-modal").isVisible(), false);
  await mkdir("test-results", { recursive: true });
  await b.screenshot({ path: `test-results/lan-${sa.mode}.png` });
  await a.locator("#lan-exit").click();
  await a.waitForFunction(() => window.__PTK__.snapshot().state === "menu");
  assert.equal(await b.locator("#lan-badge").isVisible(), true);
  await b.locator("#lan-exit").click();
  await b.waitForFunction(() => window.__PTK__.snapshot().state === "menu");
  await b.locator("#lan-btn").click();
  await b.locator("#lan-create").click();
  await b.waitForFunction(() => !document.querySelector("#lan-room").hidden);
  await b.screenshot({ path: "test-results/lan-lobby.png" });
  assert.deepEqual(errors, []);
  console.log(
    "PASS: two browsers join, ready, synchronized race, remote driving, no pause, exit and recreate; no browser errors",
  );
} finally {
  await browser.close();
}
