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
        const a = Number.isInteger(t && t.a) ? t.a : tab.panes.length - 1;
        tab.activePane = tab.panes[Math.min(Math.max(a, 0), tab.panes.length - 1)] || null;
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
      const epoch = authEpoch;
      try {
        const res = await fetch("/api/auth/status", { cache: "no-store" });
        if (epoch !== authEpoch || !started) return;
        if (res.status === 401) {
          markAuthStopped();
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

  let authEpoch = 0;

  async function refreshAuth(attempt = 0, epoch = authEpoch) {
    if (epoch !== authEpoch) return;
    try {
      // 状态接口本身也要求认证：401 才是“未登录”。
      const res = await fetch("/api/auth/status", { cache: "no-store" });
      if (epoch !== authEpoch) return;
      if (res.ok) {
        startApp();
        return;
      }
      if (res.status === 401) {
        if (epoch === authEpoch) showLogin();
        return;
      }
      if (attempt < 3) {
        setTimeout(() => refreshAuth(attempt + 1, epoch), 300 * (attempt + 1));
        return;
      }
      showLogin(`服务端错误（HTTP ${res.status}），正在重试…`);
      setTimeout(() => refreshAuth(0, epoch), 5000);
    } catch (_) {
      if (epoch !== authEpoch) return;
      // 请求失败可能只是网络还没恢复（手机刚解锁、Wi-Fi 正在重连），
      // 不代表密码失效：自动退避重试，恢复后会直接进入界面。
      if (attempt === 0) showLogin("无法连接服务端，正在自动重试…");
      const delay = Math.min(5000, 400 * (attempt + 1));
      setTimeout(() => refreshAuth(attempt + 1, epoch), delay);
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
      authEpoch++;
      startApp();
    } catch (_) {
      loginError.textContent = "网络错误，请重试";
    } finally {
      loginSubmit.disabled = false;
    }
  });

  logoutBtn.addEventListener("click", async () => {
    const dirty = tabs.filter((t) => t.kind === "editor" && t.editor && t.editor.dirty);
    if (dirty.length && !(await askConfirm(
      "退出登录？",
      `有 ${dirty.length} 个未保存的编辑页，退出后会丢失。`,
      "退出并丢弃",
      true
    ))) return;

    logoutBtn.disabled = true;
    let ok = false;
    try {
      ok = (await fetch("/api/auth/logout", { method: "POST" })).ok;
    } catch (_) {}
    logoutBtn.disabled = false;
    if (!ok) {
      notice("注销失败，请检查网络后重试", true);
      return;
    }
    authEpoch++;
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
