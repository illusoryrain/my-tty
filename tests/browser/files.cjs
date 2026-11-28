// 9 MiB 单次上传、下载往返、目录 tar、临时文件清理。
const { chromium } = require("playwright");
const fs = require("fs");
const os = require("os");
const path = require("path");

const BASE = process.env.BASE;
const PASSWORD = process.env.PASSWORD;
const ROOT = process.env.ROOT;
const CHROME = process.env.CHROME || undefined;
const assert = (c, m) => { if (!c) throw new Error("ASSERT: " + m); };
const ROOT_NAME = path.basename(ROOT);
const ROOT_REL = ROOT.replace(/^\/+/, "");
const rowFor = (rel) => `#file-list .entry[data-path="${rel}"]`;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

(async () => {
  // 源文件放在 /tmp 的子目录里：文件树会展开 /tmp，放在顶层会和上传目标同名。
  const srcDir = fs.mkdtempSync(path.join(os.tmpdir(), "mytty-src-"));
  const src = path.join(srcDir, "my-tty-upload-src.bin");
  const dst = path.join(srcDir, "my-tty-upload-dst.bin");
  const big = Buffer.alloc(9 * 1024 * 1024);
  for (let i = 0; i < big.length; i++) big[i] = (i * 31) & 0xff;
  fs.writeFileSync(src, big);

  const browser = await chromium.launch({ executablePath: CHROME, args: ["--no-sandbox"] });
  const page = await browser.newPage({ viewport: { width: 1200, height: 800 } });
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  page.on("console", (m) => { if (m.type() === "error" && !m.text().includes("401")) errors.push(m.text()); });

  await page.goto(BASE + "/");
  await page.fill("#login-password", PASSWORD);
  await page.click("#login-submit");
  await page.waitForSelector(".pane .xterm");
  await page.click("#toggle-files");
  await page.waitForSelector("#file-list");
  // 文件面板从 / 开始；终端在 HOME(=ROOT) 里，cwd 同步后停在测试目录。
  await page.waitForFunction(
    (name) => {
      const el = document.querySelector("#crumb button.active");
      return !!el && el.textContent === name;
    },
    ROOT_NAME,
    { timeout: 10000 }
  );

  // 文件工具栏的图标按钮是等宽高方形，避免不同符号宽度造成偏心。
  const iconSizes = await page.evaluate(() =>
    [...document.querySelectorAll(".files-head button.icon")].map((btn) => {
      const r = btn.getBoundingClientRect();
      return { w: r.width, h: r.height };
    })
  );
  assert(iconSizes.length >= 5, "files toolbar has icon buttons");
  assert(
    iconSizes.every((s) => Math.abs(s.w - s.h) <= 1),
    "files toolbar icons are square: " + JSON.stringify(iconSizes)
  );

  // 文件面板宽度可拖拽。
  const widthBefore = await page.evaluate(
    () => document.querySelector("#files").getBoundingClientRect().width
  );
  const handle = page.locator("#files-resize");
  const handleBox = await handle.boundingBox();
  await page.mouse.move(handleBox.x + handleBox.width / 2, handleBox.y + handleBox.height / 2);
  await page.mouse.down();
  await page.mouse.move(handleBox.x + handleBox.width / 2 + 70, handleBox.y + handleBox.height / 2, {
    steps: 5,
  });
  await page.mouse.up();
  await page.waitForTimeout(300);
  const widthAfter = await page.evaluate(
    () => document.querySelector("#files").getBoundingClientRect().width
  );
  assert(widthAfter > widthBefore + 40, "file panel width is resizable");

  // 新建文件名必须是应用内弹窗，而不是原生 prompt。
  await page.click("#files-new-file");
  await page.waitForSelector("#prompt-overlay:not([hidden])");
  await page.fill("#prompt-input", "created-by-modal.txt");
  await page.click("#prompt-ok");
  await page.waitForFunction(() => {
    const el = document.querySelector(".tab-workspace:not([hidden]) .editor-text");
    return !!el && !el.readOnly;
  });
  await page.locator(".tab.active .tab-close").click();
  await page.waitForFunction(() => !document.querySelector(".tab-workspace:not([hidden]) .editor-text"));
  await page.waitForTimeout(200);

  const uploadRel = `${ROOT_REL}/my-tty-upload-src.bin`;
  const target = path.join(ROOT, "my-tty-upload-src.bin");
  await page.setInputFiles("#upload-input", src);
  for (let i = 0; i < 200 && !fs.existsSync(target); i += 1) await sleep(100);
  if (!fs.existsSync(target)) {
    const crumb = await page.evaluate(
      () => document.querySelector("#crumb button.active")?.textContent || ""
    );
    const rootNames = fs.readdirSync(ROOT).join(",");
    throw new Error(`upload missing: root=${ROOT} crumb=${crumb} disk=[${rootNames}]`);
  }
  const onDisk = fs.readFileSync(target);
  assert(onDisk.equals(big), "9 MiB upload bytes match");

  const row = page.locator(rowFor(uploadRel));
  try {
    await row.waitFor({ state: "visible", timeout: 10000 });
  } catch (_) {
    const crumb = await page.evaluate(
      () => document.querySelector("#crumb button.active")?.textContent || ""
    );
    const paths = await page.evaluate(() =>
      [...document.querySelectorAll("#file-list .entry")].map((el) => el.dataset.path).slice(0, 100)
    );
    throw new Error(`upload row missing: root=${ROOT_REL} crumb=${crumb} paths=[${paths.join(",")}]`);
  }
  await row.hover();
  const [download] = await Promise.all([
    page.waitForEvent("download"),
    row.locator('button[title="下载"]').click(),
  ]);
  await download.saveAs(dst);
  assert(fs.readFileSync(dst).equals(big), "download bytes match");

  fs.mkdirSync(path.join(ROOT, "arch"), { recursive: true });
  fs.writeFileSync(path.join(ROOT, "arch", "x.txt"), "ARCHIVE_X");
  await page.click("#files-refresh");
  // 文件树用 content-visibility 跳过视口外的行，innerText 不含这些行；按行查询更稳。
  await page.waitForFunction(
    (rel) => !!document.querySelector(`#file-list .entry[data-path="${rel}"]`),
    `${ROOT_REL}/arch`
  );
  const dirRow = page.locator(rowFor(`${ROOT_REL}/arch`));
  await dirRow.locator(".caret").click();
  await page.locator(rowFor(`${ROOT_REL}/arch/x.txt`)).waitFor({ state: "visible", timeout: 8000 });
  await dirRow.hover();
  const [tar] = await Promise.all([
    page.waitForEvent("download"),
    dirRow.locator('button[title="下载目录（tar）"]').click(),
  ]);
  const tarPath = path.join(ROOT, "my-tty-arch.tar");
  await tar.saveAs(tarPath);
  assert(fs.statSync(tarPath).size > 512, "tar downloaded");
  assert(tar.suggestedFilename() === "arch.tar", "tar filename");

  // 重命名一个已经展开的目录：已加载的子树要跟着搬走，不能变成“未加载”。
  fs.mkdirSync(path.join(ROOT, "ren", "sub"), { recursive: true });
  fs.writeFileSync(path.join(ROOT, "ren", "sub", "kept.txt"), "KEPT");
  await page.click("#files-refresh");
  await page.waitForFunction(
    (rel) => !!document.querySelector(`#file-list .entry[data-path="${rel}"]`),
    `${ROOT_REL}/ren`
  );
  const renRow = page.locator(rowFor(`${ROOT_REL}/ren`));
  await renRow.locator(".caret").click();
  await page.locator(rowFor(`${ROOT_REL}/ren/sub`)).waitFor({ state: "visible", timeout: 8000 });
  await page.locator(rowFor(`${ROOT_REL}/ren/sub`)).locator(".caret").click();
  await page.locator(rowFor(`${ROOT_REL}/ren/sub/kept.txt`)).waitFor({ state: "visible", timeout: 8000 });

  await renRow.hover();
  await renRow.locator('button[title="重命名"]').click();
  await page.waitForSelector("#prompt-overlay:not([hidden])");
  await page.fill("#prompt-input", "ren2");
  await page.click("#prompt-ok");
  await page.waitForFunction(
    (rel) => !!document.querySelector(`#file-list .entry[data-path="${rel}"]`),
    `${ROOT_REL}/ren2`
  );
  await page.locator(rowFor(`${ROOT_REL}/ren2/sub`)).waitFor({ state: "visible", timeout: 8000 });
  await page.locator(rowFor(`${ROOT_REL}/ren2/sub/kept.txt`)).waitFor({ state: "visible", timeout: 8000 });

  // 新建目录允许输入多级路径：树必须展开并加载祖先，让新目录可达。
  await page.click("#files-new-dir");
  await page.waitForSelector("#prompt-overlay:not([hidden])");
  await page.fill("#prompt-input", "nested/inner");
  await page.click("#prompt-ok");
  await page.waitForFunction(() => {
    const el = document.querySelector("#crumb button.active");
    return !!el && el.textContent === "inner";
  });
  await page.locator(rowFor(`${ROOT_REL}/nested/inner`)).waitFor({ state: "visible", timeout: 8000 });

  const leftovers = fs.readdirSync(ROOT).filter((n) => n.startsWith(".myty-upload-"));
  assert(leftovers.length === 0, "no temp files");
  assert(errors.length === 0, "console errors: " + errors.join(" | "));
  fs.rmSync(srcDir, { recursive: true, force: true });
  console.log("files: PASS");
  await browser.close();
})().catch((e) => { console.error(e.message || e); process.exit(1); });
