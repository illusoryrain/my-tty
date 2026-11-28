
  function baseName(path) {
    const i = path.lastIndexOf("/");
    return i === -1 ? path : path.slice(i + 1);
  }

  function buildEditorTab(tab, path) {
    tab.el.classList.add("editor-workspace");
    const el = document.createElement("section");
    el.className = "editor-tab";
    el.innerHTML = `
      <header class="editor-toolbar">
        <span class="editor-path"></span>
        <span class="editor-state">加载中…</span>
        <span class="spacer"></span>
        <button class="icon editor-save" type="button" title="保存 (Ctrl+S)" aria-label="保存"><svg class="ico" viewBox="0 0 16 16" aria-hidden="true"><path d="M3 2.5h7l3 3v8H3z"/><path d="M5.5 2.5v3.5h5V2.5"/><path d="M5 9.5h6"/></svg></button>
      </header>
      <div class="editor-body">
        <pre class="editor-gutter" aria-hidden="true"></pre>
        <textarea class="editor-text" wrap="off" spellcheck="false" autocomplete="off" autocapitalize="off" readonly></textarea>
      </div>`;
    tab.el.appendChild(el);

    const pathEl = el.querySelector(".editor-path");
    const stateEl = el.querySelector(".editor-state");
    const textarea = el.querySelector(".editor-text");
    const gutter = el.querySelector(".editor-gutter");
    const saveBtn = el.querySelector(".editor-save");
    pathEl.textContent = path;
    pathEl.title = path;

    const ed = {
      path,
      name: baseName(path),
      pathEl,
      version: "",
      eol: "\n",
      dirty: false,
      loaded: false,
      saving: false,
      queued: false,
      textarea,
      gutter,
      stateEl,
      saveBtn,
      lineCount: 0,
      gutterQueued: false,
    };
    tab.editor = ed;
    tab.label.textContent = ed.name;
    tab.label.title = path;

    textarea.addEventListener("input", () => {
      if (!ed.loaded) return;
      ed.dirty = true;
      setEditorState(tab, "未保存的修改");
      scheduleEditorGutter(tab);
    });
    textarea.addEventListener("scroll", () => {
      gutter.scrollTop = textarea.scrollTop;
    });
    textarea.addEventListener("keydown", (ev) => {
      if ((ev.ctrlKey || ev.metaKey) && ev.key.toLowerCase() === "s") {
        ev.preventDefault();
        saveEditor(tab);
        return;
      }
      if (ev.key === "Escape") {
        ev.preventDefault();
        ev.stopPropagation();
        closeTab(tab);
        return;
      }
      if (ev.key === "Tab") {
        ev.preventDefault();
        const start = textarea.selectionStart;
        const end = textarea.selectionEnd;
        textarea.setRangeText("  ", start, end, "end");
        textarea.dispatchEvent(new Event("input"));
      }
    });
    saveBtn.addEventListener("click", () => saveEditor(tab));
    return ed;
  }

  function setEditorState(tab, text) {
    const ed = tab.editor;
    if (!ed) return;
    ed.stateEl.textContent = text;
    tab.btn.classList.toggle("dirty", ed.dirty);
    if (tab === activeTab) updateSummary();
  }

  async function openEditor(path) {
    const existing = tabs.find((t) => t.kind === "editor" && t.editor && t.editor.path === path);
    if (existing) {
      activateTab(existing);
      requestAnimationFrame(() => existing.editor.textarea.focus());
      return;
    }

    const tab = addTab("editor");
    if (!tab) {
      notice("标签页已达上限", true);
      return;
    }
    const ed = buildEditorTab(tab, path);
    activateTab(tab);
    if (window.matchMedia("(max-width: 820px)").matches) {
      filesEl.hidden = true;
      filesResizeEl.hidden = true;
    }

    let data;
    try {
      data = await api("GET", "read", { path });
    } catch (err) {
      if (!tabs.includes(tab)) return;
      notice(`打开失败: ${err.message}`, true);
      await closeTab(tab);
      return;
    }
    if (!tabs.includes(tab) || tab.editor !== ed) return;

    // version 是服务端给的内容哈希；保存时带回去，文件在此期间被改过就会被拒绝。
    ed.version = data.version || "";
    const raw = data.content;
    ed.eol = raw.includes("\r\n") ? "\r\n" : raw.includes("\r") && !raw.includes("\n") ? "\r" : "\n";
    ed.textarea.value = ed.eol === "\n" ? raw : raw.replace(/\r\n?/g, "\n");
    ed.textarea.readOnly = false;
    ed.loaded = true;
    setEditorState(tab, `${data.size} 字节 · 未修改`);
    updateEditorGutter(tab);
    if (tab === activeTab) {
      ed.textarea.focus();
      ed.textarea.setSelectionRange(0, 0);
    }
  }

  async function saveEditor(tab, force = false) {
    const ed = tab && tab.editor;
    if (!ed || !ed.loaded) return;
    if (ed.saving) {
      ed.queued = true;
      return;
    }
    if (!ed.dirty && !force) {
      notice("没有修改");
      return;
    }

    ed.saving = true;
    ed.saveBtn.disabled = true;
    let retryForce = false;
    const query = { path: ed.path };
    if (!force && ed.version) query.base = ed.version;
    const normalized = ed.textarea.value;
    const text = ed.eol === "\n" ? normalized : normalized.replace(/\n/g, ed.eol);

    try {
      const res = await api("PUT", "write", query, text);
      if (tab.editor !== ed || !tabs.includes(tab)) return;
      ed.version = res.version || "";
      ed.dirty = ed.textarea.value !== normalized;
      setEditorState(tab, ed.dirty ? "未保存的修改" : `${res.size} 字节 · 已保存`);
      notice(`已保存 ${ed.path}`);
      refreshFiles([parentOf(ed.path)]);
    } catch (err) {
      if (tab.editor !== ed || !tabs.includes(tab)) return;
      if (err.code === "metadata_unsafe") {
        setEditorState(tab, "文件元数据无法安全保留");
        notice("该文件有硬链接，或属主/扩展属性无法保留，编辑器不能安全覆盖", true);
        return;
      }
      if (err.code === "modified_on_disk") {
        setEditorState(tab, "文件已在别处被修改");
        retryForce = await askConfirm(
          "文件已在别处被修改",
          `${ed.path} 在打开之后被其他程序改过（或已被删除）。覆盖会丢掉那些修改。`,
          "仍然覆盖",
          true
        );
        if (!retryForce) ed.textarea.focus();
      } else {
        setEditorState(tab, `保存失败: ${err.message}`);
        notice(`保存失败: ${err.message}`, true);
      }
    } finally {
      ed.saving = false;
      ed.saveBtn.disabled = false;
      if (tab.editor === ed && tabs.includes(tab)) {
        if (retryForce) saveEditor(tab, true);
        else if (ed.queued) {
          ed.queued = false;
          saveEditor(tab);
        }
      }
    }
  }

