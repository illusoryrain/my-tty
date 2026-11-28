// 终端复制/粘贴：Ctrl+C 有选区复制、无选区中断；Ctrl+V / Ctrl+Shift+V /
// Shift+Insert 粘贴；Ctrl+Shift+C 复制且挡掉浏览器 DevTools 快捷键。
const { chromium } = require("playwright");

const BASE = process.env.BASE;
const PASSWORD = process.env.PASSWORD;
const CHROME = process.env.CHROME || undefined;
const assert = (c, m) => { if (!c) throw new Error("ASSERT: " + m); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

(async () => {
  const browser = await chromium.launch({ executablePath: CHROME, args: ["--no-sandbox"] });
  const context = await browser.newContext({
    viewport: { width: 1100, height: 700 },
    permissions: ["clipboard-read", "clipboard-write"],
  });
  const page = await context.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  page.on("console", (m) => { if (m.type() === "error" && !m.text().includes("401")) errors.push(m.text()); });

  await page.goto(BASE + "/?debug=1");
  await page.fill("#login-password", PASSWORD);
  await page.click("#login-submit");
  await page.waitForSelector(".pane .xterm");
  await page.waitForTimeout(900);

  const readClipboard = () => page.evaluate(() => navigator.clipboard.readText());
  const writeClipboard = (text) => page.evaluate((t) => navigator.clipboard.writeText(t), text);
  const termText = () => page.locator(".xterm-rows").innerText();

  const selectAllWithMouse = async () => {
    const box = await page.locator(".xterm-screen").boundingBox();
    await page.mouse.move(box.x + 5, box.y + 5);
    await page.mouse.down();
    await page.mouse.move(box.x + box.width - 5, box.y + box.height - 5, { steps: 8 });
    await page.mouse.up();
    await page.waitForTimeout(200);
  };

  await page.locator(".pane-term").click();
  await page.keyboard.type("echo COPY_TOKEN_123\r");
  await page.waitForTimeout(600);

  await page.evaluate(() => {
    window.__keys = [];
    window.addEventListener("keydown", (e) => {
      if (e.code === "KeyC" && e.shiftKey) {
        setTimeout(() => window.__keys.push({ prevented: e.defaultPrevented }), 0);
      }
    }, true);
  });

  // 有选区时 Ctrl+C = 复制
  await selectAllWithMouse();
  await writeClipboard("SENTINEL_1");
  await page.keyboard.press("Control+C");
  await page.waitForTimeout(300);
  const copied = await readClipboard();
  assert(copied !== "SENTINEL_1", "Ctrl+C with selection wrote clipboard");
  assert(copied.includes("COPY_TOKEN_123"), "Ctrl+C copied selection: " + JSON.stringify(copied.slice(0, 100)));
  assert((await page.evaluate(() => document.querySelectorAll(".xterm-selection div").length)) === 0, "copy clears selection");

  // Ctrl+Shift+C 也复制，并且 preventDefault（不会落到浏览器的 DevTools 快捷键）
  await selectAllWithMouse();
  await writeClipboard("SENTINEL_2");
  await page.keyboard.press("Control+Shift+C");
  await page.waitForTimeout(300);
  const copied2 = await readClipboard();
  assert(copied2 !== "SENTINEL_2" && copied2.includes("COPY_TOKEN_123"), "Ctrl+Shift+C copies");
  const prevented = await page.evaluate(() => window.__keys);
  assert(prevented.length > 0 && prevented.every((k) => k.prevented), "Ctrl+Shift+C preventDefault: " + JSON.stringify(prevented));
  await page.evaluate(() => { window.__keys = []; });

  // 无选区时 Ctrl+C = ^C
  await page.locator(".pane-term").click({ position: { x: 10, y: 10 } });
  await page.keyboard.type("sleep 30\r");
  await sleep(400);
  await page.keyboard.press("Control+C");
  await page.waitForTimeout(400);
  await page.keyboard.type("echo AFTER_INTERRUPT\r");
  await page.waitForTimeout(500);
  assert((await termText()).includes("AFTER_INTERRUPT"), "Ctrl+C without selection interrupts");
  await page.keyboard.press("Control+U");

  // 粘贴：Ctrl+V / Ctrl+Shift+V / Shift+Insert
  await writeClipboard("PASTE_V_TOKEN");
  await page.keyboard.press("Control+V");
  await page.waitForTimeout(400);
  assert((await termText()).includes("PASTE_V_TOKEN"), "Ctrl+V pastes");
  await page.keyboard.press("Control+U");

  await writeClipboard("PASTE_CSV_TOKEN");
  await page.keyboard.press("Control+Shift+V");
  await page.waitForTimeout(400);
  assert((await termText()).includes("PASTE_CSV_TOKEN"), "Ctrl+Shift+V pastes");
  await page.keyboard.press("Control+U");

  await writeClipboard("PASTE_INSERT_TOKEN");
  await page.keyboard.press("Shift+Insert");
  await page.waitForTimeout(400);
  assert((await termText()).includes("PASTE_INSERT_TOKEN"), "Shift+Insert pastes");
  await page.keyboard.press("Control+U");

  // 浏览器没有 Clipboard API 时走 textarea 兜底；复制后必须把焦点还给终端。
  await page.evaluate(() => {
    Object.defineProperty(navigator, "clipboard", { value: undefined, configurable: true });
  });
  await page.locator(".pane .xterm-helper-textarea").focus();
  await page.evaluate(() => window.__myttyDebug.panes[0].term.selectAll());
  assert((await page.evaluate(() => window.__myttyDebug.panes[0].term.getSelection().length)) > 0, "legacy copy has selection");
  await page.keyboard.press("Control+C");
  await page.waitForTimeout(300);
  const focusBack = await page.evaluate(() =>
    document.activeElement === document.querySelector(".pane .xterm-helper-textarea")
  );
  assert(focusBack, "legacy copy restores terminal focus");

  assert(errors.length === 0, "console errors: " + errors.join(" | "));
  console.log("clipboard: PASS");
  await browser.close();
})().catch((e) => { console.error(e.message || e); process.exit(1); });
