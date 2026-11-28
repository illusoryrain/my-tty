// 终端 cwd 同步：cd 后文件树跟随并滚动到可见位置；手动回到根目录后执行 pwd 会重新同步；
// 刷新旁的跟随开关可以关闭/重新开启同步。
const { chromium } = require("playwright");
const fs = require("fs");
const path = require("path");

const BASE = process.env.BASE;
const PASSWORD = process.env.PASSWORD;
const ROOT = process.env.ROOT;
const CHROME = process.env.CHROME || undefined;
const assert = (c, m) => { if (!c) throw new Error("ASSERT: " + m); };

(async () => {
  const sub = path.join(ROOT, "cwd-sub");
  fs.mkdirSync(sub, { recursive: true });
  // 足够多的同级目录，让目标前后都有内容，既需要滚动也能顶到列表顶部。
  const target = path.join(ROOT, "mid-cwd-target");
  fs.mkdirSync(target, { recursive: true });
  for (let i = 0; i < 40; i += 1) {
    fs.mkdirSync(path.join(ROOT, `aaa-pad-${String(i).padStart(2, "0")}`), { recursive: true });
    fs.mkdirSync(path.join(ROOT, `zzz-pad-${String(i).padStart(2, "0")}`), { recursive: true });
  }

  const browser = await chromium.launch({ executablePath: CHROME, args: ["--no-sandbox"] });
  const page = await browser.newPage({ viewport: { width: 1200, height: 800 } });
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  page.on("console", (m) => { if (m.type() === "error" && !m.text().includes("401")) errors.push(m.text()); });

  const activeCrumb = () =>
    page.evaluate(() => {
      const el = document.querySelector("#crumb button.active");
      return el ? el.textContent : "";
    });
  // 失败时带上步骤名：CI 只打印一行错误，没有 label 就不知道卡在哪。
  const waitFor = async (label, fn, arg, timeout = 10000) => {
    try {
      await page.waitForFunction(fn, arg, { timeout });
    } catch (err) {
      throw new Error(`${label}: ${err.message}`);
    }
  };
  const waitCrumb = (name) =>
    waitFor(
      `crumb ${name}`,
      (want) => {
        const el = document.querySelector("#crumb button.active");
        return !!el && el.textContent === want;
      },
      name
    );

  await page.goto(BASE + "/?debug=1");
  await page.fill("#login-password", PASSWORD);
  await page.click("#login-submit");
  await page.waitForSelector(".pane .xterm");
  await page.waitForSelector("#status.ok", { timeout: 10000 });
  await page.click("#toggle-files");
  await page.waitForSelector("#file-list");

  // cd 到 root 下的子目录：回车后客户端会主动请求 cwd。
  await page.locator(".pane-term").click();
  await page.keyboard.type(`cd '${sub}'\r`);
  await waitCrumb("cwd-sub");
  await waitFor("selected cwd-sub", () => {
    const el = document.querySelector("#file-list .entry.selected");
    return !!el && el.textContent.includes("cwd-sub");
  });

  // 在 shell 当前目录里创建文件后回车：不需要手动刷新也应该出现。
  const shellFile = "created-in-shell.txt";
  await page.locator(".pane-term").click();
  await page.keyboard.type(`touch '${shellFile}'\r`);
  await waitFor(
    "shell-created file row",
    (rel) => !!document.querySelector(`#file-list .entry[data-path="${rel}"]`),
    `${sub.replace(/^\/+/, "")}/${shellFile}`
  );

  // 手动把文件树切回根目录，再执行 pwd：树应重新跳到 shell 的 cwd。
  await page.locator("#crumb button").first().click();
  await waitCrumb("/");
  await page.locator(".pane-term").click();
  await page.keyboard.type("pwd\r");
  await waitCrumb("cwd-sub");
  assert((await activeCrumb()) === "cwd-sub", "pwd resyncs the tree");

  // cd 到树中靠后的目录：除了选中，还要尽量滚动到列表顶部。
  await page.locator(".pane-term").click();
  await page.keyboard.type(`cd '${target}'\r`);
  await waitCrumb("mid-cwd-target");
  await waitFor("selected scrolled to top", () => {
    const list = document.querySelector("#file-list");
    const sel = list.querySelector(".entry.selected");
    if (!sel) return false;
    const l = list.getBoundingClientRect();
    const r = sel.getBoundingClientRect();
    const gap = r.top - l.top;
    return list.scrollTop > 0 && gap >= -1 && gap <= 12;
  });

  // 关闭目录跟随后，cd 不再移动文件树。
  const syncBgOn = await page.evaluate(
    () => getComputedStyle(document.querySelector("#files-cwd-sync")).backgroundColor
  );
  await page.click("#files-cwd-sync");
  assert(
    (await page.getAttribute("#files-cwd-sync", "aria-pressed")) === "false",
    "cwd sync can be turned off"
  );
  const syncBgOff = await page.evaluate(
    () => getComputedStyle(document.querySelector("#files-cwd-sync")).backgroundColor
  );
  assert(syncBgOn !== syncBgOff, "cwd sync on/off state is visually distinct");
  await page.locator("#crumb button").first().click();
  await waitCrumb("/");
  await page.locator(".pane-term").click();
  await page.keyboard.type(`cd '${sub}'\r`);
  // 等 shell 真的 cd 完（服务端 cwd 已下发），否则重新开启同步时可能拿到旧值。
  await waitFor(
    "pane cwd while sync off",
    (want) => window.__myttyDebug?.panes?.[0]?.cwd === want,
    sub.replace(/^\/+/, "")
  );
  assert((await activeCrumb()) === "/", "tree stays put when cwd sync is off");

  // 重新开启：立即对齐到 shell 当前目录，不需要等到下一次 cd。
  await page.click("#files-cwd-sync");
  assert(
    (await page.getAttribute("#files-cwd-sync", "aria-pressed")) === "true",
    "cwd sync can be turned back on"
  );
  await waitCrumb("cwd-sub");

  assert(errors.length === 0, "console errors: " + errors.join(" | "));
  console.log("cwd: PASS");
  await browser.close();
})().catch((e) => { console.error(e.message || e); process.exit(1); });
