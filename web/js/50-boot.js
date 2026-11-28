
  let resizeFrame = 0;
  window.addEventListener("resize", () => {
    if (resizeFrame) return;
    resizeFrame = requestAnimationFrame(() => {
      resizeFrame = 0;
      rowHeightCache = 0;
      windowStart = -1;
      windowEnd = -1;
      if (!filesEl.hidden) renderWindow(true);
      setFilesWidth(filesWidth);
      layoutTabs();
    });
  });

  addPaneBtn.addEventListener("click", () => {
    if (!activeTab || activeTab.kind !== "terminal") return;
    createPane();
  });
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
      if (!findBar.hidden) {
        ev.preventDefault();
        closeFind();
        return;
      }
      if (!promptOverlay.hidden || !loginOverlay.hidden) return;
      // 焦点在编辑器工具栏（例如刚点过保存）时，Esc 也要能关闭编辑标签。
      if (
        activeTab &&
        activeTab.kind === "editor" &&
        !(ev.target instanceof Element && ev.target.closest("#find-bar"))
      ) {
        ev.preventDefault();
        closeTab(activeTab);
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
      uploader.xhr?.abort();
    } catch (_) {}
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
  // 文件拖到终端/编辑器等区域时，浏览器默认会导航离开页面。
  document.addEventListener("dragover", (ev) => {
    if (ev.dataTransfer && Array.from(ev.dataTransfer.types).includes("Files")) ev.preventDefault();
  });
  document.addEventListener("drop", (ev) => {
    if (ev.dataTransfer && Array.from(ev.dataTransfer.types).includes("Files")) ev.preventDefault();
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

  // 窗口尺寸统一在 boot 里的一个 rAF 处理器中处理，避免拖动时重复布局。
  if (document.fonts && document.fonts.ready) {
    document.fonts.ready.then(() => {
      panes.forEach(fitPane);
      layoutTabs();
    });
  }
  document.addEventListener("visibilitychange", () => {
    if (!document.hidden) {
      panes.forEach((p) => {
        fitPane(p);
        flushOutput(p);
      });
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

