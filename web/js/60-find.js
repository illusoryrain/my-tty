
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

