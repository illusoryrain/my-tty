(() => {
  "use strict";

  const MAX_PANES = 4;
  const MAX_TABS = 8;

  const workspace = document.getElementById("workspace");
  const tabStripEl = document.getElementById("tab-strip");
  const tabListEl = document.getElementById("tab-list");
  const tabMoreBtn = document.getElementById("tab-more");
  const tabMenuEl = document.getElementById("tab-menu");
  const tabAddBtn = document.getElementById("tab-add");
  const addPaneBtn = document.getElementById("add-pane");
  const filesBtn = document.getElementById("toggle-files");
  const filesEl = document.getElementById("files");
  const filesResizeEl = document.getElementById("files-resize");
  const cwdSyncBtn = document.getElementById("files-cwd-sync");
  const crumbEl = document.getElementById("crumb");
  const uploadBtn = document.getElementById("files-upload");
  const uploadInput = document.getElementById("upload-input");
  const fileList = document.getElementById("file-list");
  const noticeEl = document.getElementById("notice");
  const statusEl = document.getElementById("status");
  const hintEl = document.getElementById("hint");

  const editorOverlay = document.getElementById("editor-overlay");
  const editorEl = document.getElementById("editor");
  const editorPathEl = document.getElementById("editor-path");
  const editorStateEl = document.getElementById("editor-state");
  const editorSaveBtn = document.getElementById("editor-save");
  const editorCloseBtn = document.getElementById("editor-close");
  const logoutBtn = document.getElementById("logout");
  const loginOverlay = document.getElementById("login-overlay");
  const loginForm = document.getElementById("login-form");
  const loginPassword = document.getElementById("login-password");
  const loginError = document.getElementById("login-error");
  const loginSubmit = document.getElementById("login-submit");
  const promptOverlay = document.getElementById("prompt-overlay");
  const promptForm = document.getElementById("prompt-form");
  const promptTitle = document.getElementById("prompt-title");
  const promptInput = document.getElementById("prompt-input");
  const promptError = document.getElementById("prompt-error");
  const promptCancel = document.getElementById("prompt-cancel");
  const promptOk = document.getElementById("prompt-ok");
  const promptMessage = document.getElementById("prompt-message");
  const findBar = document.getElementById("find-bar");
  const findInput = document.getElementById("find-input");
  const findCount = document.getElementById("find-count");
  const interruptBtn = document.getElementById("send-interrupt");
  const fontDecBtn = document.getElementById("font-dec");
  const fontIncBtn = document.getElementById("font-inc");
  const keysBar = document.getElementById("keys");
  const uploadProgress = document.getElementById("upload-progress");
  const uprogFill = document.getElementById("uprog-fill");
  const uprogText = document.getElementById("uprog-text");
  const uprogCancel = document.getElementById("uprog-cancel");
  const editorGutter = document.getElementById("editor-gutter");

  const scheme = location.protocol === "https:" ? "wss:" : "ws:";
  const wsBase = `${scheme}//${location.host}/ws`;

  // 触摸设备把可打印字符统一交给浏览器的 input 事件：xterm 的 keydown/keypress
  // 和 input 各发一次，是手机端 ls → llss 的根因。桌面（细指针）完全不受影响。
  const coarsePointer =
    typeof window.matchMedia === "function" &&
    window.matchMedia("(pointer: coarse)").matches;

  // localStorage 在隐私模式、禁用站点数据或配额满时会抛异常；偏好设置
  // 只是锦上添花，读写失败一律当作“没有存过”，绝不能让页面启动失败。
  const store = {
    get(key) {
      try {
        return localStorage.getItem(key);
      } catch (_) {
        return null;
      }
    },
    set(key, value) {
      try {
        localStorage.setItem(key, value);
      } catch (_) {}
    },
  };

  // 每个标签页有自己的 pane 数组；`panes` 始终指向当前标签页的数组。
  const tabs = [];
  let activeTab = null;
  let tabSeq = 0;
  let panes = [];
  let activePane = null;
  let currentDir = "";
  const treeExpanded = new Set([""]);
  const treeChildren = new Map();
  const treeLoading = new Set();
  let treeRootError = false;
  let cwdSyncEnabled = store.get("myttty.cwdSync") !== "0";
  let editing = null; // { path, dirty }
  let started = false;
  let fontsize = clampFont(parseInt(store.get("myttty.fontsize") || "14", 10) || 14);
  let splitX = parseFloat(store.get("myttty.splitX") || "0.5") || 0.5;
  let splitY = parseFloat(store.get("myttty.splitY") || "0.5") || 0.5;
  let filesWidth = parseInt(store.get("myttty.filesWidth") || "300", 10);
  if (!Number.isFinite(filesWidth)) filesWidth = 300;
  let uploader = null; // { xhr, url, cancelled }

  function clampFont(n) {
    return Math.min(24, Math.max(10, n));
  }

  // ---------------------------------------------------------------- tabs

  function updateTabHint() {
    tabAddBtn.disabled = tabs.length >= MAX_TABS;
  }

  let tabMenuOpen = false;

  function positionTabMenu() {
    if (tabMenuEl.hidden) return;
    const r = tabMoreBtn.getBoundingClientRect();
    tabMenuEl.style.left = `${Math.max(4, Math.round(r.left))}px`;
    tabMenuEl.style.top = `${Math.round(r.bottom + 4)}px`;
  }

  function closeTabMenu() {
    tabMenuEl.hidden = true;
    tabMenuOpen = false;
  }

  function openTabMenu() {
    if (tabMoreBtn.hidden) return;
    tabMenuEl.hidden = false;
    tabMenuOpen = true;
    positionTabMenu();
  }

  function renderTabMenu(collapsedTabs) {
    tabMenuEl.replaceChildren();
    for (const tab of collapsedTabs) {
      const row = document.createElement("div");
      row.className = "menu-tab";

      const label = document.createElement("button");
      label.type = "button";
      label.className = "menu-label";
      label.textContent = tab.label.textContent;
      label.classList.toggle("active", tab === activeTab);
      label.addEventListener("click", () => {
        activateTab(tab);
        closeTabMenu();
      });

      const close = document.createElement("button");
      close.type = "button";
      close.className = "menu-close";
      close.title = "关闭标签页";
      close.appendChild(iconNode("delete"));
      close.addEventListener("click", (ev) => {
        ev.stopPropagation();
        closeTab(tab);
        closeTabMenu();
      });

      row.appendChild(label);
      row.appendChild(close);
      tabMenuEl.appendChild(row);
    }
  }

  // 标签栏放不下时，把最旧的标签折叠到左侧的“⋯”菜单里；当前标签始终可见。
  function layoutTabs() {
    const n = tabs.length;
    if (n === 0) {
      tabMoreBtn.hidden = true;
      closeTabMenu();
      return;
    }

    // 先全部展开量一次真实宽度（同步完成，不会绘制到屏幕）。
    for (const tab of tabs) tab.btn.classList.remove("collapsed");
    const widths = tabs.map((tab) => tab.btn.getBoundingClientRect().width);
    const gap = parseFloat(getComputedStyle(tabStripEl).columnGap) || 4;
    const plusW = tabAddBtn.getBoundingClientRect().width;

    tabMoreBtn.hidden = false;
    const moreW = tabMoreBtn.getBoundingClientRect().width;
    const available = tabStripEl.clientWidth - 2;
    const activeIdx = tabs.indexOf(activeTab);

    let visible = null;
    let collapsed = 0;
    for (let suffix = n; suffix >= 0; suffix -= 1) {
      const set = new Set();
      if (activeIdx >= 0) set.add(activeIdx);
      for (let i = Math.max(0, n - suffix); i < n; i += 1) set.add(i);

      collapsed = n - set.size;
      let width = plusW + (collapsed > 0 ? moreW : 0);
      const items = 1 + (collapsed > 0 ? 1 : 0) + set.size;
      for (const i of set) width += widths[i];
      width += gap * Math.max(0, items - 1);

      if (width <= available) {
        visible = set;
        break;
      }
    }

    if (!visible) {
      visible = new Set();
      collapsed = n;
    }

    const collapsedTabs = [];
    for (let i = 0; i < n; i += 1) {
      const show = visible.has(i);
      tabs[i].btn.classList.toggle("collapsed", !show);
      if (!show) collapsedTabs.push(tabs[i]);
    }

    const hasCollapsed = collapsedTabs.length > 0;
    tabMoreBtn.hidden = !hasCollapsed;
    tabMoreBtn.classList.toggle(
      "active",
      activeTab !== null && collapsedTabs.includes(activeTab)
    );
    tabMoreBtn.title = hasCollapsed ? `还有 ${collapsedTabs.length} 个标签页` : "";

    if (!hasCollapsed) {
      closeTabMenu();
      tabMenuEl.replaceChildren();
    } else {
      renderTabMenu(collapsedTabs);
      if (tabMenuOpen) positionTabMenu();
    }
  }

  function addTab() {
    if (tabs.length >= MAX_TABS) return null;

    const el = document.createElement("div");
    el.className = "tab-workspace";
    el.hidden = true;
    workspace.appendChild(el);

    const btn = document.createElement("div");
    btn.className = "tab";
    btn.setAttribute("role", "tab");
    btn.setAttribute("aria-selected", "false");

    const label = document.createElement("button");
    label.type = "button";
    label.className = "tab-label";
    label.textContent = `终端 ${++tabSeq}`;

    const close = document.createElement("button");
    close.type = "button";
    close.className = "tab-close";
    close.title = "关闭标签页";
    close.appendChild(iconNode("delete"));

    btn.appendChild(label);
    btn.appendChild(close);
    tabListEl.appendChild(btn);

    const tab = { el, btn, label, panes: [], activePane: null, splitX: 0.5, splitY: 0.5 };
    tabs.push(tab);

    btn.addEventListener("click", () => activateTab(tab));
    close.addEventListener("click", (ev) => {
      ev.stopPropagation();
      closeTab(tab);
    });

    updateTabHint();
    layoutTabs();
    return tab;
  }

  function newTab() {
    const tab = addTab();
    if (!tab) return;
    activateTab(tab);
    createPane("", tab);
  }

  function activateTab(tab) {
    if (!tab || tab === activeTab) return;

    if (activeTab) {
      activeTab.splitX = splitX;
      activeTab.splitY = splitY;
      activeTab.activePane = activePane;
      activeTab.el.hidden = true;
      activeTab.btn.classList.remove("active");
      activeTab.btn.setAttribute("aria-selected", "false");
      if (activePane) activePane.term.blur();
    }

    activeTab = tab;
    panes = tab.panes;
    splitX = tab.splitX;
    splitY = tab.splitY;
    activePane =
      tab.activePane && tab.panes.includes(tab.activePane)
        ? tab.activePane
        : tab.panes[tab.panes.length - 1] || null;

    tab.el.hidden = false;
    tab.btn.classList.add("active");
    tab.btn.setAttribute("aria-selected", "true");
    for (const p of panes) p.el.classList.toggle("active", p === activePane);

    layout(tab);
    layoutTabs();
    updateSummary();
    saveSessions();
    if (cwdSyncEnabled && activePane && activePane.cwd) syncFilesToCwd(activePane.cwd);
    requestAnimationFrame(() => {
      for (const p of tab.panes) fitPane(p);
      if (activePane && !coarsePointer) activePane.term.focus();
    });
  }

  function closeTab(tab) {
    const idx = tabs.indexOf(tab);
    if (idx === -1) return;

    for (const pane of [...tab.panes]) removePane(pane, false);
    tab.el.remove();
    tab.btn.remove();
    tabs.splice(idx, 1);
    if (tabs.length === 0) tabSeq = 0;

    if (activeTab === tab) {
      activeTab = null;
      panes = [];
      activePane = null;
      const next = tabs[Math.min(idx, tabs.length - 1)];
      if (next) activateTab(next);
      else newTab();
    }

    updateTabHint();
    layoutTabs();
    saveSessions();
  }

  // ---------------------------------------------------------------- terminals

  function createPane(initialSession = "", tab = activeTab) {
    if (!tab || tab.panes.length >= MAX_PANES) return;

    const el = document.createElement("section");
    el.className = "pane";
    el.innerHTML = `
      <div class="pane-bar">
        <span class="pane-dot"></span>
        <span class="pane-status">连接中…</span>
        <button class="pane-close" type="button" title="关闭此分屏" aria-label="关闭此分屏"><svg class="ico" viewBox="0 0 16 16" aria-hidden="true"><path d="M4 4l8 8"/><path d="M12 4l-8 8"/></svg></button>
      </div>
      <div class="pane-term"></div>`;
    tab.el.appendChild(el);

    const termEl = el.querySelector(".pane-term");
    const bar = el.querySelector(".pane-bar");
    const status = el.querySelector(".pane-status");
    const dot = el.querySelector(".pane-dot");

    const term = new Terminal({
      cursorBlink: true,
      cursorStyle: "block",
      fontFamily:
        '"JetBrains Mono", ui-monospace, SFMono-Regular, Menlo, Consolas, "Liberation Mono", monospace',
      fontSize: fontsize,
      scrollback: 5000,
      allowProposedApi: false,
      macOptionIsMeta: true,
      theme: terminalTheme,
    });
    const fit = new FitAddon.FitAddon();
    term.loadAddon(fit);
    const search = new SearchAddon.SearchAddon();
    term.loadAddon(search);
    term.loadAddon(new WebLinksAddon.WebLinksAddon());
    term.open(termEl);

    // xterm 6.0 用 _keyDownSeen 去重：composed 的 insertText 只要该标记为真
    // 就会被忽略。Safari/输入法会出现 keydown 是 229/Process、字符只能靠随后的
    // input 送达；移动端浏览器又可能在 keydown/keypress 已经发出字符后，再派发
    // 一次 composed insertText——无条件清标记会让同一个字符发两遍（ls → llss）。
    //
    // 不猜“哪个键发出了字符”，而是记录 xterm 在键盘事件里实际发出的数据：
    // 只有 input 的数据与刚才键盘路径发出的不一致时，才清标记让 input 补发。
    // xterm 的 keydown/keypress/input 以及 229 keydown 额外安排的 textarea
    // 差分发送都会经过 term.onData，可据此判断这个字符是否已经发过。
    const helperTextarea = term.textarea;
    if (helperTextarea && term._core) {
      let keyEventActive = false;
      let sentThisKeyEvent = false;
      let lastKeySent = null;
      let lastKeySentAt = 0;
      let swallowInput = false;
      let lastBeforeInputData = null;
      let lastBeforeInputAt = 0;
      let imeKeyDownAt = 0;
      let pendingIME = null;
      let lastSentData = null;
      let lastSentAt = 0;

      term.onData((data) => {
        lastSentData = data;
        lastSentAt = performance.now();
        if (!keyEventActive) return;
        sentThisKeyEvent = true;
        lastKeySent = data;
        lastKeySentAt = lastSentAt;
      });

      const beginKey = (event) => {
        if (event.type === "keydown") {
          imeKeyDownAt = event.keyCode === 229 ? performance.now() : 0;
        }
        keyEventActive = true;
        sentThisKeyEvent = false;
      };
      const endKey = (event) => {
        keyEventActive = false;
        // keydown 已经发过字符时压掉紧随其后的 keypress，避免第二条键盘路径重复。
        if (event.type === "keydown" && sentThisKeyEvent) {
          term._core._keyDownHandled = true;
        }
      };

      const letInputThrough = (event) => {
        if (event.target !== helperTextarea) return;
        if (!event.data) return;
        if (event.inputType !== "insertText" || event.isComposing) return;

        const now = performance.now();
        const data = event.data;

        if (event.type === "beforeinput") {
          lastBeforeInputData = data;
          lastBeforeInputAt = now;
        } else if (
          pendingIME &&
          pendingIME.data === data &&
          now - pendingIME.at < 100
        ) {
          // beforeinput 已决定走 textarea 差分发送，这次 input 必须挡住：有些
          // 设备（keyup 先于 input、input 非 composed）会让 xterm 的 _inputEvent
          // 抢在差分之前再发一次，l 就变成 ll。兜底已在 beforeinput 里排好。
          pendingIME = null;
          term._core._keyDownSeen = true;
          event.stopPropagation();
          return;
        } else if (lastBeforeInputData === data && now - lastBeforeInputAt < 100) {
          // 同一个数据已经由 beforeinput 处理过，input 只做兜底，不能重复决定。
          lastBeforeInputData = null;
          return;
        }

        const imeAt = imeKeyDownAt;
        if (imeAt && now - imeAt < 500) {
          // 软键盘的 229 keydown 会让 xterm 在 keydown 里为 textarea 的后续变化
          // 安排一次差分发送。吞掉这次 input，让差分成为唯一发送者；差分定时器
          // 比这里先注册，它已经发过就不再补发。若 input 晚于差分触发、差分没
          // 东西可发，由下面的兜底补发，保证字符不丢。
          imeKeyDownAt = 0;
          term._core._keyDownSeen = true;
          event.stopPropagation();
          if (event.type === "beforeinput") pendingIME = { data, at: now };
          setTimeout(() => {
            if (lastSentData === data && lastSentAt >= imeAt) return;
            sendInput(pane, data);
          }, 0);
          return;
        }

        keyEventActive = false;
        const alreadySent =
          lastKeySent !== null &&
          event.data === lastKeySent &&
          now - lastKeySentAt < 500;
        lastKeySent = null;

        if (alreadySent) {
          // 键盘路径已经发过：阻止 input 再发一次。极少数移动浏览器即使取消
          // beforeinput 仍会派发 input，下面的捕获监听会把它挡住。
          if (event.cancelable) event.preventDefault();
          swallowInput = true;
          setTimeout(() => {
            swallowInput = false;
          }, 0);
          return;
        }
        term._core._keyDownSeen = false;
      };

      const swallowIfNeeded = (event) => {
        if (!swallowInput) return;
        swallowInput = false;
        event.stopPropagation();
      };

      termEl.addEventListener("keydown", beginKey, true);
      termEl.addEventListener("keypress", beginKey, true);
      // endKey 必须挂在 textarea 本身且用捕获阶段：xterm 处理 Enter 等键时会
      // stopPropagation()，挂在上层冒泡阶段收不到；同阶段的捕获监听仍会执行。
      helperTextarea.addEventListener("keydown", endKey, true);
      helperTextarea.addEventListener("keypress", endKey, true);
      // beforeinput 是最早的时机；input 捕获阶段始终保留兜底（在 xterm 自己的
      // textarea 监听器之前执行），并用 lastBeforeInputData 避免同一事件处理两次。
      if ("onbeforeinput" in helperTextarea) {
        helperTextarea.addEventListener("beforeinput", letInputThrough);
      }
      termEl.addEventListener("input", letInputThrough, true);
      termEl.addEventListener("input", swallowIfNeeded, true);

      // 排查用：URL 加 ?debug-input=1 时把原始事件打到控制台，默认不输出。
      if (new URLSearchParams(location.search).has("debug-input")) {
        const types = [
          "keydown",
          "keypress",
          "beforeinput",
          "input",
          "compositionstart",
          "compositionend",
        ];
        for (const type of types) {
          helperTextarea.addEventListener(
            type,
            (event) => {
              console.log("[my-tty input]", type, {
                key: event.key,
                code: event.code,
                keyCode: event.keyCode,
                charCode: event.charCode,
                data: event.data,
                inputType: event.inputType,
                composed: event.composed,
                isComposing: event.isComposing,
              });
            },
            true
          );
        }
      }
    }

    const pane = {
      el,
      tab,
      termEl,
      term,
      fit,
      search,
      bar,
      status,
      dot,
      sessionId: initialSession,
      offset: 0,
      cwd: null,
      ws: null,
      alive: false,
      reconnect: null,
      // 心跳/自动重连状态。
      lastRx: 0,
      hbTimer: null,
      retryTimer: null,
      retryAttempt: 0,
      retryable: true,
      opens: 0,
      // connectPane 在等 ticket 时 pane.ws 还是空的；没有这个标记，online /
      // visibilitychange 会在同一分屏上再取一张票，建出第二条 WebSocket。
      connecting: false,
      // 终端输出写队列：xterm 还在解析上一批时到达的帧先攒起来，下一批合成一次 write。
      outQueue: [],
      outQueued: 0,
      outWriting: false,
    };
    tab.panes.push(pane);
    tab.activePane = pane;
    if (tab === activeTab) panes = tab.panes;

    term.attachCustomKeyEventHandler((event) => handleTermKey(event, pane));
    term.onData((data) => sendInput(pane, data));
    term.onResize(() => sendResize(pane));

    el.addEventListener("mousedown", () => focusPane(pane));
    termEl.addEventListener("focusin", () => focusPane(pane));
    el.querySelector(".pane-close").addEventListener("click", (ev) => {
      ev.stopPropagation();
      removePane(pane);
    });
    status.addEventListener("click", () => {
      if (!pane.alive && pane.reconnect) pane.reconnect();
    });

    connectPane(pane);
    layout(tab);
    if (tab === activeTab) focusPane(pane);
    saveSessions();
  }

  function focusPane(pane) {
    if (!pane) return;
    if (pane.tab && pane.tab !== activeTab) activateTab(pane.tab);
    activePane = pane;
    if (pane.tab) pane.tab.activePane = pane;
    for (const p of panes) p.el.classList.toggle("active", p === pane);
    if (cwdSyncEnabled && pane.cwd) syncFilesToCwd(pane.cwd);
    pane.term.focus();
  }

  function removePane(pane, respawn = true) {
    const tab = pane.tab;
    const list = tab ? tab.panes : panes;
    const idx = list.indexOf(pane);
    if (idx === -1) return;
    pane.retryable = false;
    stopHeartbeat(pane);
    if (pane.retryTimer) {
      clearTimeout(pane.retryTimer);
      pane.retryTimer = null;
    }
    if (pane.ws) {
      // 显式关闭分屏 = 结束这个会话；页面刷新/断网不会发这条消息。
      try {
        if (pane.ws.readyState === WebSocket.OPEN) {
          pane.ws.send(JSON.stringify({ t: "close" }));
        }
      } catch (_) {}
      try {
        pane.ws.close();
      } catch (_) {}
      pane.ws = null;
    }
    pane.term.dispose();
    pane.el.remove();
    list.splice(idx, 1);

    if (tab && tab.activePane === pane) tab.activePane = null;
    if (tab === activeTab && activePane === pane) {
      activePane = list[Math.min(idx, list.length - 1)] || null;
      if (tab) tab.activePane = activePane;
      if (activePane) focusPane(activePane);
      else for (const p of panes) p.el.classList.remove("active");
    }

    pane.sessionId = "";
    saveSessions();
    if (list.length === 0) {
      if (respawn && started && tab) createPane("", tab);
    } else if (tab === activeTab) {
      layout(tab);
    }
    if (tab === activeTab) updateSummary();
  }

  function saveSessions() {
    try {
      sessionStorage.setItem(
        "myttty.tabs",
        JSON.stringify({
          active: Math.max(0, tabs.indexOf(activeTab)),
          tabs: tabs.map((t) => ({
            x: t.splitX,
            y: t.splitY,
            s: t.panes.map((p) => p.sessionId || ""),
          })),
        })
      );
    } catch (_) {}
  }

  async function connectPane(pane) {
    if (!pane.el.isConnected) return;
    if (pane.retryTimer) {
      clearTimeout(pane.retryTimer);
      pane.retryTimer = null;
    }
    const current = pane.ws;
    if (current && (current.readyState === WebSocket.OPEN || current.readyState === WebSocket.CONNECTING)) {
      return;
    }
    // 票据请求是异步的；这段窗口里 pane.ws 仍为空，必须靠标记挡住重入，
    // 否则 online/可见性变化会为同一个分屏建出两条 WebSocket（甚至两个 PTY）。
    if (pane.connecting) return;
    pane.connecting = true;
    setPaneStatus(pane, "连接中…", "pending");
    pane.reconnect = () => connectPane(pane);

    let ticket = "";
    try {
      const res = await fetch("/api/auth/ticket", { method: "POST", cache: "no-store" });
      if (!res.ok) {
        pane.connecting = false;
        if (res.status === 401) {
          // 登录真的失效了：停止自动重连，登录成功后 startApp 会统一重试。
          pane.retryable = false;
          showLogin("登录已失效，请重新登录");
          setPaneStatus(pane, "认证失败（点击重试）", "error");
        } else {
          setPaneStatus(pane, "无法获取连接票据", "error");
          scheduleReconnect(pane);
        }
        return;
      }
      ticket = (await res.json()).ticket || "";
    } catch (err) {
      // 网络问题不等于登录失效：不弹登录框，安静退避重试。
      pane.connecting = false;
      setPaneStatus(pane, "无法获取连接票据", "error");
      scheduleReconnect(pane);
      return;
    }

    // pane 可能在等待 ticket 时被关闭，或所在标签页被删掉。
    if (!pane.el.isConnected) {
      pane.connecting = false;
      return;
    }

    let url = `${wsBase}?ticket=${encodeURIComponent(ticket)}&offset=${pane.offset}`;
    if (pane.sessionId) url += `&session=${encodeURIComponent(pane.sessionId)}`;

    let ws;
    try {
      ws = new WebSocket(url);
    } catch (err) {
      pane.connecting = false;
      scheduleReconnect(pane);
      return;
    }
    ws.binaryType = "arraybuffer";
    pane.ws = ws;
    pane.connecting = false;
    pane.reconnect = () => connectPane(pane);

    ws.onopen = () => {
      pane.alive = true;
      pane.opens += 1;
      pane.retryAttempt = 0;
      pane.retryable = true;
      startHeartbeat(pane);
      setPaneStatus(pane, "已连接", "ok");
      fitPane(pane);
      // 点击状态栏重连后把焦点还给终端，否则接下来的按键会落到 body 上；
      // 后台标签页连上时不能把用户切走。
      if (pane.tab === activeTab) focusPane(pane);
      updateSummary();
    };
    ws.onmessage = (event) => {
      pane.lastRx = Date.now();
      if (typeof event.data !== "string") {
        const bytes = new Uint8Array(event.data);
        pane.offset += bytes.byteLength;
        queueOutput(pane, bytes);
        return;
      }
      let msg;
      try {
        msg = JSON.parse(event.data);
      } catch (_) {
        return;
      }
      if (msg.t === "ready") {
        // 服务端会在回放前给出权威起点；换会话（如服务端重启）时重置偏移。
        if (typeof msg.offset === "number") pane.offset = msg.offset;
        if (msg.session && msg.session !== pane.sessionId) {
          const replaced = !!pane.sessionId;
          pane.sessionId = msg.session;
          saveSessions();
          if (replaced) setPaneStatus(pane, "已连接 · 原会话已失效", "pending");
        }
        sendResize(pane);
      } else if (msg.t === "cwd") {
        if (typeof msg.path === "string") {
          pane.cwd = msg.path;
          if (cwdSyncEnabled && pane === activePane) syncFilesToCwd(msg.path);
        }
      } else if (msg.t === "gap") {
        notice(`缓冲区已满，丢弃了 ${msg.lost} 字节历史输出`, true);
      } else if (msg.t === "exit") {
        pane.sessionId = "";
        pane.offset = 0;
        pane.retryable = false;
        saveSessions();
        setPaneStatus(pane, "Shell 已退出（点击重连）", "error");
      } else if (msg.t === "error") {
        // 会话数满了再自动重连只会一直撞墙，交给用户点。
        if (msg.reason === "too_many_sessions") pane.retryable = false;
        setPaneStatus(
          msg.reason === "too_many_sessions"
            ? "会话数已满（点击重试）"
            : msg.reason === "session_busy"
              ? "会话正忙（点击重试）"
              : "会话异常（点击重连）",
          "error"
        );
      }
    };
    ws.onclose = (event) => {
      if (pane.ws !== ws) return; // 已经有新连接接管这个 pane，别动它的心跳
      stopHeartbeat(pane);
      pane.ws = null;
      pane.alive = false;
      updateSummary();
      // 4001 = 服务端说“另一个窗口接管了这个会话”。这时不能自动重连，
      // 否则两个页面会互相踢来踢去。
      if (event && event.code === 4001) {
        pane.retryable = false;
        setPaneStatus(pane, "已被其他窗口接管（点击重连）", "error");
        return;
      }
      if (!pane.el.isConnected || !started) return;
      if (pane.retryable) {
        scheduleReconnect(pane);
      } else if (pane.status.textContent === "连接中…" || pane.status.textContent === "已连接") {
        setPaneStatus(pane, "已断开（点击重连）", "error");
      }
    };
    ws.onerror = () => {
      if (!pane.alive) setPaneStatus(pane, "连接被拒绝", "error");
    };
  }

  // 刷屏（cat 大文件、编译日志）时服务端每次 PTY 读取就是一帧；逐帧 term.write
  // 会让 xterm 排起成千上万个小任务。这里同一时间只让一批在 xterm 里解析，
  // 期间到达的帧在完成回调里合并成一次 write。顺序不变，也不丢字节。
  function queueOutput(pane, bytes) {
    pane.outQueue.push(bytes);
    pane.outQueued += bytes.byteLength;
    if (!pane.outWriting) flushOutput(pane);
  }

  // 单次 write 的上限：刷屏时待写帧可能很多，按块合并，避免一次分配几 MB
  // 的连续缓冲；xterm 内部仍会按自己的节奏解析。
  const MAX_WRITE_BATCH = 256 * 1024;

  function flushOutput(pane) {
    if (pane.outQueue.length === 0 || !pane.el.isConnected) {
      pane.outWriting = false;
      pane.outQueue = [];
      pane.outQueued = 0;
      return;
    }
    let take = 0;
    let bytes = 0;
    while (take < pane.outQueue.length) {
      const size = pane.outQueue[take].byteLength;
      if (take > 0 && bytes + size > MAX_WRITE_BATCH) break;
      bytes += size;
      take += 1;
    }
    let chunk;
    if (take === 1) {
      chunk = pane.outQueue[0];
    } else {
      chunk = new Uint8Array(bytes);
      let at = 0;
      for (let i = 0; i < take; i += 1) {
        chunk.set(pane.outQueue[i], at);
        at += pane.outQueue[i].byteLength;
      }
    }
    pane.outQueue.splice(0, take);
    pane.outQueued -= bytes;
    pane.outWriting = true;
    pane.term.write(chunk, () => flushOutput(pane));
  }

  // 半开连接（手机锁屏、掉 Wi-Fi、笔记本睡眠）不会触发 onclose，只能靠心跳发现。
  const HEARTBEAT_MS = 20000;
  const STALE_MS = 55000;

  function sendPing(pane) {
    const ws = pane.ws;
    if (!ws || ws.readyState !== WebSocket.OPEN) return;
    try {
      ws.send(JSON.stringify({ t: "ping" }));
    } catch (_) {}
  }

  function startHeartbeat(pane) {
    stopHeartbeat(pane);
    pane.lastRx = Date.now();
    pane.hbTimer = setInterval(() => {
      const ws = pane.ws;
      if (!ws || ws.readyState !== WebSocket.OPEN) return;
      // 后台标签页的定时器会被浏览器限流；这时不做超时判断，
      // 否则在后台放一会儿就会被误判成掉线。
      if (document.hidden) return;
      if (Date.now() - pane.lastRx > STALE_MS) {
        // 发得出去、但一个心跳应答都收不到：连接已经是半开的，主动关掉重连。
        try {
          ws.close();
        } catch (_) {}
        return;
      }
      sendPing(pane);
    }, HEARTBEAT_MS);
  }

  function stopHeartbeat(pane) {
    if (pane.hbTimer) {
      clearInterval(pane.hbTimer);
      pane.hbTimer = null;
    }
  }

  function scheduleReconnect(pane) {
    if (!pane.el.isConnected || !started || !pane.retryable || pane.retryTimer) return;
    const attempt = pane.retryAttempt || 0;
    pane.retryAttempt = attempt + 1;
    const delay = Math.min(30000, 1000 * 2 ** Math.min(attempt, 5));
    setPaneStatus(pane, "已断开，正在重连…", "pending");
    pane.retryTimer = setTimeout(() => {
      pane.retryTimer = null;
      if (!pane.el.isConnected || !started || !pane.retryable) return;
      const ws = pane.ws;
      if (ws && (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING)) return;
      connectPane(pane);
    }, delay);
  }

  /// 网络恢复或页面回到前台时，正在退避等待的分屏立即重连，而不是等完
  /// 剩下的（最长 30 秒）退避时间。被接管/shell 已退出的分屏不自动重连。
  function reconnectWaitingPanes() {
    if (!started) return;
    for (const tab of tabs) {
      for (const pane of tab.panes) {
        if (pane.alive || !pane.retryable || !pane.el.isConnected) continue;
        const ws = pane.ws;
        if (ws && (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING)) continue;
        if (pane.retryTimer) {
          clearTimeout(pane.retryTimer);
          pane.retryTimer = null;
        }
        pane.retryAttempt = 0;
        connectPane(pane);
      }
    }
  }

  window.addEventListener("online", reconnectWaitingPanes);

  /// 登录成功后把因为 401 停下来的分屏全部重新拉起来。
  function retryDeadPanes() {
    for (const tab of tabs) {
      for (const pane of tab.panes) {
        if (pane.alive || !pane.el.isConnected) continue;
        pane.retryable = true;
        pane.retryAttempt = 0;
        if (pane.retryTimer) {
          clearTimeout(pane.retryTimer);
          pane.retryTimer = null;
        }
        connectPane(pane);
      }
    }
  }

  function setPaneStatus(pane, text, kind) {
    pane.status.textContent = text;
    pane.status.className = `pane-status ${kind || ""}`;
    pane.dot.className = `pane-dot ${kind || ""}`;
    // 悬浮标题栏默认隐藏；出错时常驻，方便点击重连/关闭。
    pane.bar.classList.toggle("attention", kind === "error");
    if (pane.tab) {
      pane.tab.btn.classList.toggle(
        "down",
        pane.tab.panes.some((p) => p.status.classList.contains("error"))
      );
    }
    updateSummary();
  }

  function updateSummary() {
    const total = panes.length;
    const alive = panes.filter((p) => p.alive).length;
    // 全部正常时只显示“已连接”；只有分屏掉线时才显示 alive/total，
    // 避免出现 1/1、2/2 这种没有信息量的分数。
    statusEl.textContent =
      total === 0 ? "无会话" : alive === total ? "已连接" : `${alive}/${total} 已连接`;
    statusEl.title = statusEl.textContent;
    statusEl.className = alive === total && total > 0 ? "ok" : total ? "pending" : "";
  }

  function requestCwd(pane) {
    const ws = pane.ws;
    if (!ws || ws.readyState !== WebSocket.OPEN) return;
    try {
      ws.send(JSON.stringify({ t: "cwd" }));
    } catch (_) {}
  }

  const textEncoder = new TextEncoder();

  function sendInput(pane, data) {
    if (ctrlSticky && data.length === 1) {
      const code = data.toUpperCase().charCodeAt(0);
      if (code >= 64 && code <= 95) data = String.fromCharCode(code - 64);
      ctrlSticky = false;
      if (keysBar) keysBar.querySelector('[data-key="ctrl"]').classList.remove("active");
    }
    const ws = pane.ws;
    if (!ws || ws.readyState !== WebSocket.OPEN) return;
    const bytes = textEncoder.encode(data);
    const CHUNK = 8192;
    for (let i = 0; i < bytes.length; i += CHUNK) {
      ws.send(bytes.subarray(i, i + CHUNK));
    }
    // 用户执行完一条命令（回车）后主动对一次 cwd：pwd/cd 都能立刻同步文件树，
    // 不需要等服务端 500ms 的轮询。
    if (data.includes("\r") || data.includes("\n")) {
      setTimeout(() => requestCwd(pane), 100);
    }
  }

  function sendResize(pane) {
    const ws = pane.ws;
    if (!ws || ws.readyState !== WebSocket.OPEN) return;
    ws.send(JSON.stringify({ t: "resize", cols: pane.term.cols, rows: pane.term.rows }));
  }

  function fitPane(pane) {
    // 后台标签页 / 被隐藏的 pane 量不到尺寸，强行 fit 会把终端缩成 2x1。
    if (!pane.el.isConnected || pane.el.offsetParent === null) return;
    try {
      pane.fit.fit();
    } catch (_) {
      return;
    }

    // DOM renderer 的单元格高度会取整：fit() 偶尔会多算 1 行，导致最后一行
    // 被容器裁掉。这里用真实布局尺寸校验一次，放不下就收缩。
    const host = pane.term.element;
    const screen = host && host.querySelector(".xterm-screen");
    if (host && screen) {
      // 裁切发生在 .pane-term（overflow:hidden）的边框盒，按它的尺寸判断。
      const box = pane.termEl.getBoundingClientRect();
      for (let i = 0; i < 4; i++) {
        const sr = screen.getBoundingClientRect();
        const tooWide = sr.right > box.right + 0.5;
        const tooTall = sr.bottom > box.bottom + 0.5;
        if (!tooWide && !tooTall) break;
        const cols = tooWide ? Math.max(2, pane.term.cols - 1) : pane.term.cols;
        const rows = tooTall ? Math.max(1, pane.term.rows - 1) : pane.term.rows;
        if (cols === pane.term.cols && rows === pane.term.rows) break;
        pane.term.resize(cols, rows);
      }
    }

    sendResize(pane);
  }

  const splitters = { v: null, h: null };

  function ensureSplitters() {
    if (!splitters.v) {
      const v = document.createElement("div");
      v.className = "splitter v";
      v.hidden = true;
      v.addEventListener("pointerdown", (ev) => startSplitDrag(ev, "x"));
      workspace.appendChild(v);
      splitters.v = v;
    }
    if (!splitters.h) {
      const h = document.createElement("div");
      h.className = "splitter h";
      h.hidden = true;
      h.addEventListener("pointerdown", (ev) => startSplitDrag(ev, "y"));
      workspace.appendChild(h);
      splitters.h = h;
    }
  }

  function clampSplit(v) {
    return Math.min(0.85, Math.max(0.15, v));
  }

  function startSplitDrag(ev, axis) {
    if (!activeTab) return;
    ev.preventDefault();
    const el = ev.currentTarget;
    el.setPointerCapture(ev.pointerId);
    el.classList.add("dragging");

    const move = (e) => {
      const r = workspace.getBoundingClientRect();
      if (axis === "x") {
        splitX = clampSplit((e.clientX - r.left) / r.width);
        activeTab.splitX = splitX;
      } else {
        splitY = clampSplit((e.clientY - r.top) / r.height);
        activeTab.splitY = splitY;
      }
      applyGrid(activeTab);
    };
    const up = () => {
      el.classList.remove("dragging");
      el.removeEventListener("pointermove", move);
      el.removeEventListener("pointerup", up);
      el.removeEventListener("pointercancel", up);
      // localStorage 是同步写盘：拖动过程中只改内存，松手时写一次。
      store.set(axis === "x" ? "myttty.splitX" : "myttty.splitY", String(axis === "x" ? splitX : splitY));
      saveSessions();
    };
    el.addEventListener("pointermove", move);
    el.addEventListener("pointerup", up);
    el.addEventListener("pointercancel", up);
  }

  function positionSplitters(tab) {
    const n = tab.panes.length;
    if (splitters.v) {
      splitters.v.hidden = n < 2;
      splitters.v.style.left = `${tab.splitX * 100}%`;
    }
    if (splitters.h) {
      // 3 屏时只有右列上下分，横把手从竖直分栏处开始，避免切到左边整高的 pane。
      splitters.h.hidden = n < 3;
      splitters.h.style.top = `${tab.splitY * 100}%`;
      splitters.h.style.left = n === 3 ? `${tab.splitX * 100}%` : "0";
    }
  }

  function applyGrid(tab) {
    const n = tab.panes.length;
    for (const p of tab.panes) p.el.style.gridArea = "";

    const cols = n >= 2 ? `${tab.splitX}fr ${1 - tab.splitX}fr` : "1fr";
    if (n === 3) {
      tab.el.style.gridTemplateColumns = cols;
      tab.el.style.gridTemplateRows = `${tab.splitY}fr ${1 - tab.splitY}fr`;
      tab.panes[0].el.style.gridArea = "1 / 1 / span 2 / span 1";
    } else if (n === 4) {
      tab.el.style.gridTemplateColumns = cols;
      tab.el.style.gridTemplateRows = `${tab.splitY}fr ${1 - tab.splitY}fr`;
    } else if (n === 2) {
      tab.el.style.gridTemplateColumns = cols;
      tab.el.style.gridTemplateRows = "1fr";
    } else {
      tab.el.style.gridTemplateColumns = "1fr";
      tab.el.style.gridTemplateRows = "1fr";
    }

    if (tab !== activeTab) return;
    positionSplitters(tab);
    requestAnimationFrame(() => {
      for (const p of tab.panes) fitPane(p);
    });
  }

  function layout(tab = activeTab) {
    if (!tab) return;
    tab.el.dataset.count = String(tab.panes.length);
    ensureSplitters();
    applyGrid(tab);
    if (tab !== activeTab) return;
    addPaneBtn.disabled = tab.panes.length >= MAX_PANES;
    updateSummary();
  }

  // xterm 的 attachCustomKeyEventHandler 返回 false 只是让 xterm 不再处理，
  // 不会阻止浏览器默认行为。Ctrl+Shift+C 在 Chrome/Edge 里是 DevTools 的
  // “检查元素”，所以必须自己 preventDefault，否则快捷键照样被浏览器截走。
  function consumeKey(event) {
    event.preventDefault();
    event.stopPropagation();
  }

  // 可打印字符（不含 Ctrl/Alt/Meta、组合输入和功能键）。
  function isPrintableKeyEvent(event) {
    if (event.ctrlKey || event.altKey || event.metaKey) return false;
    if (event.isComposing || event.keyCode === 229) return false;
    if (event.key && event.key.length === 1) return true;
    const code = event.keyCode || event.charCode;
    return (
      (code >= 48 && code <= 57) ||
      (code >= 65 && code <= 90) ||
      (code >= 97 && code <= 122) ||
      code === 32
    );
  }

  // 复制/粘贴只处理 Ctrl（Linux/Windows）：
  //   Ctrl+C  有选区 → 复制；没有选区 → 原样交给 shell（SIGINT）
  //   Ctrl+Insert / Ctrl+Shift+C → 复制（后者挡掉 Chrome 的 DevTools 快捷键）
  //   Ctrl+V / Ctrl+Shift+V / Shift+Insert → 不拦，交给浏览器原生 paste 事件，
  //   xterm 自己处理 bracketed paste，也不需要 clipboard-read 权限。
  // macOS 的 Cmd+C / Cmd+V 不在这里处理：xterm 本来就不会拦截它们，浏览器的
  // 原生 copy/paste 事件会照常触发，由 xterm 自己完成复制和粘贴。
  function handleTermKey(event, pane) {
    // 触摸设备：可打印字符只走 input 路径；keydown/keypress 交给浏览器默认行为
    // 产生 input，避免 xterm 在键盘事件里先发一次、input 再发一次。
    if (coarsePointer && event.type !== "keyup" && isPrintableKeyEvent(event)) {
      return false;
    }
    if (event.type !== "keydown") return true;
    if (event.key === "Escape" && !findBar.hidden) {
      closeFind();
      return false;
    }

    const explicitCopy =
      (event.ctrlKey && event.shiftKey && event.code === "KeyC") ||
      (event.ctrlKey && !event.shiftKey && event.code === "Insert");
    if (explicitCopy) {
      consumeKey(event);
      copyText(pane.term.getSelection());
      return false;
    }

    if (event.ctrlKey && !event.shiftKey && !event.altKey && event.code === "KeyC") {
      const selection = pane.term.getSelection();
      if (selection) {
        consumeKey(event);
        copyText(selection);
        // 复制后清掉选区：这样下一次 Ctrl+C 就是中断，而不是重复复制。
        pane.term.clearSelection();
        return false;
      }
      // 没有选区：交回 xterm，正常发送 ^C。
      return true;
    }

    if (event.ctrlKey && event.code === "KeyV") return false;
    if (event.shiftKey && !event.ctrlKey && !event.altKey && event.code === "Insert") return false;

    if (event.ctrlKey && event.shiftKey && event.code === "KeyF") {
      consumeKey(event);
      openFind();
      return false;
    }
    return true;
  }

  // -------------------------------------------------------------------- files

  async function api(method, action, query, body) {
    const qs = query ? `?${new URLSearchParams(query)}` : "";
    const headers = {};
    if (body !== undefined) headers["Content-Type"] = "text/plain; charset=utf-8";
    const res = await fetch(`/api/fs/${action}${qs}`, { method, headers, body });
    let data = {};
    try {
      data = await res.json();
    } catch (_) {}
    if (res.status === 401) {
      showLogin("登录已失效，请重新登录");
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
    notice("");
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
      } else {
        treeExpanded.delete(item.dir);
        treeChildren.delete(item.dir);
      }
      notice(`列目录失败: ${item.err.message}`, true);
      if (item.dir === currentDir) currentDir = "";
    }
    if (!failed.some((item) => item.dir === "")) treeRootError = false;
    if (currentDir && !treeChildren.has(currentDir)) currentDir = "";

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
    return result;
  }

  function expandPath(path) {
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

  async function ensureTreeLoaded(path, force = false) {
    if (treeLoading.has(path)) return;
    if (!force && treeChildren.has(path)) return;

    treeLoading.add(path);
    if (!treeChildren.has(path)) scheduleRender();
    try {
      const data = await loadDir(path);
      if (data.truncated) notice(`目录 ${path || "/"} 条目过多，仅显示前 1 万项`);
    } catch (err) {
      if (!treeChildren.has(path)) treeExpanded.delete(path);
      treeDirty = true;
      notice(`列目录失败: ${err.message}`, true);
    } finally {
      treeLoading.delete(path);
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
      if (currentDir === path && !filesEl.hidden) scrollTreeToSelected(alignTop);
    });
  }

  function selectDir(path) {
    if (path === currentDir && treeExpanded.has(path)) return;
    applyDir(path);
  }

  /// shell 的 cwd 变化或用户按回车后，把文件树跳到对应目录。
  /// 强制重读路径上的目录，终端里新建的目录也能立即出现在树里。
  function syncFilesToCwd(path) {
    if (typeof path !== "string" || path === currentDir) return;
    applyDir(path, true, true);
  }

  function toggleDir(path) {
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
    for (const p of [...treeChildren.keys()]) {
      if (p === oldPath || p.startsWith(`${oldPath}/`)) treeChildren.delete(p);
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
  /// 树的内容是否真的变了；批量的 force 重读如果内容没变就不再整树重建。
  let treeDirty = false;
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

  /// 展开后的可见行；只在 treeChildren/treeExpanded 变化时重建。
  let flatRows = [];
  let flatDirty = true;
  let windowStart = -1;
  let windowEnd = -1;

  const htmlEscapes = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" };
  function htmlEscape(text) {
    return String(text).replace(/[&<>"']/g, (c) => htmlEscapes[c]);
  }

  function ensureFlat() {
    if (!flatDirty) return;
    flatDirty = false;
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
    treeDirty = false;
    // 结构变化会改变视口上方的行数（例如另一个大目录的列表晚到），只保留
    // scrollTop 会让内容整体跳走。选中行还在视口附近时，记住它当时的位置，
    // 重建后按新下标补回去。
    const rowHeight = treeRowHeight();
    const oldIndex = selectedIndex();
    const offset = oldIndex >= 0 ? oldIndex * rowHeight - fileList.scrollTop : 0;
    const visible = oldIndex >= 0 && offset >= -rowHeight && offset <= fileList.clientHeight;
    flatDirty = true;
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

  window.addEventListener("resize", () => {
    rowHeightCache = 0;
    windowStart = -1;
    windowEnd = -1;
    renderWindow(true);
  });

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
      if (isDir) rebaseTree(path, newPath);
      refreshFiles([parentPath]);
    } catch (err) {
      notice(`重命名失败: ${err.message}`, true);
    }
  }

  async function deleteEntry(path, name, isDir) {
    if (!(await askConfirm(`删除 ${name}？`, "此操作不可撤销。", "删除", true))) return;
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
  const upload_chunk = 4 * 1024 * 1024;

  function randomUploadId() {
    const bytes = new Uint8Array(8);
    crypto.getRandomValues(bytes);
    return [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
  }

  function showUploadProgress(show, fraction, text) {
    uploadProgress.hidden = !show;
    if (!show) return;
    uprogFill.style.width = `${Math.max(0, Math.min(1, fraction)) * 100}%`;
    uprogText.textContent = text;
  }

  function putChunk(url, blob, onProgress) {
    return new Promise((resolve, reject) => {
      const xhr = new XMLHttpRequest();
      uploader = { xhr, cancelled: false, url };
      xhr.open("PUT", url);
      xhr.responseType = "text";
      xhr.upload.onprogress = (ev) => {
        if (ev.lengthComputable) onProgress(ev.loaded);
      };
      xhr.onload = () => {
        let data = {};
        try {
          data = JSON.parse(xhr.responseText || "{}");
        } catch (_) {}
        if (xhr.status >= 200 && xhr.status < 300) resolve(data);
        else if (xhr.status === 401) reject(new Error("unauthorized"));
        else reject(new Error(data.error || `HTTP ${xhr.status}`));
      };
      xhr.onerror = () => reject(new Error("network"));
      xhr.onabort = () => reject(new Error("cancelled"));
      xhr.send(blob);
    });
  }

  async function uploadOne(file, targetDir) {
    const path = joinPath(targetDir, file.name);
    const encoded = encodeURIComponent(path);
    const total = file.size;

    if (total === 0) {
      const res = await fetch(`/api/fs/upload?path=${encoded}`, { method: "PUT", body: new Blob([]) });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      return;
    }

    const id = randomUploadId();
    let offset = 0;
    let retries = 0;

    while (offset < total) {
      const end = Math.min(offset + upload_chunk, total);
      const blob = file.slice(offset, end);
      const url =
        `/api/fs/upload?path=${encoded}&id=${id}&offset=${offset}&total=${total}`;
      try {
        const data = await putChunk(url, blob, (loaded) => {
          showUploadProgress(
            true,
            (offset + loaded) / total,
            `${file.name} ${Math.round(((offset + loaded) / total) * 100)}%`
          );
        });
        offset = typeof data.offset === "number" ? data.offset : end;
        retries = 0;
      } catch (err) {
        if (uploader && uploader.cancelled) throw err;
        if (err.message === "unauthorized") {
          showLogin("登录已失效，请重新登录");
          throw err;
        }
        retries++;
        if (retries > 3) throw err;
        // 断点续传：向服务端确认已经写入的偏移量。
        try {
          const res = await fetch(`/api/fs/upload?path=${encoded}&id=${id}`, { method: "GET" });
          if (res.ok) {
            const data = await res.json();
            offset = data.offset || 0;
          }
        } catch (_) {}
      }
    }
  }

  async function uploadFiles(fileList, targetDir = currentDir) {
    const files = Array.from(fileList || []);
    if (files.length === 0) return;

    let done = 0;
    let failed = 0;
    showUploadProgress(true, 0, "准备上传…");

    for (const file of files) {
      if (file.size > upload_limit) {
        failed++;
        notice(`${file.name} 超过 64 MiB 上限`, true);
        continue;
      }
      try {
        await uploadOne(file, targetDir);
        done++;
      } catch (err) {
        failed++;
        if (err.message !== "cancelled") {
          notice(`上传 ${file.name} 失败: ${err.message}`, true);
        }
        if (uploader && uploader.cancelled) break;
      }
    }

    showUploadProgress(false, 0, "");
    uploader = null;
    if (failed === 0) notice(`已上传 ${done} 个文件`);
    else if (done > 0) notice(`上传完成 ${done} 个，失败 ${failed} 个`, true);
    if (targetDir) treeExpanded.add(targetDir);
    refreshFiles([targetDir]);
  }

  // 应用内文本输入弹窗；返回 null 表示取消。
  function askText(title, initial = "") {
    return new Promise((resolve) => {
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
      await api("PUT", "write", { path }, "");
      await refreshFiles();
      openEditor(path);
    } catch (err) {
      notice(`新建失败: ${err.message}`, true);
    }
  }

  async function newDir() {
    const name = await askText("新建目录");
    if (!name) return;
    const path = joinPath(currentDir, name);
    try {
      const parent = currentDir;
      await api("POST", "mkdir", { path });
      currentDir = path;
      treeExpanded.add(path);
      refreshFiles([parent]);
    } catch (err) {
      notice(`新建目录失败: ${err.message}`, true);
    }
  }

  // ------------------------------------------------------------------- editor

  async function openEditor(path) {
    if (editing && editing.dirty && editing.path !== path) {
      if (!(await askConfirm("放弃未保存的修改？", `${editing.path} 有未保存的修改，切换后会丢失。`, "放弃并切换", true))) return;
    }
    try {
      const data = await api("GET", "read", { path });
      // version 是服务端给的内容哈希；保存时带回去，文件在此期间被改过就会被拒绝。
      editing = { path, dirty: false, version: data.version || "" };
      editorPathEl.textContent = path;
      editorEl.value = data.content;
      editorStateEl.textContent = `${data.size} 字节 · 未修改`;
      editorOverlay.hidden = false;
      updateGutter();
      editorEl.focus();
      editorEl.setSelectionRange(0, 0);
    } catch (err) {
      notice(`打开失败: ${err.message}`, true);
    }
  }

  async function closeEditor() {
    if (editing && editing.dirty) {
      if (!(await askConfirm("放弃未保存的修改？", `${editing.path} 有未保存的修改，关闭后会丢失。`, "放弃并关闭", true))) return;
    }
    editing = null;
    editorOverlay.hidden = true;
  }

  async function saveEditor(force = false) {
    if (!editing) return;
    const target = editing;
    const query = { path: target.path };
    if (!force && target.version) query.base = target.version;
    const text = editorEl.value;
    try {
      const res = await api("PUT", "write", query, text);
      if (editing !== target) return;
      editing.version = res.version || "";
      // 保存请求在路上时用户可能又敲了字：那部分仍算未保存。
      editing.dirty = editorEl.value !== text;
      editorStateEl.textContent = editing.dirty ? "未保存的修改" : `${res.size} 字节 · 已保存`;
      notice(`已保存 ${editing.path}`);
      refreshFiles([parentOf(editing.path)]);
    } catch (err) {
      if (editing !== target) return;
      if (err.code === "modified_on_disk") {
        editorStateEl.textContent = "文件已在别处被修改";
        const overwrite = await askConfirm(
          "文件已在别处被修改",
          `${target.path} 在打开之后被其他程序改过（或已被删除）。覆盖会丢掉那些修改。`,
          "仍然覆盖",
          true
        );
        if (overwrite && editing === target) saveEditor(true);
        else editorEl.focus();
        return;
      }
      editorStateEl.textContent = `保存失败: ${err.message}`;
      notice(`保存失败: ${err.message}`, true);
    }
  }

  editorEl.addEventListener("input", () => {
    if (!editing) return;
    editing.dirty = true;
    editorStateEl.textContent = "未保存的修改";
    scheduleGutter();
  });
  editorEl.addEventListener("keydown", (ev) => {
    if ((ev.ctrlKey || ev.metaKey) && ev.key.toLowerCase() === "s") {
      ev.preventDefault();
      saveEditor();
    }
  });
  editorSaveBtn.addEventListener("click", () => saveEditor());
  editorCloseBtn.addEventListener("click", closeEditor);
  window.addEventListener("keydown", (ev) => {
    if (!promptOverlay.hidden) return;
    if (ev.key === "Escape" && !editorOverlay.hidden) {
      ev.preventDefault();
      closeEditor();
    }
  });

  // -------------------------------------------------------------------- boot

  addPaneBtn.addEventListener("click", () => createPane());
  tabAddBtn.addEventListener("click", () => newTab());
  tabMoreBtn.addEventListener("click", (ev) => {
    ev.stopPropagation();
    if (tabMenuEl.hidden) openTabMenu();
    else closeTabMenu();
  });
  document.addEventListener("click", (ev) => {
    if (tabMenuEl.hidden) return;
    if (tabMoreBtn.contains(ev.target) || tabMenuEl.contains(ev.target)) return;
    closeTabMenu();
  });
  document.addEventListener(
    "keydown",
    (ev) => {
      if (ev.key !== "Escape" || tabMenuEl.hidden) return;
      ev.preventDefault();
      ev.stopPropagation();
      closeTabMenu();
    },
    true
  );

  findInput.addEventListener("input", () => runFind(false, true));
  findInput.addEventListener("keydown", (ev) => {
    if (ev.key === "Enter") {
      ev.preventDefault();
      runFind(ev.shiftKey, false);
    } else if (ev.key === "Escape") {
      ev.preventDefault();
      closeFind();
    }
  });
  document.getElementById("find-prev").addEventListener("click", () => runFind(true, false));
  document.getElementById("find-next").addEventListener("click", () => runFind(false, false));
  document.getElementById("find-close").addEventListener("click", closeFind);

  interruptBtn.addEventListener("click", () => sendKey("ctrlc"));
  fontDecBtn.addEventListener("click", () => setFontSize(fontsize - 1));
  fontIncBtn.addEventListener("click", () => setFontSize(fontsize + 1));

  keysBar.addEventListener("click", (ev) => {
    const btn = ev.target.closest("button[data-key]");
    if (btn) sendKey(btn.dataset.key);
  });

  window.addEventListener("keydown", (ev) => {
    if (!promptOverlay.hidden) return;
    const mod = ev.ctrlKey || ev.metaKey;
    if (mod && ev.shiftKey && (ev.key === "+" || ev.key === "=" || ev.code === "Equal")) {
      ev.preventDefault();
      setFontSize(fontsize + 1);
      return;
    }
    if (mod && ev.shiftKey && (ev.key === "-" || ev.key === "_" || ev.code === "Minus")) {
      ev.preventDefault();
      setFontSize(fontsize - 1);
      return;
    }
    if (ev.key === "F3") {
      ev.preventDefault();
      if (findBar.hidden) openFind();
      else runFind(ev.shiftKey, false);
      return;
    }
    if (ev.key === "Escape") {
      if (!editorOverlay.hidden) return; // 编辑器自己处理
      if (!findBar.hidden) {
        ev.preventDefault();
        closeFind();
      }
    }
  });
  filesBtn.addEventListener("click", () => {
    filesEl.hidden = !filesEl.hidden;
    filesResizeEl.hidden = filesEl.hidden;
    if (!filesEl.hidden) {
      refreshFiles([...treeExpanded])
        .then(() => {
          if (!filesEl.hidden) scrollTreeToSelected(true);
        })
        .catch(() => {});
      requestAnimationFrame(() => panes.forEach(fitPane));
    }
  });
  document.getElementById("files-refresh").addEventListener("click", () => refreshFiles([...treeExpanded]));
  cwdSyncBtn.addEventListener("click", () => setCwdSync(!cwdSyncEnabled));
  setCwdSync(cwdSyncEnabled, false);
  document.getElementById("files-new-file").addEventListener("click", newFile);
  document.getElementById("files-new-dir").addEventListener("click", newDir);
  filesResizeEl.addEventListener("pointerdown", startFilesResize);
  filesResizeEl.addEventListener("dblclick", () => setFilesWidth(300, true));
  setFilesWidth(filesWidth);

  uploadBtn.addEventListener("click", () => uploadInput.click());
  uprogCancel.addEventListener("click", () => {
    if (!uploader) return;
    uploader.cancelled = true;
    try {
      uploader.xhr.abort();
    } catch (_) {}
    fetch(uploader.url.replace(/&offset=.*$/, "").replace(/&total=.*$/, ""), { method: "DELETE" }).catch(() => {});
  });
  uploadInput.addEventListener("change", () => {
    uploadFiles(uploadInput.files);
    uploadInput.value = "";
  });
  filesEl.addEventListener("dragover", (ev) => {
    ev.preventDefault();
    filesEl.classList.add("drop");
  });
  filesEl.addEventListener("dragleave", () => filesEl.classList.remove("drop"));
  filesEl.addEventListener("drop", (ev) => {
    ev.preventDefault();
    filesEl.classList.remove("drop");
    if (ev.dataTransfer && ev.dataTransfer.files.length) uploadFiles(ev.dataTransfer.files);
  });

  let resizeQueued = false;
  const ro = new ResizeObserver(() => {
    if (resizeQueued) return;
    resizeQueued = true;
    requestAnimationFrame(() => {
      resizeQueued = false;
      for (const p of panes) fitPane(p);
    });
  });
  ro.observe(workspace);

  // 终端尺寸统一交给上面的 ResizeObserver（已按帧合并）；这里再 fit 一遍
  // 只会让每次窗口拖动多做一轮强制同步布局。
  window.addEventListener("resize", () => {
    setFilesWidth(filesWidth);
    layoutTabs();
  });
  if (document.fonts && document.fonts.ready) {
    document.fonts.ready.then(() => {
      panes.forEach(fitPane);
      layoutTabs();
    });
  }
  document.addEventListener("visibilitychange", () => {
    if (!document.hidden) {
      panes.forEach(fitPane);
      // 后台时心跳暂停；回到前台先确认连接还活着，半开的连接会被心跳关掉重连。
      for (const tab of tabs) {
        for (const pane of tab.panes) {
          pane.lastRx = Date.now();
          sendPing(pane);
        }
      }
      reconnectWaitingPanes();
    }
  });

  if (window.matchMedia && window.matchMedia("(max-width: 820px)").matches) {
    hintEl.textContent = "";
    filesEl.hidden = true;
  }

  // 低饱和配色：与页面外壳共用同一组中性色，避免终端里突然跳出高饱和色块。
  const terminalTheme = {
    background: "#101319",
    foreground: "#c8cdd8",
    cursor: "#8ea3c0",
    cursorAccent: "#101319",
    selectionBackground: "#2b3444",
    black: "#191d25",
    red: "#c18d92",
    green: "#9fb392",
    yellow: "#c2b18c",
    blue: "#8ba1bf",
    magenta: "#b09eb4",
    cyan: "#8fafb2",
    white: "#c2c7d1",
    brightBlack: "#4a5262",
    brightRed: "#d0a0a5",
    brightGreen: "#b2c5a6",
    brightYellow: "#d3c39f",
    brightBlue: "#a3b7d1",
    brightMagenta: "#c2b1c5",
    brightCyan: "#a2c0c2",
    brightWhite: "#e0e4ec",
  };

  // ------------------------------------------------------------ 搜索/字号

  function openFind() {
    if (!activePane) return;
    findBar.hidden = false;
    findCount.textContent = "";
    findInput.focus();
    findInput.select();
  }

  function closeFind() {
    findBar.hidden = true;
    findCount.textContent = "";
    for (const p of panes) {
      p.search.clearDecorations();
      p.term.clearSelection();
    }
    if (activePane) activePane.term.focus();
    requestAnimationFrame(() => panes.forEach(fitPane));
  }

  function runFind(backwards, incremental) {
    const pane = activePane;
    if (!pane) return;
    const query = findInput.value;
    if (!query) {
      pane.search.clearDecorations();
      pane.term.clearSelection();
      findCount.textContent = "";
      return;
    }
    const options = { caseSensitive: false, incremental };
    let found = backwards
      ? pane.search.findPrevious(query, options)
      : pane.search.findNext(query, options);
    if (!found && incremental) {
      // 输入时是增量查找（从上次结果继续）；没找到就从缓冲区头/尾再兜底一次，
      // 否则光标后方的历史输出会看起来像“没有结果”。
      const wrap = { caseSensitive: false };
      found = backwards
        ? pane.search.findPrevious(query, wrap)
        : pane.search.findNext(query, wrap);
    }
    findCount.textContent = found ? "" : incremental ? "" : "无结果";
  }

  function setFontSize(next) {
    fontsize = clampFont(next);
    store.set("myttty.fontsize", String(fontsize));
    for (const tab of tabs) {
      for (const p of tab.panes) {
        p.term.options.fontSize = fontsize;
        if (tab === activeTab) fitPane(p);
      }
    }
  }

  // --------------------------------------------------------- 剪贴板兜底

  function copyText(text) {
    if (!text) return Promise.resolve();
    if (navigator.clipboard && navigator.clipboard.writeText) {
      return navigator.clipboard.writeText(text).catch(() => legacyCopy(text));
    }
    legacyCopy(text);
    return Promise.resolve();
  }

  function legacyCopy(text) {
    const ta = document.createElement("textarea");
    ta.value = text;
    ta.setAttribute("readonly", "");
    ta.style.position = "fixed";
    ta.style.opacity = "0";
    document.body.appendChild(ta);
    ta.select();
    try {
      document.execCommand("copy");
    } catch (_) {}
    ta.remove();
  }

  // ---------------------------------------------------------- 移动按键条

  let ctrlSticky = false;

  const keySequences = {
    esc: "\x1b",
    tab: "\t",
    up: "\x1b[A",
    down: "\x1b[B",
    right: "\x1b[C",
    left: "\x1b[D",
    ctrlc: "\x03",
    ctrld: "\x04",
    ctrll: "\x0c",
  };

  function sendKey(name) {
    const pane = activePane;
    if (!pane) return;
    if (name === "ctrl") {
      ctrlSticky = !ctrlSticky;
      keysBar.querySelector('[data-key="ctrl"]').classList.toggle("active", ctrlSticky);
      pane.term.focus();
      return;
    }
    const seq = keySequences[name];
    if (seq == null) return;
    sendInput(pane, seq);
    if (ctrlSticky) {
      ctrlSticky = false;
      keysBar.querySelector('[data-key="ctrl"]').classList.remove("active");
    }
    pane.term.focus();
  }

  // ------------------------------------------------------------- 编辑辅助

  // 大文件（上限 1 MiB，可能几万行）每按一个键都重建行号会明显卡顿：
  // 输入事件按帧合并，行数没变就不动 DOM。
  let gutterLines = 0;
  let gutterQueued = false;

  function countLines(value) {
    let count = 1;
    let i = -1;
    while ((i = value.indexOf("\n", i + 1)) !== -1) count += 1;
    if (value.endsWith("\n")) count -= 1;
    return Math.max(1, count);
  }

  function updateGutter() {
    const count = countLines(editorEl.value);
    if (count !== gutterLines) {
      gutterLines = count;
      const lines = new Array(count);
      for (let i = 0; i < count; i++) lines[i] = i + 1;
      editorGutter.textContent = lines.join("\n") + "\n";
    }
    editorGutter.scrollTop = editorEl.scrollTop;
  }

  function scheduleGutter() {
    if (gutterQueued) return;
    gutterQueued = true;
    requestAnimationFrame(() => {
      gutterQueued = false;
      updateGutter();
    });
  }

  editorEl.addEventListener("scroll", () => {
    editorGutter.scrollTop = editorEl.scrollTop;
  });
  editorEl.addEventListener("keydown", (ev) => {
    if (ev.key === "Tab") {
      ev.preventDefault();
      const start = editorEl.selectionStart;
      const end = editorEl.selectionEnd;
      editorEl.setRangeText("  ", start, end, "end");
      editorEl.dispatchEvent(new Event("input"));
    }
  });
  window.addEventListener("beforeunload", (ev) => {
    if (editing && editing.dirty) {
      ev.preventDefault();
      ev.returnValue = "";
    }
  });

  // -------------------------------------------------------------- 弹窗

  // ------------------------------------------------------------- 登录状态

  function showLogin(message) {
    loginOverlay.hidden = false;
    loginError.textContent = message || "";
    loginPassword.value = "";
    setTimeout(() => loginPassword.focus(), 30);
  }

  function hideLogin() {
    loginOverlay.hidden = true;
    loginError.textContent = "";
  }

  async function startApp() {
    hideLogin();
    if (started) {
      // 重新登录后：恢复心跳检查，并把因 401 停下来的分屏接回去。
      startAuthKeepalive();
      retryDeadPanes();
      return;
    }
    started = true;
    // 终端字体必须在创建 Terminal 之前就绪，否则 xterm 会按回退字体算字宽，
    // 之后字体加载完也不会重算 letter-spacing，方框/方块字符会出现缝隙。
    try {
      await document.fonts.load('14px "JetBrains Mono"');
      await document.fonts.ready;
    } catch (_) {}
    if (tabs.length === 0) {
      const restored = restoreTabs();
      if (!restored) newTab();
    } else {
      layout();
    }
    layoutTabs();
    refreshFiles();
    startAuthKeepalive();
  }

  function validSessionId(sid) {
    return typeof sid === "string" && /^[0-9a-f]{32}$/.test(sid);
  }

  function restoreTabs() {
    let saved = null;
    try {
      saved = JSON.parse(sessionStorage.getItem("myttty.tabs") || "null");
    } catch (_) {}

    if (saved && Array.isArray(saved.tabs) && saved.tabs.length) {
      for (const t of saved.tabs.slice(0, MAX_TABS)) {
        const tab = addTab();
        if (!tab) break;
        const sx = Number(t && t.x);
        const sy = Number(t && t.y);
        if (Number.isFinite(sx)) tab.splitX = clampSplit(sx);
        if (Number.isFinite(sy)) tab.splitY = clampSplit(sy);
        // 先让标签页可见再创建终端，避免在 display:none 的容器里 open()。
        activateTab(tab);
        const ids = Array.isArray(t && t.s) ? t.s.slice(0, MAX_PANES) : [];
        for (const sid of ids) {
          if (validSessionId(sid)) createPane(sid, tab);
        }
        if (tab.panes.length === 0) createPane("", tab);
      }
      const wanted = Number.isInteger(saved.active) ? saved.active : 0;
      activateTab(tabs[Math.min(Math.max(wanted, 0), tabs.length - 1)]);
      return true;
    }

    // 兼容旧版本：只有一组 pane 会话 id。
    try {
      const old = JSON.parse(sessionStorage.getItem("myttty.sessions") || "null");
      if (Array.isArray(old) && old.length) {
        const tab = addTab();
        activateTab(tab);
        for (const sid of old.slice(0, MAX_PANES)) {
          if (validSessionId(sid)) createPane(sid, tab);
        }
        if (tab.panes.length === 0) createPane("", tab);
        return true;
      }
    } catch (_) {}
    return false;
  }

  function stopApp() {
    started = false;
    stopAuthKeepalive();
    for (const tab of [...tabs]) {
      for (const pane of [...tab.panes]) removePane(pane, false);
      tab.el.remove();
      tab.btn.remove();
    }
    tabs.length = 0;
    activeTab = null;
    tabSeq = 0;
    panes = [];
    activePane = null;
    if (splitters.v) splitters.v.hidden = true;
    if (splitters.h) splitters.h.hidden = true;
    updateTabHint();
    updateSummary();
    try {
      sessionStorage.removeItem("myttty.tabs");
      sessionStorage.removeItem("myttty.sessions");
    } catch (_) {}
  }

  const AUTH_CHECK_MS = 5 * 60 * 1000;
  let authCheckTimer = null;

  /// 页面开着就一直保持登录会话活跃。
  ///
  /// 服务端的空闲超时只被 HTTP 请求刷新，终端里的按键走 WebSocket 不算；
  /// 没有这个心跳，挂着一个终端但从不刷新页面也会在 session_idle_hours 后过期。
  function startAuthKeepalive() {
    if (authCheckTimer) return;
    authCheckTimer = setInterval(async () => {
      try {
        const res = await fetch("/api/auth/status", { cache: "no-store" });
        if (res.status === 401) {
          stopAuthKeepalive();
          showLogin("登录已失效，请重新登录");
        }
      } catch (_) {
        // 网络抖动不代表登录失效：保持现状，下一轮再试。
      }
    }, AUTH_CHECK_MS);
  }

  function stopAuthKeepalive() {
    if (authCheckTimer) {
      clearInterval(authCheckTimer);
      authCheckTimer = null;
    }
  }

  async function refreshAuth(attempt = 0) {
    try {
      // 状态接口本身也要求认证：401 才是“未登录”。
      const res = await fetch("/api/auth/status", { cache: "no-store" });
      if (res.ok) {
        startApp();
        return;
      }
      if (res.status === 401) {
        showLogin();
        return;
      }
      if (attempt < 3) {
        setTimeout(() => refreshAuth(attempt + 1), 300 * (attempt + 1));
        return;
      }
      showLogin(`服务端错误（HTTP ${res.status}），正在重试…`);
      setTimeout(() => refreshAuth(0), 5000);
    } catch (_) {
      // 请求失败可能只是网络还没恢复（手机刚解锁、Wi-Fi 正在重连），
      // 不代表密码失效：自动退避重试，恢复后会直接进入界面。
      if (attempt === 0) showLogin("无法连接服务端，正在自动重试…");
      const delay = Math.min(5000, 400 * (attempt + 1));
      setTimeout(() => refreshAuth(attempt + 1), delay);
    }
  }

  loginForm.addEventListener("submit", async (ev) => {
    ev.preventDefault();
    const password = loginPassword.value;
    if (!password) return;
    loginSubmit.disabled = true;
    loginError.textContent = "";
    try {
      const res = await fetch("/api/auth/login", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ password }),
      });
      if (!res.ok) {
        loginError.textContent =
          res.status === 401 ? "密码不正确" : `登录失败（HTTP ${res.status}）`;
        loginPassword.select();
        return;
      }
      loginPassword.value = "";
      startApp();
    } catch (_) {
      loginError.textContent = "网络错误，请重试";
    } finally {
      loginSubmit.disabled = false;
    }
  });

  logoutBtn.addEventListener("click", async () => {
    logoutBtn.disabled = true;
    try {
      await fetch("/api/auth/logout", { method: "POST" });
    } catch (_) {}
    logoutBtn.disabled = false;
    stopApp();
    showLogin("已注销");
  });

  // 浏览器回归测试用：?debug=1 时暴露只读的实时状态（不包含任何凭据）。
  if (new URLSearchParams(location.search).has("debug")) {
    Object.defineProperty(window, "__myttyDebug", {
      value: {
        get panes() {
          return panes;
        },
        allPanes: () => tabs.flatMap((tab) => tab.panes),
        ping: () => tabs.flatMap((tab) => tab.panes).forEach(sendPing),
        closeWs: () =>
          tabs.flatMap((tab) => tab.panes).forEach((pane) => {
            if (!pane.ws) return;
            try {
              pane.ws.close();
            } catch (_) {}
          }),
      },
    });
  }

  refreshAuth();
})();
