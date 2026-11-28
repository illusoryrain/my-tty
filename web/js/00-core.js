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
  /// 正在加载的目录 -> 该次加载的 Promise；同一目录被同时点开时只发一个请求，
  /// 并且调用方（例如 applyDir）能等它真正结束再判断成功与否。
  const treeLoads = new Map();
  let treeRootError = false;
  let cwdSyncEnabled = store.get("myttty.cwdSync") !== "0";
  // 终端内悬浮状态栏的位置（0..1，按可移动空间归一化），所有分屏共用。
  let paneBarPos = (() => {
    try {
      const v = JSON.parse(store.get("myttty.paneBar") || "null");
      if (!v || !Number.isFinite(v.x) || !Number.isFinite(v.y)) return { x: 1, y: 0 };
      return { x: Math.min(1, Math.max(0, v.x)), y: Math.min(1, Math.max(0, v.y)) };
    } catch (_) {
      return { x: 1, y: 0 };
    }
  })();
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

