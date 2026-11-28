// 手机软键盘输入只发一次：覆盖 keyup 早于 input、input 非 composed 等顺序。
const { chromium } = require("playwright");
const fs = require("fs");
const path = require("path");

const BASE = process.env.BASE;
const PASSWORD = process.env.PASSWORD;
const CHROME = process.env.CHROME || undefined;
const assert = (c, m) => { if (!c) throw new Error("ASSERT: " + m); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

(async () => {
  const browser = await chromium.launch({ executablePath: CHROME, args: ["--no-sandbox"] });
  const context = await browser.newContext({
    viewport: { width: 390, height: 844 },
    isMobile: true,
    hasTouch: true,
    deviceScaleFactor: 3,
  });
  await context.addInitScript(() => {
    window.__sent = [];
    const orig = WebSocket.prototype.send;
    WebSocket.prototype.send = function (data) {
      if (typeof data !== "string") {
        try {
          window.__sent.push(new TextDecoder().decode(new Uint8Array(data)));
        } catch (_) {}
      }
      return orig.call(this, data);
    };
  });
  const page = await context.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));

  await page.goto(BASE + "/");
  await page.waitForSelector("#login-overlay:not([hidden])");
  await page.fill("#login-password", PASSWORD);
  await page.click("#login-submit");
  await page.waitForSelector(".pane .xterm");
  await page.waitForFunction(() => document.querySelector("#status").textContent.includes("已连接"));

  assert(
    await page.evaluate(() => matchMedia("(pointer: coarse)").matches),
    "mobile context must report a coarse pointer"
  );

  const drain = async () => {
    await sleep(150);
    return page.evaluate(() => {
      const s = window.__sent;
      window.__sent = [];
      return s;
    });
  };

  // 一组按键在同一个任务里派发，模拟一台设备能给出的最紧凑顺序。
  const press = (steps, composed) =>
    page.evaluate(({ steps, composed }) => {
      const ta = document.querySelector(".xterm-helper-textarea");
      ta.focus();
      const kd = () => {
        const ev = new KeyboardEvent("keydown", {
          key: "Unidentified",
          bubbles: true,
          cancelable: true,
          composed: true,
        });
        Object.defineProperty(ev, "keyCode", { get: () => 229 });
        ta.dispatchEvent(ev);
      };
      const ku = () => {
        const ev = new KeyboardEvent("keyup", {
          key: "Unidentified",
          bubbles: true,
          cancelable: true,
          composed: true,
        });
        Object.defineProperty(ev, "keyCode", { get: () => 76 });
        ta.dispatchEvent(ev);
      };
      const ins = () => {
        ta.value += "l";
        ta.dispatchEvent(new InputEvent("beforeinput", {
          inputType: "insertText",
          data: "l",
          composed,
          bubbles: true,
          cancelable: true,
        }));
        ta.dispatchEvent(new InputEvent("input", {
          inputType: "insertText",
          data: "l",
          composed,
          bubbles: true,
          cancelable: true,
        }));
      };
      for (const step of steps) {
        if (step === "kd") kd();
        else if (step === "ku") ku();
        else ins();
      }
    }, { steps, composed });

  async function expectOnce(name, steps, composed, count) {
    await drain();
    await page.evaluate(() => {
      document.querySelector(".xterm-helper-textarea").value = "";
    });
    for (let i = 0; i < count; i++) {
      await press(steps, composed);
      await sleep(40);
    }
    const out = await drain();
    const got = out.join("");
    assert(got.length === count, `${name}: expected ${count} chars, got ${JSON.stringify(out)}`);
  }

  await expectOnce("keydown -> input -> keyup", ["kd", "ins", "ku"], true, 3);
  await expectOnce("keydown -> keyup -> input", ["kd", "ku", "ins"], true, 3);
  await expectOnce("input -> keydown -> keyup", ["ins", "kd", "ku"], true, 3);
  await expectOnce("input only (no key events)", ["ins"], true, 3);
  await expectOnce("non-composed input", ["kd", "ins", "ku"], false, 3);

  // 229 keydown 之后 textarea 变短：仍应只发一个退格。
  await drain();
  await page.evaluate(() => {
    const ta = document.querySelector(".xterm-helper-textarea");
    ta.value = "l";
    ta.focus();
    const kd = new KeyboardEvent("keydown", { key: "Unidentified", bubbles: true, cancelable: true, composed: true });
    Object.defineProperty(kd, "keyCode", { get: () => 229 });
    ta.dispatchEvent(kd);
    ta.value = "";
    ta.dispatchEvent(new InputEvent("beforeinput", { inputType: "deleteContentBackward", data: null, bubbles: true, cancelable: true, composed: true }));
    ta.dispatchEvent(new InputEvent("input", { inputType: "deleteContentBackward", data: null, bubbles: true, cancelable: true, composed: true }));
  });
  const del = await drain();
  assert(del.join("") === "\x7f", `backspace: expected one DEL, got ${JSON.stringify(del)}`);

  // 229 keydown 之后的回车也只发一次。
  await drain();
  await page.evaluate(() => {
    const ta = document.querySelector(".xterm-helper-textarea");
    ta.value = "";
    ta.focus();
    const kd = new KeyboardEvent("keydown", { key: "Unidentified", bubbles: true, cancelable: true, composed: true });
    Object.defineProperty(kd, "keyCode", { get: () => 229 });
    ta.dispatchEvent(kd);
    ta.value = "\n";
    ta.dispatchEvent(new InputEvent("beforeinput", { inputType: "insertLineBreak", data: null, bubbles: true, cancelable: true, composed: true }));
    ta.dispatchEvent(new InputEvent("input", { inputType: "insertLineBreak", data: null, bubbles: true, cancelable: true, composed: true }));
  });
  const enter = await drain();
  assert(enter.join("") === "\n", `enter: expected one newline, got ${JSON.stringify(enter)}`);

  // 编辑标签激活时，触屏设备上那条失效的 Esc/Tab/Ctrl 按键条必须真正隐藏。
  await page.locator(".pane-term").first().click();
  await page.keyboard.type("printf 'x\\n' > mobile-edit.txt\r");
  for (let i = 0; i < 50 && !fs.existsSync(path.join(process.env.ROOT, "mobile-edit.txt")); i++) await sleep(100);
  await page.click("#toggle-files");
  await page.click("#files-refresh");
  const mobileFile = page.locator("#file-list .entry.file", { hasText: "mobile-edit.txt" });
  await mobileFile.locator(".name").click();
  await page.waitForSelector(".tab-workspace:not([hidden]) .editor-text");
  const keys = await page.evaluate(() => {
    const el = document.querySelector("#keys");
    return { hidden: el.hidden, display: getComputedStyle(el).display };
  });
  assert(keys.hidden && keys.display === "none", "keys bar hidden for editor: " + JSON.stringify(keys));

  assert(errors.length === 0, "page errors: " + errors.join(" | "));
  await browser.close();
  console.log("mobile_input: PASS");
})().catch((e) => {
  console.error("mobile_input: FAIL:", e.message);
  process.exit(1);
});
