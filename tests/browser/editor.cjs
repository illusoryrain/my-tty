// 编辑器冲突检测、应用内确认弹窗、版本化静态资源、localStorage 不可用时启动、输出合并、偏好持久化。
const { chromium } = require("playwright");
const fs = require("fs"); const path = require("path");
// 共享 ROOT 里别的测试会建很多目录（虚拟列表只渲染视口附近的行），用独立子目录。
const ROOT = path.join(process.env.ROOT, "editor-test"); const ROOT_NAME = "editor-test";
const assert = (c, m) => { if (!c) throw new Error("ASSERT: " + m); };
(async () => {
  fs.mkdirSync(ROOT, { recursive: true });
  fs.writeFileSync(path.join(ROOT, "conf.txt"), "original\n");
  fs.writeFileSync(path.join(ROOT, "gone.txt"), "x\n");
  const browser = await chromium.launch({ executablePath: process.env.CHROME || undefined, args: ["--no-sandbox"] });
  const ctx = await browser.newContext({ viewport: { width: 1200, height: 800 } });
  // 1. localStorage 全部抛异常时页面仍能启动
  await ctx.addInitScript(() => {
    Storage.prototype.getItem = () => { throw new Error("blocked"); };
    Storage.prototype.setItem = () => { throw new Error("blocked"); };
  });
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  page.on("dialog", (d) => { errors.push("native dialog: " + d.message()); d.dismiss(); });
  const res = [];
  page.on("response", (r) => res.push([r.url(), r.headers()["cache-control"]]));
  await page.goto(process.env.BASE + "/");
  await page.fill("#login-password", process.env.PASSWORD);
  await page.click("#login-submit");
  await page.waitForSelector(".pane .xterm");
  await page.waitForTimeout(800);
  const versioned = res.filter(([u]) => /\?v=[0-9a-f]{16}$/.test(u));
  assert(versioned.length >= 7, "versioned subresources: " + JSON.stringify(res));
  assert(versioned.every(([, cc]) => cc.includes("immutable")), "immutable");
  console.log("versioned assets:", versioned.length, "ok; storage-blocked startup ok");

  // 2. 编辑器冲突
  await page.locator(".pane-term").first().click();
  await page.keyboard.type(`cd '${ROOT}'\r`);
  await page.click("#toggle-files");
  await page.waitForFunction((n) => { const el = document.querySelector("#crumb button.active"); return !!el && el.textContent === n; }, ROOT_NAME, { timeout: 10000 });
  const row = page.locator("#file-list .entry.file", { hasText: "conf.txt" });
  await row.waitFor();
  await row.locator(".name").click();
  await page.waitForSelector("#editor-overlay:not([hidden])");
  await page.locator("#editor").fill("mine\n");
  fs.writeFileSync(path.join(ROOT, "conf.txt"), "theirs\n");
  await page.click("#editor-save");
  await page.waitForSelector("#prompt-overlay:not([hidden])");
  assert((await page.textContent("#prompt-title")).includes("已在别处被修改"), "conflict title");
  assert(await page.isHidden("#prompt-input"), "input hidden in confirm");
  assert(fs.readFileSync(path.join(ROOT, "conf.txt"), "utf8") === "theirs\n", "not overwritten");
  await page.click("#prompt-cancel");
  await page.waitForSelector("#prompt-overlay", { state: "hidden" });
  await page.click("#editor-save");
  await page.waitForSelector("#prompt-overlay:not([hidden])");
  await page.click("#prompt-ok");
  await page.waitForFunction(() => document.querySelector("#editor-state").textContent.includes("已保存"));
  assert(fs.readFileSync(path.join(ROOT, "conf.txt"), "utf8") === "mine\n", "forced overwrite");
  // 再次保存（使用新 version）不应冲突
  await page.locator("#editor").fill("mine2\n");
  await page.click("#editor-save");
  await page.waitForFunction(() => document.querySelector("#editor-state").textContent.includes("已保存"));
  assert(fs.readFileSync(path.join(ROOT, "conf.txt"), "utf8") === "mine2\n", "second save");
  console.log("editor conflict ok");

  // 3. 未保存时关闭 -> 自定义确认；Esc 取消
  await page.locator("#editor").fill("dirty\n");
  await page.click("#editor-close");
  await page.waitForSelector("#prompt-overlay:not([hidden])");
  await page.keyboard.press("Escape");
  await page.waitForSelector("#prompt-overlay", { state: "hidden" });
  assert(await page.isVisible("#editor-overlay"), "editor still open after cancel");
  await page.click("#editor-close");
  await page.waitForSelector("#prompt-overlay:not([hidden])");
  await page.click("#prompt-ok");
  await page.waitForSelector("#editor-overlay", { state: "hidden" });
  console.log("close confirm ok");

  // 4. 删除确认
  const gone = page.locator("#file-list .entry.file", { hasText: "gone.txt" });
  await gone.hover();
  await gone.locator('[data-act="delete"]').click();
  await page.waitForSelector("#prompt-overlay:not([hidden])");
  assert((await page.textContent("#prompt-ok")) === "删除", "delete label");
  await page.click("#prompt-ok");
  await gone.waitFor({ state: "detached" });
  assert(!fs.existsSync(path.join(ROOT, "gone.txt")), "deleted");
  // 文本输入弹窗恢复正常
  await page.click("#files-new-file");
  await page.waitForSelector("#prompt-overlay:not([hidden])");
  assert(await page.isVisible("#prompt-input"), "input back for askText");
  assert((await page.textContent("#prompt-ok")) === "确定", "ok label reset");
  await page.keyboard.press("Escape");
  console.log("delete confirm ok");

  // 5. 输出合并：大量输出完整到达
  await page.locator(".pane-term").first().click();
  await page.keyboard.type("seq 1 200000 | tail -c 20000 >/dev/null; seq 1 30000; echo DONE_$((6*7))\r");
  await page.waitForFunction(() => [...document.querySelectorAll(".xterm-rows")].some(r => r.innerText.includes("DONE_42")), null, { timeout: 20000 });
  console.log("bulk output ok");


  // 6. 偏好持久化（存储正常的新上下文）：拖动中不写 localStorage，松手写一次；刷新后字号保留。
  const ctx2 = await browser.newContext({ viewport: { width: 1200, height: 800 } });
  const p2 = await ctx2.newPage();
  await p2.goto(process.env.BASE + "/");
  await p2.fill("#login-password", process.env.PASSWORD);
  await p2.click("#login-submit");
  await p2.waitForSelector(".pane .xterm");
  await p2.waitForTimeout(500);
  await p2.click("#font-inc");
  await p2.click("#font-inc");
  await p2.click("#add-pane");
  await p2.waitForTimeout(600);
  const box = await p2.locator(".splitter.v").boundingBox();
  const wsr = await p2.evaluate(() => { const r = document.querySelector("#workspace").getBoundingClientRect(); return { x: r.x, w: r.width, y: r.y, h: r.height }; });
  await p2.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  await p2.mouse.down();
  await p2.mouse.move(wsr.x + wsr.w * 0.65, wsr.y + wsr.h / 2, { steps: 3 });
  const during = await p2.evaluate(() => localStorage.getItem("myttty.splitX"));
  await p2.mouse.up();
  const after = await p2.evaluate(() => localStorage.getItem("myttty.splitX"));
  assert(during === null, "no write during drag: " + during);
  assert(Math.abs(parseFloat(after) - 0.65) < 0.02, "written on pointerup: " + after);
  await p2.reload();
  await p2.waitForSelector(".pane .xterm");
  await p2.waitForTimeout(800);
  const size = await p2.evaluate(() => getComputedStyle(document.querySelector(".xterm-rows")).fontSize);
  assert(size === "16px", "font size persisted: " + size);
  console.log("prefs ok");

  assert(errors.length === 0, "errors: " + errors.join(" | "));
  console.log("editor: PASS");
  await browser.close();
})().catch((e) => { console.error(e.message || e); process.exit(1); });
