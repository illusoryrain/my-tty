
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

  function addTab(kind = "terminal") {
    if (tabs.length >= MAX_TABS) return null;

    const el = document.createElement("div");
    el.className = "tab-workspace";
    if (kind === "editor") el.classList.add("editor-workspace");
    el.hidden = true;
    workspace.appendChild(el);

    const btn = document.createElement("div");
    btn.className = "tab";
    btn.setAttribute("role", "tab");
    btn.setAttribute("aria-selected", "false");

    const label = document.createElement("button");
    label.type = "button";
    label.className = "tab-label";
    if (kind === "terminal") label.textContent = `终端 ${++tabSeq}`;

    const close = document.createElement("button");
    close.type = "button";
    close.className = "tab-close";
    close.title = "关闭标签页";
    close.appendChild(iconNode("delete"));

    btn.appendChild(label);
    btn.appendChild(close);
    tabListEl.appendChild(btn);

    const tab = {
      kind,
      el,
      btn,
      label,
      panes: [],
      activePane: null,
      splitX: 0.5,
      splitY: 0.5,
      editor: null,
    };
    tabs.push(tab);

    btn.addEventListener("click", () => activateTab(tab));
    close.addEventListener("click", async (ev) => {
      ev.stopPropagation();
      await closeTab(tab);
    });

    updateTabHint();
    layoutTabs();
    return tab;
  }

  function newTab() {
    const tab = addTab("terminal");
    if (!tab) return;
    activateTab(tab);
    createPane("", tab);
  }

  function focusActive() {
    if (!activeTab) return;
    if (activeTab.kind === "editor" && activeTab.editor) activeTab.editor.textarea.focus();
    else if (activePane) activePane.term.focus();
  }

  function activateTab(tab) {
    if (!tab) return;
    if (tab === activeTab) {
      focusActive();
      return;
    }

    if (activeTab) {
      if (activeTab.kind === "terminal") {
        activeTab.splitX = splitX;
        activeTab.splitY = splitY;
        activeTab.activePane = activePane;
        if (activePane) activePane.term.blur();
      } else if (activeTab.editor) {
        activeTab.editor.textarea.blur();
      }
      activeTab.el.hidden = true;
      activeTab.btn.classList.remove("active");
      activeTab.btn.setAttribute("aria-selected", "false");
    }

    activeTab = tab;
    if (tab.kind === "terminal") {
      panes = tab.panes;
      splitX = tab.splitX;
      splitY = tab.splitY;
      activePane =
        tab.activePane && tab.panes.includes(tab.activePane)
          ? tab.activePane
          : tab.panes[tab.panes.length - 1] || null;
    } else {
      panes = [];
      activePane = null;
    }

    tab.el.hidden = false;
    tab.btn.classList.add("active");
    tab.btn.setAttribute("aria-selected", "true");
    for (const p of panes) p.el.classList.toggle("active", p === activePane);

    layout(tab);
    layoutTabs();
    updateSummary();
    saveSessions();
    if (tab.kind === "terminal") {
      if (cwdSyncEnabled && activePane && activePane.cwd) syncFilesToCwd(activePane.cwd);
      requestAnimationFrame(() => {
        for (const p of tab.panes) {
          fitPane(p);
          flushOutput(p);
        }
        if (activePane && !coarsePointer) activePane.term.focus();
      });
    } else if (tab.editor) {
      requestAnimationFrame(() => {
        updateEditorGutter(tab);
        tab.editor.textarea.focus();
      });
    }
  }

  async function closeTab(tab) {
    if (!tab || tab.closing) return;
    tab.closing = true;
    if (!tabs.includes(tab)) return;
    if (tab.kind === "editor" && tab.editor && tab.editor.dirty) {
      const ok = await askConfirm(
        "放弃未保存的修改？",
        `${tab.editor.path} 有未保存的修改，关闭后会丢失。`,
        "放弃并关闭",
        true
      );
      if (!ok) {
        tab.closing = false;
        if (tab === activeTab && tab.editor) tab.editor.textarea.focus();
        else focusActive();
        return;
      }
    }
    const idx = tabs.indexOf(tab);
    if (idx === -1) return;

    if (tab.kind === "terminal") {
      for (const pane of [...tab.panes]) removePane(pane, false);
    }
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
    if (activeTab) focusActive();
  }

