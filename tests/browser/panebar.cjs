// 终端右上角悬浮状态栏可拖动，并记住位置（避免遮挡 TUI 顶部的功能键）。
const { chromium } = require("playwright");

const BASE = process.env.BASE;
const PASSWORD = process.env.PASSWORD;
const CHROME = process.env.CHROME || undefined;
const assert = (c, m) => { if (!c) throw new Error("ASSERT: " + m); };

(async () => {
  const browser = await chromium.launch({ executablePath: CHROME, args: ["--no-sandbox"] });
  const page = await browser.newPage({ viewport: { width: 1200, height: 800 } });
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));

  await page.goto(BASE + "/");
  await page.waitForSelector("#login-overlay:not([hidden])");
  await page.fill("#login-password", PASSWORD);
  await page.click("#login-submit");
  await page.waitForSelector(".pane .xterm");
  await page.waitForFunction(() => document.querySelector(".pane-status").textContent.includes("已连接"));

  const pane = page.locator(".pane").first();
  await pane.hover();
  const bar = page.locator(".pane-bar").first();
  const grip = page.locator(".pane-grip").first();
  const before = await bar.boundingBox();
  const grab = await grip.boundingBox();
  const box = await pane.boundingBox();

  // 从右上角拖到左下角。
  const targetX = box.x + 24;
  const targetY = box.y + box.height - 52;
  await page.mouse.move(grab.x + grab.width / 2, grab.y + grab.height / 2);
  await page.mouse.down();
  await page.mouse.move(targetX, targetY, { steps: 10 });
  await page.mouse.up();
  await page.waitForTimeout(150);

  const after = await bar.boundingBox();
  assert(after.x < before.x - 100, `bar moved left: ${before.x} -> ${after.x}`);
  assert(after.y > before.y + 100, `bar moved down: ${before.y} -> ${after.y}`);
  const stored = await page.evaluate(() => {
    const raw = localStorage.getItem("myttty.paneBar");
    return raw ? JSON.parse(raw) : null;
  });
  assert(stored && stored.x < 0.5 && stored.y > 0.5, "pane bar position saved: " + JSON.stringify(stored));

  // 刷新后位置保持不变。
  await page.reload();
  await page.waitForSelector(".pane .xterm");
  await page.waitForFunction(() => document.querySelector(".pane-status").textContent.includes("已连接"));
  await pane.hover();
  const reloaded = await bar.boundingBox();
  assert(Math.abs(reloaded.x - after.x) < 12, `x persisted: ${after.x} -> ${reloaded.x}`);
  assert(Math.abs(reloaded.y - after.y) < 12, `y persisted: ${after.y} -> ${reloaded.y}`);

  assert(errors.length === 0, "page errors: " + errors.join(" | "));
  await browser.close();
  console.log("panebar: PASS");
})().catch((e) => {
  console.error("panebar: FAIL:", e.message);
  process.exit(1);
});
