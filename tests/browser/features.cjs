// 字号、搜索、拖拽分栏、编辑器行号与 Tab。
const { chromium } = require("playwright");
const fs = require("fs");
const path = require("path");

const BASE = process.env.BASE;
const PASSWORD = process.env.PASSWORD;
const ROOT = process.env.ROOT;
const CHROME = process.env.CHROME || undefined;
const assert = (c, m) => { if (!c) throw new Error("ASSERT: " + m); };
const ROOT_NAME = path.basename(ROOT);

(async () => {
  fs.writeFileSync(path.join(ROOT, "lines.txt"), "one\ntwo\nthree\n");
  const browser = await chromium.launch({ executablePath: CHROME, args: ["--no-sandbox"] });
  const page = await browser.newPage({ viewport: { width: 1200, height: 800 } });
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  page.on("console", (m) => { if (m.type() === "error" && !m.text().includes("401")) errors.push(m.text()); });

  await page.goto(BASE + "/");
  await page.fill("#login-password", PASSWORD);
  await page.click("#login-submit");
  await page.waitForSelector(".pane .xterm");
  await page.waitForTimeout(800);

  const before = await page.evaluate(() => getComputedStyle(document.querySelector(".xterm-rows")).fontSize);
  await page.click("#font-inc");
  await page.waitForTimeout(400);
  const after = await page.evaluate(() => getComputedStyle(document.querySelector(".xterm-rows")).fontSize);
  assert(before === "14px" && after === "15px", `font size ${before} -> ${after}`);
  await page.click("#font-dec");

  // 顶栏 ^C：不依赖键盘 Ctrl（RDP 等环境）
  await page.locator(".pane-term").click();
  await page.keyboard.type("sleep 30\r");
  await page.waitForTimeout(400);
  await page.click("#send-interrupt");
  await page.keyboard.type("printf 'INTERRUPT_BTN_%s\\n' OK\r");
  await page.waitForFunction(
    () => document.querySelector(".xterm-rows").innerText.includes("INTERRUPT_BTN_OK"),
    null,
    { timeout: 8000 }
  );

  // Safari / 输入法丢字回归：keydown 之后到达的 composed insertText 不能被
  // xterm 的 _keyDownSeen 去重逻辑吞掉。
  await page.locator(".pane-term").click();
  await page.keyboard.type("printf 'READY_%s\\n' MARK; read -r X; echo ILEN=${#X}; echo IVAL=$X\r");
  await page.waitForFunction(
    () => document.querySelector(".xterm-rows").innerText.includes("READY_MARK"),
    null,
    { timeout: 8000 }
  );
  await page.evaluate(() => {
    const ta = document.querySelector(".xterm-helper-textarea");
    ta.focus();
    ta.dispatchEvent(new KeyboardEvent("keydown", { key: "Process", bubbles: true, cancelable: true }));
    const opts = { data: "Z", inputType: "insertText", composed: true, bubbles: true, cancelable: true };
    ta.dispatchEvent(new InputEvent("beforeinput", opts));
    ta.dispatchEvent(new InputEvent("input", opts));
  });
  await page.keyboard.press("Enter");
  await page.waitForFunction(
    () => document.querySelector(".xterm-rows").innerText.includes("IVAL=Z"),
    null,
    { timeout: 8000 }
  );
  assert(
    (await page.locator(".xterm-rows").innerText()).includes("ILEN=1"),
    "composed insertText is not dropped"
  );

  // 移动端重复输入回归：keydown 已经发出字符后，浏览器又补发一次 composed
  // insertText。不能再清 _keyDownSeen，否则 Z 会变成 ZZ（ls -> llss）。
  await page.keyboard.type("printf 'READY2_%s\\n' MARK; read -r Y; echo YLEN=${#Y}; echo YVAL=$Y\r");
  await page.waitForFunction(
    () => document.querySelector(".xterm-rows").innerText.includes("READY2_MARK"),
    null,
    { timeout: 8000 }
  );
  await page.evaluate(() => document.querySelector(".xterm-helper-textarea").focus());
  await page.keyboard.down("Z");
  await page.evaluate(() => {
    const ta = document.querySelector(".xterm-helper-textarea");
    ta.focus();
    const opts = { data: "Z", inputType: "insertText", composed: true, bubbles: true, cancelable: true };
    ta.dispatchEvent(new InputEvent("beforeinput", opts));
    ta.dispatchEvent(new InputEvent("input", opts));
  });
  await page.keyboard.up("Z");
  await page.keyboard.press("Enter");
  await page.waitForFunction(
    () => document.querySelector(".xterm-rows").innerText.includes("YVAL=Z"),
    null,
    { timeout: 8000 }
  );
  assert(
    (await page.locator(".xterm-rows").innerText()).includes("YLEN=1"),
    "composed insertText after keydown must not double the character"
  );

  // keydown 已经发出字符（Enter）后，紧随其后的 keypress 不能再发一次：
  // app.js 用 _keyDownHandled 压掉第二条键盘路径。
  const keyFrames = await page.evaluate(async () => {
    const ta = document.querySelector(".xterm-helper-textarea");
    const orig = WebSocket.prototype.send;
    const sent = [];
    WebSocket.prototype.send = function (data) {
      if (typeof data !== "string") {
        try {
          sent.push(new TextDecoder().decode(new Uint8Array(data)));
        } catch (_) {}
      }
      return orig.call(this, data);
    };
    ta.focus();
    const kd = new KeyboardEvent("keydown", { key: "Enter", code: "Enter", bubbles: true, cancelable: true });
    Object.defineProperty(kd, "keyCode", { get: () => 13 });
    Object.defineProperty(kd, "which", { get: () => 13 });
    ta.dispatchEvent(kd);
    const kp = new KeyboardEvent("keypress", { key: "Enter", bubbles: true, cancelable: true });
    Object.defineProperty(kp, "keyCode", { get: () => 13 });
    Object.defineProperty(kp, "charCode", { get: () => 13 });
    Object.defineProperty(kp, "which", { get: () => 13 });
    ta.dispatchEvent(kp);
    await new Promise((resolve) => setTimeout(resolve, 50));
    WebSocket.prototype.send = orig;
    return sent;
  });
  assert(
    keyFrames.join("") === "\r",
    "keydown-sent Enter must not be sent again by keypress: " + JSON.stringify(keyFrames)
  );

  await page.locator(".pane-term").click();
  await page.keyboard.type("printf 'FIND_%s\\nOTHER\\nFIND\\n' MARK\r");
  await page.waitForFunction(
    () => document.querySelector(".xterm-rows").innerText.includes("FIND_MARK"),
    null,
    { timeout: 8000 }
  );
  await page.keyboard.press("Control+Shift+F");
  await page.waitForSelector("#find-bar:not([hidden])");
  await page.fill("#find-input", "FIND");
  await page.waitForFunction(
    () => document.querySelectorAll(".xterm-selection div").length > 0,
    null,
    { timeout: 8000 }
  );
  await page.keyboard.press("Escape");

  await page.click("#add-pane");
  await page.waitForTimeout(600);
  const splitter = page.locator(".splitter.v");
  assert(await splitter.isVisible(), "splitter visible");
  const box = await splitter.boundingBox();
  const ws = await page.evaluate(() => { const r = document.querySelector("#workspace").getBoundingClientRect(); return { x: r.x, w: r.width, y: r.y, h: r.height }; });
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  await page.mouse.down();
  await page.mouse.move(ws.x + ws.w * 0.7, ws.y + ws.h / 2, { steps: 5 });
  await page.mouse.up();
  await page.waitForTimeout(400);
  const cols = await page.evaluate(
    () => document.querySelector(".tab-workspace:not([hidden])").style.gridTemplateColumns
  );
  const [c1, c2] = cols.split(" ").map(parseFloat);
  assert(Math.abs(c1 - 0.7) < 0.02 && Math.abs(c2 - 0.3) < 0.02, "splitter moved: " + cols);

  // 3 屏时右列上下分栏也必须能拖。
  await page.click("#add-pane");
  await page.waitForTimeout(600);
  const hsplit = page.locator(".splitter.h");
  assert(await hsplit.isVisible(), "horizontal splitter visible with 3 panes");
  const hbox = await hsplit.boundingBox();
  await page.mouse.move(hbox.x + hbox.width / 2, hbox.y + hbox.height / 2);
  await page.mouse.down();
  await page.mouse.move(ws.x + ws.w * 0.8, ws.y + ws.h * 0.7, { steps: 5 });
  await page.mouse.up();
  await page.waitForTimeout(400);
  const rows = await page.evaluate(
    () => document.querySelector(".tab-workspace:not([hidden])").style.gridTemplateRows
  );
  const [r1, r2] = rows.split(" ").map(parseFloat);
  assert(Math.abs(r1 - 0.7) < 0.02 && Math.abs(r2 - 0.3) < 0.02, "horizontal splitter moved: " + rows);

  await page.click("#toggle-files");
  await page.waitForFunction(
    (name) => {
      const el = document.querySelector("#crumb button.active");
      return !!el && el.textContent === name;
    },
    ROOT_NAME,
    { timeout: 10000 }
  );
  await page.locator("#file-list .entry.file", { hasText: "lines.txt" }).waitFor();
  await page.locator("#file-list .entry.file", { hasText: "lines.txt" }).locator(".name").click();
  await page.waitForFunction(() => {
    const el = document.querySelector(".tab-workspace:not([hidden]) .editor-text");
    return !!el && !el.readOnly;
  });
  assert(
    (await page.textContent(".tab-workspace:not([hidden]) .editor-gutter")).trim().split("\n").length === 3,
    "gutter lines"
  );
  await page.evaluate(() => {
    const el = document.querySelector(".tab-workspace:not([hidden]) .editor-text");
    el.focus();
    el.setSelectionRange(3, 3);
  });
  await page.keyboard.press("Tab");
  assert(
    (await page.inputValue(".tab-workspace:not([hidden]) .editor-text")).split("\n")[0].endsWith("  "),
    "tab indents"
  );
  // Tab 缩进把文件改脏了，Esc 关闭会先弹“放弃未保存的修改”。
  await page.keyboard.press("Escape");
  await page.waitForSelector("#prompt-overlay:not([hidden])");
  await page.click("#prompt-ok");
  await page.waitForFunction(() => !document.querySelector(".tab-workspace:not([hidden]) .editor-text"));

  assert(errors.length === 0, "console errors: " + errors.join(" | "));
  console.log("features: PASS");
  await browser.close();
})().catch((e) => { console.error(e.message || e); process.exit(1); });
