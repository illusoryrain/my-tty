  // ------------------------------------------------------------- 编辑辅助

  // 大文件（上限 1 MiB，可能几万行）每按一个键都重建行号会明显卡顿：
  // 输入事件按帧合并，行数没变就不动 DOM。
  function countLines(value) {
    let count = 1;
    let i = -1;
    while ((i = value.indexOf("\n", i + 1)) !== -1) count += 1;
    if (value.endsWith("\n")) count -= 1;
    return Math.max(1, count);
  }

  function updateEditorGutter(tab) {
    const ed = tab && tab.editor;
    if (!ed) return;
    const count = countLines(ed.textarea.value);
    if (count !== ed.lineCount) {
      ed.lineCount = count;
      const lines = new Array(count);
      for (let i = 0; i < count; i++) lines[i] = i + 1;
      ed.gutter.textContent = lines.join("\n") + "\n";
    }
    ed.gutter.scrollTop = ed.textarea.scrollTop;
  }

  function scheduleEditorGutter(tab) {
    const ed = tab && tab.editor;
    if (!ed || ed.gutterQueued) return;
    ed.gutterQueued = true;
    requestAnimationFrame(() => {
      ed.gutterQueued = false;
      if (tab.editor === ed) updateEditorGutter(tab);
    });
  }

  window.addEventListener("beforeunload", (ev) => {
    if (tabs.some((t) => t.kind === "editor" && t.editor && t.editor.dirty)) {
      ev.preventDefault();
      ev.returnValue = "";
    }
  });

