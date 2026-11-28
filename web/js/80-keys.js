
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

