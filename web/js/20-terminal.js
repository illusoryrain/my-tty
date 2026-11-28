  // ---------------------------------------------------------------- terminals

  function createPane(initialSession = "", tab = activeTab) {
    if (!tab || tab.panes.length >= MAX_PANES) return;

    const el = document.createElement("section");
    el.className = "pane";
    el.innerHTML = `
      <div class="pane-bar">
        <span class="pane-grip" title="拖动调整位置" aria-hidden="true"></span>
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
      authStopped: false,
      opens: 0,
      // 终端输出写队列：xterm 还在解析上一批时到达的帧先攒起来，下一批合成一次 write。
      outQueue: [],
      outQueued: 0,
      dropping: false,
      outWriting: false,
    };
    tab.panes.push(pane);
    tab.activePane = pane;
    if (tab === activeTab) panes = tab.panes;

    term.attachCustomKeyEventHandler((event) => handleTermKey(event, pane));
    term.onData((data) => sendInput(pane, data));
    term.onResize(() => sendResize(pane));

    el.addEventListener("mousedown", (ev) => {
      // 拖动悬浮状态栏时不要把焦点打到终端上（移动端会弹出软键盘）。
      if (ev.target.closest(".pane-bar")) return;
      focusPane(pane);
    });
    termEl.addEventListener("focusin", () => focusPane(pane));
    el.querySelector(".pane-close").addEventListener("click", (ev) => {
      ev.stopPropagation();
      removePane(pane);
    });
    el.querySelector(".pane-grip").addEventListener("pointerdown", (ev) => startPaneBarDrag(ev, pane));
    status.addEventListener("click", () => {
      if (!pane.alive && pane.reconnect) pane.reconnect();
    });

    connectPane(pane);
    layout(tab);
    if (tab === activeTab) focusPane(pane);
    requestAnimationFrame(() => positionPaneBar(pane));
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
      // 只持久化终端标签；文件编辑标签不恢复内容，刷新后重新打开即可。
      const termTabs = tabs.filter((t) => t.kind === "terminal");
      sessionStorage.setItem(
        "myttty.tabs",
        JSON.stringify({
          active: Math.max(0, termTabs.indexOf(activeTab)),
          tabs: termTabs.map((t) => ({
            x: t.splitX,
            y: t.splitY,
            a: Math.max(0, t.panes.indexOf(t.activePane)),
            s: t.panes.map((p) => p.sessionId || ""),
          })),
        })
      );
    } catch (_) {}
  }

  function markAuthStopped() {
    for (const t of tabs) for (const p of t.panes) p.authStopped = true;
  }

  function connectPane(pane) {
    if (!pane.el.isConnected) return;
    if (pane.retryTimer) {
      clearTimeout(pane.retryTimer);
      pane.retryTimer = null;
    }
    const current = pane.ws;
    if (current && (current.readyState === WebSocket.OPEN || current.readyState === WebSocket.CONNECTING)) {
      return;
    }
    setPaneStatus(pane, "连接中…", "pending");
    pane.reconnect = () => connectPane(pane);

    // 浏览器会在同源 WebSocket 握手里自动带 HttpOnly Cookie，把票据从 URL
    // 里去掉，代理日志和网络抓包就看不到任何可用凭据。
    let url = `${wsBase}?offset=${pane.offset}`;
    if (pane.sessionId) url += `&session=${encodeURIComponent(pane.sessionId)}`;

    let ws;
    try {
      ws = new WebSocket(url);
    } catch (err) {
      scheduleReconnect(pane);
      return;
    }
    ws.binaryType = "arraybuffer";
    pane.ws = ws;
    pane.reconnect = () => connectPane(pane);

    ws.onopen = () => {
      if (pane.ws !== ws) return;
      pane.alive = true;
      pane.authStopped = false;
      pane.dropping = false;
      pane.opens += 1;
      pane.retryAttempt = 0;
      pane.retryable = true;
      startHeartbeat(pane);
      setPaneStatus(pane, "已连接", "ok");
      fitPane(pane);
      // 自动重连不能抢焦点/切活动分屏；只有本来就是当前分屏、且没有弹窗时才恢复焦点。
      if (pane.tab === activeTab && activePane === pane && promptOverlay.hidden && loginOverlay.hidden) {
        pane.term.focus();
      }
      updateSummary();
    };
    ws.onmessage = (event) => {
      if (pane.ws !== ws) return;
      pane.lastRx = Date.now();
      if (typeof event.data !== "string") {
        // 已经决定丢弃队列并重连时，后续帧不能再计入 offset，
        // 否则服务端回放会从错误的位置开始，丢掉的字节就补不回来了。
        if (pane.dropping) return;
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
    ws.onclose = async (event) => {
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
      // WebSocket 握手 401 在浏览器里只会变成 1006；用状态接口区分“掉线”和
      // “登录过期”，避免过期后无限重连。
      try {
        const res = await fetch("/api/auth/status", { cache: "no-store" });
        if (pane.ws && pane.ws !== ws) return;
        if (!started || !pane.el.isConnected) return;
        if (res.status === 401) {
          markAuthStopped();
          stopAuthKeepalive();
          showLogin("登录已失效，请重新登录");
          return;
        }
      } catch (_) {}
      // 状态请求是异步的；期间用户可能已经点了重连并建立了新连接，或者
      // 已经注销/关闭了分屏。旧连接的收尾不能改动新连接/已移除的分屏。
      if (pane.ws && pane.ws !== ws) return;
      if (!started || !pane.el.isConnected) return;
      if (pane.retryable) {
        scheduleReconnect(pane);
      } else if (pane.status.textContent === "连接中…" || pane.status.textContent === "已连接") {
        setPaneStatus(pane, "已断开（点击重连）", "error");
      }
    };
    ws.onerror = () => {
      if (pane.ws !== ws) return;
      if (!pane.alive) setPaneStatus(pane, "连接被拒绝", "error");
    };
  }

  // 刷屏（cat 大文件、编译日志）时服务端每次 PTY 读取就是一帧；逐帧 term.write
  // 会让 xterm 排起成千上万个小任务。这里同一时间只让一批在 xterm 里解析，
  // 期间到达的帧在完成回调里合并成一次 write。顺序不变，也不丢字节。
  // 单次 write 的上限：刷屏时待写帧可能很多，按块合并，避免一次分配几 MB
  // 的连续缓冲；xterm 内部仍会按自己的节奏解析。
  const MAX_WRITE_BATCH = 256 * 1024;
  // 后台标签不解析输出；队列超过这个量就断开重连，靠服务端环形缓冲回放，
  // 避免低端设备被一条刷屏命令拖到 OOM。
  const MAX_OUT_QUEUE = 8 * 1024 * 1024;

  function queueOutput(pane, bytes) {
    if (pane.outQueued + bytes.byteLength > MAX_OUT_QUEUE) {
      // offset 已经在 onmessage 里按收到顺序前进；把还没交给 xterm 的部分退回去，
      // 重连后从服务端环形缓冲重新回放。正在 write 的那一块不计入 outQueued，
      // 它会正常显示，所以也不能退回。
      pane.offset = Math.max(0, pane.offset - pane.outQueued - bytes.byteLength);
      pane.outQueue = [];
      pane.outQueued = 0;
      pane.dropping = true;
      setPaneStatus(pane, "输出过快，正在重连", "pending");
      try {
        pane.ws?.close();
      } catch (_) {}
      return;
    }
    pane.outQueue.push(bytes);
    pane.outQueued += bytes.byteLength;
    if (pane.tab === activeTab && !document.hidden && !pane.outWriting) flushOutput(pane);
  }

  function flushOutput(pane) {
    // 同一时刻只允许一个 write 在 xterm 里排队；完成回调会再触发下一批。
    // 切标签/回到前台时可以直接调用，不必关心是否已有 write 在途。
    if (pane.outWriting) return;
    if (pane.tab !== activeTab || document.hidden) return;
    if (pane.outQueue.length === 0 || !pane.el.isConnected) {
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
    pane.term.write(chunk, () => {
      pane.outWriting = false;
      flushOutput(pane);
    });
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
        if (pane.alive || !pane.el.isConnected || !pane.authStopped) continue;
        pane.authStopped = false;
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

  function positionPaneBar(pane) {
    const bar = pane.bar;
    if (!bar || !pane.el.isConnected) return;
    const w = pane.el.clientWidth;
    const h = pane.el.clientHeight;
    const bw = bar.offsetWidth;
    const bh = bar.offsetHeight;
    if (!w || !h || !bw || !bh) return;
    // 状态栏位置按“可移动空间”归一化（0..1），窗口/分屏尺寸变化后仍然成立。
    const maxX = Math.max(0, w - bw - 6);
    const maxY = Math.max(0, h - bh - 6);
    const x = Math.min(maxX, Math.max(0, paneBarPos.x * maxX));
    const y = Math.min(maxY, Math.max(0, paneBarPos.y * maxY));
    bar.style.left = `${Math.round(x)}px`;
    bar.style.top = `${Math.round(y)}px`;
    bar.style.right = "auto";
  }

  function startPaneBarDrag(ev, pane) {
    if (ev.button !== 0 || !pane.bar) return;
    // 触摸布局里状态栏固定在 pane 顶部（position: static），不需要也不能拖。
    if (getComputedStyle(pane.bar).position === "static") return;
    const handle = ev.currentTarget;
    const bar = pane.bar;
    const pr = pane.el.getBoundingClientRect();
    const br = bar.getBoundingClientRect();
    const grabX = ev.clientX - br.left;
    const grabY = ev.clientY - br.top;
    let moved = false;

    const move = (e) => {
      if (!moved && Math.hypot(e.clientX - ev.clientX, e.clientY - ev.clientY) < 3) return;
      moved = true;
      bar.classList.add("dragging");
      const maxX = Math.max(0, pr.width - bar.offsetWidth - 6);
      const maxY = Math.max(0, pr.height - bar.offsetHeight - 6);
      const left = Math.min(maxX, Math.max(0, e.clientX - pr.left - grabX));
      const top = Math.min(maxY, Math.max(0, e.clientY - pr.top - grabY));
      bar.style.left = `${Math.round(left)}px`;
      bar.style.top = `${Math.round(top)}px`;
      bar.style.right = "auto";
      paneBarPos = { x: maxX ? left / maxX : 0, y: maxY ? top / maxY : 0 };
    };
    const up = () => {
      handle.removeEventListener("pointermove", move);
      handle.removeEventListener("pointerup", up);
      handle.removeEventListener("pointercancel", up);
      bar.classList.remove("dragging");
      try {
        handle.releasePointerCapture(ev.pointerId);
      } catch (_) {}
      if (!moved) return;
      store.set("myttty.paneBar", JSON.stringify(paneBarPos));
      for (const t of tabs) {
        for (const p of t.panes) positionPaneBar(p);
      }
    };

    try {
      handle.setPointerCapture(ev.pointerId);
    } catch (_) {}
    handle.addEventListener("pointermove", move);
    handle.addEventListener("pointerup", up);
    handle.addEventListener("pointercancel", up);
  }

  function setPaneStatus(pane, text, kind) {
    pane.status.textContent = text;
    pane.status.className = `pane-status ${kind || ""}`;
    pane.dot.className = `pane-dot ${kind || ""}`;
    // 悬浮标题栏默认隐藏；出错时常驻，方便点击重连/关闭。
    pane.bar.classList.toggle("attention", kind === "error");
    positionPaneBar(pane);
    if (pane.tab) {
      pane.tab.btn.classList.toggle(
        "down",
        pane.tab.panes.some((p) => p.status.classList.contains("error"))
      );
    }
    updateSummary();
  }

  function updateSummary() {
    if (activeTab && activeTab.kind === "editor") {
      const ed = activeTab.editor;
      keysBar.hidden = true;
      interruptBtn.disabled = true;
      statusEl.textContent = ed ? (ed.dirty ? `${ed.name} · 未保存` : ed.name) : "文件";
      statusEl.title = ed ? ed.path : "";
      statusEl.className = ed && ed.dirty ? "pending" : "";
      return;
    }
    keysBar.hidden = false;
    interruptBtn.disabled = false;
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
      try {
        ws.send(bytes.subarray(i, i + CHUNK));
      } catch (_) {
        return;
      }
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
    try {
      ws.send(JSON.stringify({ t: "resize", cols: pane.term.cols, rows: pane.term.rows }));
    } catch (_) {}
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
    positionPaneBar(pane);
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
    if (tab.kind === "editor") {
      tab.el.dataset.count = "";
      if (splitters.v) splitters.v.hidden = true;
      if (splitters.h) splitters.h.hidden = true;
      if (tab === activeTab) {
        addPaneBtn.disabled = true;
        updateSummary();
      }
      return;
    }
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
    if (event.key === "F3") {
      consumeKey(event);
      if (findBar.hidden) openFind();
      else runFind(event.shiftKey, false);
      return false;
    }
    return true;
  }

