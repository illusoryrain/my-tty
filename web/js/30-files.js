  // -------------------------------------------------------------------- files

  async function api(method, action, query, body) {
    const epoch = authEpoch;
    const qs = query ? `?${new URLSearchParams(query)}` : "";
    const headers = {};
    if (body !== undefined) headers["Content-Type"] = "text/plain; charset=utf-8";
    const res = await fetch(`/api/fs/${action}${qs}`, { method, headers, body });
    let data = {};
    try {
      data = await res.json();
    } catch (_) {}
    if (res.status === 401) {
      // 请求发出后用户可能已经重新登录；旧的 401 不能把登录框再弹出来。
      if (epoch === authEpoch) {
        markAuthStopped();
        showLogin("登录已失效，请重新登录");
      }
      throw new Error("unauthorized");
    }
    if (!res.ok) {
      const err = new Error(data.error || `HTTP ${res.status}`);
      err.code = data.error || "";
      throw err;
    }
    return data;
  }

  function joinPath(dir, name) {
    return dir ? `${dir}/${name}` : name;
  }

  function parentOf(path) {
    const i = path.lastIndexOf("/");
    return i === -1 ? "" : path.slice(0, i);
  }

  function notice(text, isError) {
    noticeEl.textContent = text || "";
    noticeEl.className = isError ? "error" : "";
    if (text) clearTimeout(notice._t);
    if (text) notice._t = setTimeout(() => (noticeEl.textContent = ""), 4000);
  }

  function setFilesWidth(next, persist = false) {
    const body = filesEl.parentElement;
    const max = Math.max(200, body.clientWidth - 320);
    filesWidth = Math.round(Math.min(Math.max(next, 180), max));
    filesEl.style.setProperty("--files-width", `${filesWidth}px`);
    if (persist) store.set("myttty.filesWidth", String(filesWidth));
  }

  function setCwdSync(enabled, persist = true) {
    cwdSyncEnabled = enabled;
    cwdSyncBtn.classList.toggle("off", !enabled);
    cwdSyncBtn.setAttribute("aria-pressed", enabled ? "true" : "false");
    cwdSyncBtn.title = enabled ? "目录跟随：开（点击关闭）" : "目录跟随：关（点击开启）";
    if (persist) store.set("myttty.cwdSync", enabled ? "1" : "0");
    if (!enabled || !activePane) return;
    // 重新开启时立即对齐；请求一次 cwd 覆盖关闭期间发生的 cd。
    if (activePane.cwd) syncFilesToCwd(activePane.cwd);
    requestCwd(activePane);
  }

  function startFilesResize(ev) {
    ev.preventDefault();
    const el = filesResizeEl;
    el.setPointerCapture(ev.pointerId);
    el.classList.add("dragging");
    const bodyLeft = filesEl.parentElement.getBoundingClientRect().left;

    const move = (e) => setFilesWidth(e.clientX - bodyLeft);
    const up = () => {
      el.classList.remove("dragging");
      el.removeEventListener("pointermove", move);
      el.removeEventListener("pointerup", up);
      el.removeEventListener("pointercancel", up);
      setFilesWidth(filesWidth, true);
    };

    el.addEventListener("pointermove", move);
    el.addEventListener("pointerup", up);
    el.addEventListener("pointercancel", up);
  }

  /// 重新读取树根、当前目录，以及调用方明确改动过的目录。
  ///
  /// 以前这里会把所有展开过的目录都重读一遍：浏览过十几个目录之后，一次上传
  /// 就会重新拉取十几份列表（可能几 MB JSON）。终端里的 cwd 变化已经由
  /// applyDir(force) 处理，这里只需要覆盖 UI 操作真正影响到的目录。
  async function refreshFiles(touched) {
    const dirs = new Set(["", currentDir]);
    for (const dir of touched || []) {
      if (typeof dir === "string") dirs.add(dir);
    }
    const failed = [];
    let truncated = false;

    await Promise.all(
      [...dirs].map(async (dir) => {
        try {
          const data = await loadDir(dir);
          if (data.truncated) truncated = true;
        } catch (err) {
          failed.push({ dir, err });
        }
      })
    );

    for (const item of failed) {
      if (item.dir === "") {
        treeRootError = true;
      } else if (item.err.code === "not_found") {
        removeMissingDir(item.dir);
      } else {
        treeExpanded.delete(item.dir);
        treeChildren.delete(item.dir);
        treeDirty = true;
      }
      notice(
        item.err.code === "not_found"
          ? `目录已不存在: ${item.dir || "/"}`
          : `列目录失败: ${item.err.message}`,
        true
      );
    }
    if (!failed.some((item) => item.dir === "")) treeRootError = false;
    currentDir = loadedAncestor(currentDir);

    renderCrumbs();
    renderTree();
    if (truncated) notice("部分目录条目过多，仅显示前 1 万项");
  }

  function sameEntries(a, b) {
    if (a.length !== b.length) return false;
    for (let i = 0; i < a.length; i++) {
      if (a[i].name !== b[i].name || a[i].kind !== b[i].kind || a[i].size !== b[i].size) {
        return false;
      }
    }
    return true;
  }

  async function loadDir(path) {
    const data = await api("GET", "list", { path });
    const result = { entries: data.entries || [], truncated: !!data.truncated };
    const prev = treeChildren.get(path);
    if (!prev || prev.truncated !== result.truncated || !sameEntries(prev.entries, result.entries)) {
      treeDirty = true;
    }
    treeChildren.set(path, result);
    // 只缓存最近浏览的目录，避免长时间使用后无限增长；展开中的目录保留，
    // 否则树里会出现“状态还在展开、子节点却没了”的空洞。
    if (treeChildren.size > 256) {
      for (const key of treeChildren.keys()) {
        if (key !== "" && key !== path && !treeExpanded.has(key)) {
          treeChildren.delete(key);
          break;
        }
      }
    }
    return result;
  }

  function expandPath(path) {
    treeDirty = true;
    treeExpanded.add("");
    let acc = "";
    for (const part of path.split("/")) {
      if (!part) continue;
      acc = joinPath(acc, part);
      treeExpanded.add(acc);
    }
  }

  function pathPrefixes(path) {
    const list = [""];
    let acc = "";
    for (const part of path.split("/")) {
      if (!part) continue;
      acc = joinPath(acc, part);
      list.push(acc);
    }
    return list;
  }

  /// 从 path 开始往上找第一个已经有缓存的目录；root 没加载时返回 ""。
  function loadedAncestor(path) {
    let p = path;
    while (p && !treeChildren.has(p)) p = parentOf(p);
    return p;
  }

  /// 目录在列出后消失（/proc 的 PID、被其他进程删掉的目录）：把父目录里的
  /// 旧行和它自己的缓存一起清掉，并把当前位置退回最近的已加载祖先，
  /// 不要停在一条永远打不开的路径上。
  function removeMissingDir(path) {
    if (!path) return;
    const parent = parentOf(path);
    const data = treeChildren.get(parent);
    if (data) {
      const name = baseName(path);
      const entries = data.entries.filter((entry) => entry.name !== name);
      if (entries.length !== data.entries.length) {
        treeChildren.set(parent, { entries, truncated: data.truncated });
      }
    }
    dropTreePath(path);
    currentDir = loadedAncestor(currentDir);
    renderCrumbs();
  }

  async function ensureTreeLoaded(path, force = false) {
    const pending = treeLoads.get(path);
    if (pending) return await pending;
    if (!force && treeChildren.has(path)) return true;

    treeLoading.add(path);
    if (!treeChildren.has(path)) scheduleRender();
    const task = (async () => {
      try {
        const data = await loadDir(path);
        if (data.truncated) notice(`目录 ${path || "/"} 条目过多，仅显示前 1 万项`);
        return true;
      } catch (err) {
        if (err.code === "not_found") {
          removeMissingDir(path);
          notice(`目录已不存在: ${path || "/"}`, true);
        } else {
          if (!treeChildren.has(path)) treeExpanded.delete(path);
          treeDirty = true;
          notice(`列目录失败: ${err.message}`, true);
        }
        return false;
      }
    })();
    treeLoads.set(path, task);
    try {
      return await task;
    } finally {
      treeLoading.delete(path);
      treeLoads.delete(path);
      scheduleRenderWhenIdle();
    }
  }

  function applyDir(path, force = false, alignTop = false) {
    currentDir = path;
    expandPath(path);
    // 面板关着时只记住位置，等打开时 refreshFiles() 一次性加载。
    if (filesEl.hidden) return;
    renderCrumbs();
    renderTree();
    scrollTreeToSelected(alignTop);
    const pending = pathPrefixes(path).map((prefix) => ensureTreeLoaded(prefix, force));
    Promise.all(pending).then(() => {
      if (currentDir !== path || filesEl.hidden) return;
      if (!treeChildren.has(path)) {
        // 目标目录没加载成功；ensureTreeLoaded 已经提示过了，这里只负责
        // 把当前位置退回到最近一个能显示的祖先。
        currentDir = loadedAncestor(parentOf(path));
        renderCrumbs();
        renderTree();
        scrollTreeToSelected(alignTop);
        return;
      }
      scrollTreeToSelected(alignTop);
    });
  }

  function selectDir(path) {
    if (path === currentDir && treeExpanded.has(path)) return;
    applyDir(path);
  }

  /// shell 的 cwd 变化或用户按回车后，把文件树跳到对应目录。
  /// 强制重读路径上的目录，终端里新建的目录也能立即出现在树里。
  function syncFilesToCwd(path) {
    if (typeof path !== "string") return;
    if (path === currentDir) {
      // 终端里执行 touch/mkdir 后 cwd 不变，但目录内容可能变了；回车会主动
      // 请求一次 cwd，这里强制重读当前目录，而不是因为路径相同直接返回。
      if (!filesEl.hidden) ensureTreeLoaded(path, true);
      return;
    }
    applyDir(path, true, true);
  }

  function toggleDir(path) {
    treeDirty = true;
    if (treeExpanded.has(path)) {
      treeExpanded.delete(path);
      renderTree();
      return;
    }
    treeExpanded.add(path);
    ensureTreeLoaded(path, true);
    renderTree();
  }

  function dropTreePath(path) {
    treeDirty = true;
    for (const p of [...treeExpanded]) {
      if (p === path || p.startsWith(`${path}/`)) treeExpanded.delete(p);
    }
    for (const p of [...treeChildren.keys()]) {
      if (p === path || p.startsWith(`${path}/`)) treeChildren.delete(p);
    }
    if (currentDir === path || currentDir.startsWith(`${path}/`)) {
      currentDir = parentOf(path);
    }
  }

  function rebaseTree(oldPath, newPath) {
    treeDirty = true;
    const mapped = (p) =>
      p === oldPath
        ? newPath
        : p.startsWith(`${oldPath}/`)
          ? newPath + p.slice(oldPath.length)
          : p;

    for (const p of [...treeExpanded]) {
      if (p === oldPath || p.startsWith(`${oldPath}/`)) {
        treeExpanded.delete(p);
        treeExpanded.add(mapped(p));
      }
    }
    // 把已经加载过的子树跟着目录一起搬走，否则重命名后展开状态还在、
    // 子节点却被删掉，界面会显示“未加载”。覆盖目标目录的旧缓存也一并丢弃。
    // 先删目标、再搬来源：否则来源的缓存可能搬进目标后又被目标清理删掉。
    const cached = [...treeChildren];
    for (const [p] of cached) {
      if (p === newPath || p.startsWith(`${newPath}/`)) treeChildren.delete(p);
    }
    for (const [p, data] of cached) {
      if (p === oldPath || p.startsWith(`${oldPath}/`)) {
        treeChildren.delete(p);
        treeChildren.set(mapped(p), data);
      }
    }
    if (currentDir === oldPath || currentDir.startsWith(`${oldPath}/`)) {
      currentDir = mapped(currentDir);
    }
  }

  function renderCrumbs() {
    crumbEl.innerHTML = "";
    const rootBtn = document.createElement("button");
    rootBtn.type = "button";
    rootBtn.textContent = "/";
    rootBtn.classList.toggle("active", currentDir === "");
    rootBtn.addEventListener("click", () => selectDir(""));
    crumbEl.appendChild(rootBtn);

    if (!currentDir) return;
    let acc = "";
    const parts = currentDir.split("/").filter(Boolean);
    for (let i = 0; i < parts.length; i += 1) {
      const part = parts[i];
      acc = joinPath(acc, part);
      const sep = document.createElement("span");
      sep.textContent = "/";
      sep.className = "sep";
      crumbEl.appendChild(sep);

      const btn = document.createElement("button");
      btn.type = "button";
      btn.textContent = part;
      if (i === parts.length - 1) btn.classList.add("active");
      const target = acc;
      btn.addEventListener("click", () => selectDir(target));
      crumbEl.appendChild(btn);
    }
  }

  /// 合并同一轮里的多次渲染请求。
  ///
  /// 一次 cd 会同时加载 /、/tmp、/tmp/x… 多个目录，旧代码每加载完一个就整树
  /// 重建一次；几千项的目录会因此重绘五到九次。这里用 20ms 防抖合并成一次。
  let renderTimer = null;
  /// 树的内容是否真的变了；flatRows 和已渲染的树都以它为唯一失效标志。
  let treeDirty = true;
  function scheduleRender() {
    if (renderTimer) clearTimeout(renderTimer);
    renderTimer = setTimeout(() => {
      renderTimer = null;
      renderTree();
    }, 20);
  }

  /// 一次操作通常会并行加载好几个目录；等最后一批都结束再重绘，避免
  /// 每份列表回来都重建一次整棵树（3000 项时每次约 200ms）。
  function scheduleRenderWhenIdle() {
    if (treeLoading.size > 0) return;
    if (!treeDirty) return;
    scheduleRender();
  }

  // ---------------------------------------------------------------------
  // 文件树：把展开后的树拍平成行，只渲染视口附近的一段。
  // 3000 项的目录若整棵插入要 4 万个 DOM 节点（约 400ms）；这里固定只渲染
  // 几十行，滚动时换窗口，总高度用上下两个等高占位行撑起来。
  // ---------------------------------------------------------------------

  /// 展开后的可见行；treeDirty 为真时重建。
  let flatRows = [];
  let windowStart = -1;
  let windowEnd = -1;

  const htmlEscapes = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" };
  function htmlEscape(text) {
    return String(text).replace(/[&<>"']/g, (c) => htmlEscapes[c]);
  }

  function ensureFlat() {
    if (!treeDirty) return;
    treeDirty = false;
    const rows = [];
    const root = treeChildren.get("");
    if (!root) {
      rows.push({ kind: "status", text: treeRootError ? "无法读取目录" : "加载中…", depth: 0 });
    } else if (root.entries.length === 0) {
      rows.push({ kind: "status", text: "（空目录）", depth: 0 });
    } else {
      flatten(rows, "", 0);
    }
    flatRows = rows;
  }

  function flatten(rows, parentPath, depth) {
    const data = treeChildren.get(parentPath);
    if (!data) return;
    for (const entry of data.entries) {
      const isDir = entry.kind === "directory";
      const path = joinPath(parentPath, entry.name);
      const open = isDir && treeExpanded.has(path);
      rows.push({ kind: "entry", path, name: entry.name, size: entry.size, isDir, open, depth });
      if (!open) continue;
      const children = treeChildren.get(path);
      if (!children) {
        rows.push({
          kind: "status",
          text: treeLoading.has(path) ? "加载中…" : "（未加载）",
          depth: depth + 1,
        });
      } else if (children.entries.length === 0) {
        rows.push({ kind: "status", text: "（空目录）", depth: depth + 1 });
      } else {
        flatten(rows, path, depth + 1);
      }
    }
  }

  // 行高由 CSS 变量决定（桌面 24px、窄屏 30px）；每行同高，滚动高度才能精确。
  let rowHeightCache = 0;
  function treeRowHeight() {
    if (!rowHeightCache) {
      const value = parseFloat(getComputedStyle(fileList).getPropertyValue("--tree-row-height"));
      rowHeightCache = value > 0 ? value : 24;
    }
    return rowHeightCache;
  }

  /// 当前选中的目录在 flatRows 里的下标；没有就返回 -1。
  function selectedIndex() {
    for (let i = 0; i < flatRows.length; i += 1) {
      const row = flatRows[i];
      if (row.kind === "entry" && row.isDir && row.path === currentDir) return i;
    }
    return -1;
  }

  function renderTree() {
    // 结构变化会改变视口上方的行数（例如另一个大目录的列表晚到），只保留
    // scrollTop 会让内容整体跳走。选中行还在视口附近时，记住它当时的位置，
    // 重建后按新下标补回去。
    const rowHeight = treeRowHeight();
    const oldIndex = selectedIndex();
    const offset = oldIndex >= 0 ? oldIndex * rowHeight - fileList.scrollTop : 0;
    const visible = oldIndex >= 0 && offset >= -rowHeight && offset <= fileList.clientHeight;
    ensureFlat();
    if (visible) {
      const newIndex = selectedIndex();
      if (newIndex >= 0) fileList.scrollTop = Math.max(0, newIndex * rowHeight - offset);
    }
    renderWindow(true);
  }

  /// 渲染 [start, end) 这一段行；上下用等高占位行补齐总高度。
  function renderWindow(force) {
    ensureFlat();
    const rowHeight = treeRowHeight();
    const total = flatRows.length;
    const viewport = fileList.clientHeight;
    const overscan = 20;
    const start = Math.max(0, Math.min(total, Math.floor(fileList.scrollTop / rowHeight) - overscan));
    const end = Math.max(
      start,
      Math.min(total, Math.ceil((fileList.scrollTop + viewport) / rowHeight) + overscan)
    );
    if (!force && start === windowStart && end === windowEnd) return;
    windowStart = start;
    windowEnd = end;

    const out = [];
    if (start > 0) {
      out.push(`<li class="tree-spacer" style="height:${start * rowHeight}px" aria-hidden="true"></li>`);
    }
    for (let i = start; i < end; i += 1) out.push(rowHtml(flatRows[i]));
    if (end < total) {
      out.push(`<li class="tree-spacer" style="height:${(total - end) * rowHeight}px" aria-hidden="true"></li>`);
    }

    const scrollTop = fileList.scrollTop;
    fileList.innerHTML = out.join("");
    fileList.scrollTop = scrollTop;
  }

  function rowHtml(row) {
    // 每层缩进 17px（原嵌套 ul 的 13px margin + 4px padding），并用 CSS 变量
    // 告诉样式表要画多宽的祖先导引线。
    const indent = 4 + row.depth * 17;
    if (row.kind === "status") {
      return `<li class="empty" style="padding-left:${indent}px">${row.text}</li>`;
    }
    const name = htmlEscape(row.name);
    const isDir = row.isDir;
    const open = row.open;
    const selected = isDir && row.path === currentDir ? " selected" : "";
    const out = [
      `<li class="tree-node"><div class="entry ${isDir ? "directory" : "file"}${selected}" data-path="${htmlEscape(row.path)}" data-name="${name}" style="padding-left:${indent}px;--indent:${indent}px">`,
    ];
    if (isDir) {
      const title = open ? "折叠" : "展开";
      out.push(
        `<button type="button" class="caret${open ? " open" : ""}" data-act="toggle" title="${title}" aria-label="${title}"></button>`
      );
    } else {
      out.push('<span class="caret-spacer"></span>');
    }
    out.push(`<button type="button" class="name" data-act="open" title="${name}">${name}</button>`);
    if (!isDir) out.push(`<span class="size">${humanSize(row.size)}</span>`);
    out.push('<span class="actions">');
    const downloadTitle = isDir ? "下载目录（tar）" : "下载";
    out.push(
      `<button type="button" class="icon" data-act="download" title="${downloadTitle}" aria-label="${downloadTitle}"></button>`
    );
    out.push(
      '<button type="button" class="icon" data-act="rename" title="重命名" aria-label="重命名"></button>'
    );
    out.push(
      '<button type="button" class="icon" data-act="delete" title="删除" aria-label="删除"></button>'
    );
    out.push("</span></div></li>");
    return out.join("");
  }

  function scrollTreeToSelected(alignTop = false) {
    ensureFlat();
    const rowHeight = treeRowHeight();
    const index = selectedIndex();
    if (index < 0) return;
    const top = index * rowHeight;
    if (alignTop) {
      // cwd 同步时尽量把目标放到列表顶部，下面直接露出目录内容。
      fileList.scrollTop = Math.max(0, top);
    } else {
      const viewTop = fileList.scrollTop;
      const viewBottom = viewTop + fileList.clientHeight;
      // 4px 是 #file-list 的 padding-top。
      if (top + 4 < viewTop) fileList.scrollTop = top;
      else if (top + 4 + rowHeight > viewBottom) {
        fileList.scrollTop = top + 4 + rowHeight - fileList.clientHeight;
      }
    }
    renderWindow(true);
  }

  // 滚动只换窗口；同一个动画帧里的多次滚动事件只处理一次。
  let scrollFrame = 0;
  fileList.addEventListener(
    "scroll",
    () => {
      if (scrollFrame) return;
      scrollFrame = requestAnimationFrame(() => {
        scrollFrame = 0;
        renderWindow(false);
      });
    },
    { passive: true }
  );

  const actionIcons = {
    download: ["M8 2.5v8", "M4.5 7 8 10.5 11.5 7", "M3.5 13h9"],
    rename: ["M3 13l1-3 7-7 2 2-7 7z", "M9.5 3.5l2 2"],
    delete: ["M4 4l8 8", "M12 4l-8 8"],
    chevron: ["M6 4l4 4-4 4"],
  };

  function iconNode(name) {
    const ns = "http://www.w3.org/2000/svg";
    const svg = document.createElementNS(ns, "svg");
    svg.setAttribute("class", "ico");
    svg.setAttribute("viewBox", "0 0 16 16");
    svg.setAttribute("aria-hidden", "true");
    for (const d of actionIcons[name] || []) {
      const p = document.createElementNS(ns, "path");
      p.setAttribute("d", d);
      svg.appendChild(p);
    }
    return svg;
  }

  function humanSize(n) {
    if (n < 1024) return `${n} B`;
    if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KiB`;
    return `${(n / 1024 / 1024).toFixed(1)} MiB`;
  }

  async function renameEntry(path, name, isDir) {
    const next = await askText("重命名", name);
    if (!next || next === name) return;
    const parentPath = parentOf(path);
    const newPath = joinPath(parentPath, next);
    try {
      await api("POST", "rename", { from: path, to: newPath });
    } catch (err) {
      if (err.code === "not_empty") {
        notice("重命名失败: 目标目录不是空的", true);
        return;
      }
      if (err.code === "cross_device") {
        notice("重命名失败: 不能跨文件系统移动", true);
        return;
      }
      if (err.code !== "already_exists") {
        notice(`重命名失败: ${err.message}`, true);
        return;
      }
      if (!(await askConfirm("目标已存在", `${newPath} 已存在，要覆盖吗？`, "覆盖", true))) return;
      try {
        await api("POST", "rename", { from: path, to: newPath, overwrite: "1" });
      } catch (err2) {
        notice(`重命名失败: ${err2.message}`, true);
        return;
      }
    }
    if (isDir) rebaseTree(path, newPath);
    for (const tab of tabs) {
      if (tab.kind !== "editor" || !tab.editor) continue;
      const old = tab.editor.path;
      if (old !== path && !(isDir && old.startsWith(`${path}/`))) continue;
      const moved = newPath + old.slice(path.length);
      tab.editor.path = moved;
      tab.editor.name = baseName(moved);
      tab.editor.pathEl.textContent = moved;
      tab.editor.pathEl.title = moved;
      tab.label.textContent = tab.editor.name;
      tab.label.title = moved;
    }
    refreshFiles([parentPath]);
  }

  async function deleteEntry(path, name, isDir) {
    if (!(await askConfirm(`删除 ${name}？`, "此操作不可撤销。", "删除", true))) return;
    // 先处理受影响的编辑器；用户只要保留一个未保存标签，就放弃删除，
    // 避免标签在删除后还指向一个已经不存在的路径。
    for (const tab of [...tabs]) {
      if (tab.kind !== "editor" || !tab.editor) continue;
      const p = tab.editor.path;
      if (p !== path && !(isDir && p.startsWith(`${path}/`))) continue;
      await closeTab(tab);
      if (tabs.includes(tab)) return;
    }
    const parentPath = parentOf(path);
    try {
      await api("DELETE", "delete", { path });
      if (isDir) dropTreePath(path);
      refreshFiles([parentPath]);
    } catch (err) {
      notice(`删除失败: ${err.message}`, true);
    }
  }

  // 文件树的所有点击都委托到 #file-list；拖放同理，只标记当前悬停的目录行。
  fileList.addEventListener("click", (ev) => {
    const actEl = ev.target.closest("[data-act]");
    if (!actEl) return;
    const row = actEl.closest(".entry");
    if (!row) return;
    const path = row.dataset.path;
    const name = row.dataset.name || "";
    const isDir = row.classList.contains("directory");
    switch (actEl.dataset.act) {
      case "toggle":
        ev.stopPropagation();
        toggleDir(path);
        break;
      case "open":
        if (isDir) selectDir(path);
        else openEditor(path);
        break;
      case "download":
        ev.stopPropagation();
        if (isDir) downloadArchive(path, name);
        else downloadFile(path, name);
        break;
      case "rename":
        ev.stopPropagation();
        renameEntry(path, name, isDir);
        break;
      case "delete":
        ev.stopPropagation();
        deleteEntry(path, name, isDir);
        break;
    }
  });

  let dropRow = null;
  function markDropRow(row) {
    if (dropRow === row) return;
    if (dropRow) dropRow.classList.remove("drop-target");
    dropRow = row;
    if (dropRow) dropRow.classList.add("drop-target");
  }
  fileList.addEventListener("dragover", (ev) => {
    const row = ev.target.closest?.(".entry.directory") || null;
    if (!row) return;
    ev.preventDefault();
    ev.stopPropagation();
    markDropRow(row);
  });
  fileList.addEventListener("dragleave", (ev) => {
    const row = ev.target.closest?.(".entry.directory");
    if (row && !row.contains(ev.relatedTarget)) markDropRow(null);
  });
  fileList.addEventListener("drop", (ev) => {
    const row = ev.target.closest?.(".entry.directory") || null;
    markDropRow(null);
    if (!row) return;
    ev.preventDefault();
    ev.stopPropagation();
    if (ev.dataTransfer && ev.dataTransfer.files.length) {
      uploadFiles(ev.dataTransfer.files, row.dataset.path);
    }
  });

  function downloadFile(path, name) {
    const a = document.createElement("a");
    a.href = `/api/fs/download?path=${encodeURIComponent(path)}`;
    a.download = name;
    document.body.appendChild(a);
    a.click();
    a.remove();
  }

  function downloadArchive(path, name) {
    const a = document.createElement("a");
    a.href = `/api/fs/archive?path=${encodeURIComponent(path)}`;
    a.download = `${name}.tar`;
    document.body.appendChild(a);
    a.click();
    a.remove();
  }

  const upload_limit = 64 * 1024 * 1024;

  function showUploadProgress(show, fraction, text) {
    uploadProgress.hidden = !show;
    if (!show) return;
    uprogFill.style.width = `${Math.max(0, Math.min(1, fraction)) * 100}%`;
    uprogText.textContent = text;
  }

  // 整文件一次 PUT：服务端写临时文件后原子替换，断线不会留下半截目标文件。
  function uploadOne(file, targetDir, batch) {
    return new Promise((resolve, reject) => {
      const epoch = authEpoch;
      const xhr = new XMLHttpRequest();
      const url = `/api/fs/upload?path=${encodeURIComponent(joinPath(targetDir, file.name))}`;
      batch.xhr = xhr;
      xhr.open("PUT", url);
      xhr.responseType = "text";
      const total = file.size || 1; // 0 字节文件也不能让进度变成 NaN%
      xhr.upload.onprogress = (ev) => {
        if (!ev.lengthComputable) return;
        const pct = Math.round((ev.loaded / total) * 100);
        showUploadProgress(true, ev.loaded / total, `${file.name} ${pct}%`);
      };
      xhr.onload = () => {
        let data = {};
        try {
          data = JSON.parse(xhr.responseText || "{}");
        } catch (_) {}
        if (xhr.status >= 200 && xhr.status < 300) return resolve(data);
        if (xhr.status === 401) {
          if (epoch === authEpoch) showLogin("登录已失效，请重新登录");
          return reject(new Error("unauthorized"));
        }
        reject(new Error(data.error || `HTTP ${xhr.status}`));
      };
      xhr.onerror = () => reject(new Error("network"));
      xhr.onabort = () => reject(new Error("cancelled"));
      xhr.send(file);
    });
  }

  async function uploadFiles(fileList, targetDir = currentDir) {
    const files = Array.from(fileList || []);
    if (files.length === 0) return;
    if (uploader) {
      notice("已有一个上传任务在进行", true);
      return;
    }

    const batch = { xhr: null, cancelled: false };
    uploader = batch;
    let done = 0;
    let failed = 0;
    showUploadProgress(true, 0, "准备上传…");

    try {
      for (const file of files) {
        if (batch.cancelled) break;
        if (file.size > upload_limit) {
          failed++;
          notice(`${file.name} 超过 64 MiB 上限`, true);
          continue;
        }
        try {
          await uploadOne(file, targetDir, batch);
          done++;
        } catch (err) {
          failed++;
          if (err.message !== "cancelled") notice(`上传 ${file.name} 失败: ${err.message}`, true);
          if (batch.cancelled) break;
        }
      }
    } finally {
      uploader = null;
      showUploadProgress(false, 0, "");
      if (batch.cancelled) notice("上传已取消", true);
      else if (failed === 0) notice(`已上传 ${done} 个文件`);
      else if (done > 0) notice(`上传完成 ${done} 个，失败 ${failed} 个`, true);
      if (targetDir) {
        treeExpanded.add(targetDir);
        treeDirty = true;
      }
      refreshFiles([targetDir]);
    }
  }

  // 应用内文本输入弹窗；返回 null 表示取消。
  function askText(title, initial = "") {
    return new Promise((resolve) => {
      const previous = document.activeElement;
      promptTitle.textContent = title;
      promptMessage.hidden = true;
      promptInput.hidden = false;
      promptOk.textContent = "确定";
      promptOk.classList.remove("danger");
      promptInput.value = initial;
      promptError.textContent = "";
      promptOverlay.hidden = false;
      promptInput.focus();
      promptInput.select();

      const finish = (value) => {
        promptOverlay.hidden = true;
        promptForm.removeEventListener("submit", onSubmit);
        promptForm.removeEventListener("keydown", onKey);
        promptCancel.removeEventListener("click", onCancel);
        if (previous instanceof HTMLElement && previous.isConnected) previous.focus();
        resolve(value);
      };
      const onSubmit = (event) => {
        event.preventDefault();
        if (!promptInput.value) {
          promptError.textContent = "名字不能为空";
          promptInput.focus();
          return;
        }
        finish(promptInput.value);
      };
      const onCancel = () => finish(null);
      const onKey = (event) => {
        if (event.key === "Escape") {
          event.preventDefault();
          event.stopPropagation();
          finish(null);
        }
      };

      promptForm.addEventListener("submit", onSubmit);
      promptForm.addEventListener("keydown", onKey);
      promptCancel.addEventListener("click", onCancel);
    });
  }

  // 应用内确认弹窗，替代原生 confirm()：风格一致，也不会被移动端/iframe 拦截。
  // 返回 true 表示确认。
  function askConfirm(title, message, okLabel = "确定", danger = false) {
    return new Promise((resolve) => {
      const previous = document.activeElement;
      promptTitle.textContent = title;
      promptMessage.textContent = message;
      promptMessage.hidden = !message;
      promptInput.hidden = true;
      promptError.textContent = "";
      promptOk.textContent = okLabel;
      promptOk.classList.toggle("danger", danger);
      promptOverlay.hidden = false;
      promptOk.focus();

      const finish = (value) => {
        promptOverlay.hidden = true;
        promptInput.hidden = false;
        promptMessage.hidden = true;
        promptOk.textContent = "确定";
        promptOk.classList.remove("danger");
        promptForm.removeEventListener("submit", onSubmit);
        promptForm.removeEventListener("keydown", onKey);
        promptCancel.removeEventListener("click", onCancel);
        if (previous instanceof HTMLElement && previous.isConnected) previous.focus();
        resolve(value);
      };
      const onSubmit = (event) => {
        event.preventDefault();
        finish(true);
      };
      const onCancel = () => finish(false);
      const onKey = (event) => {
        if (event.key === "Escape") {
          event.preventDefault();
          event.stopPropagation();
          finish(false);
        }
      };

      promptForm.addEventListener("submit", onSubmit);
      promptForm.addEventListener("keydown", onKey);
      promptCancel.addEventListener("click", onCancel);
    });
  }

  async function newFile() {
    const name = await askText("新建文件");
    if (!name) return;
    const path = joinPath(currentDir, name);
    try {
      await api("PUT", "write", { path, exclusive: "1" }, "");
    } catch (err) {
      if (err.code !== "already_exists") {
        notice(`新建失败: ${err.message}`, true);
        return;
      }
      if (!(await askConfirm("文件已存在", `${path} 已存在，要覆盖吗？`, "覆盖", true))) return;
      try {
        await api("PUT", "write", { path }, "");
      } catch (err2) {
        notice(`新建失败: ${err2.message}`, true);
        return;
      }
    }
    await refreshFiles();
    openEditor(path);
  }

  async function newDir() {
    const name = await askText("新建目录");
    if (!name) return;
    const path = joinPath(currentDir, name);
    try {
      await api("POST", "mkdir", { path });
      // 允许在名字里输入多级路径；applyDir 会展开并加载所有祖先目录，
      // 否则新目录在树里不可达。
      applyDir(path, true, true);
    } catch (err) {
      notice(`新建目录失败: ${err.message}`, true);
    }
  }

