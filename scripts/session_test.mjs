#!/usr/bin/env node
// 会话保持冒烟：断线重连回同一个 shell、offset 增量回放、close 结束会话。
// 用法: node session_test.mjs <http-base> <password>

const base = process.argv[2];
const password = process.argv[3];
if (!base || !password) {
  console.error("usage: node session_test.mjs <http-base> <password>");
  process.exit(2);
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const login = await fetch(`${base}/api/auth/login`, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ password }),
});
if (!login.ok) {
  console.error("login failed:", login.status);
  process.exit(1);
}
const cookie = (
  (login.headers.getSetCookie && login.headers.getSetCookie()[0]) ||
  login.headers.get("set-cookie") ||
  ""
).split(";")[0];

async function ticket() {
  const r = await fetch(`${base}/api/auth/ticket`, { method: "POST", headers: { cookie } });
  if (!r.ok) throw new Error("ticket failed: " + r.status);
  return (await r.json()).ticket;
}

async function connect(session, offset) {
  const t = await ticket();
  let url = `${base.replace(/^http/, "ws")}/ws?ticket=${encodeURIComponent(t)}&offset=${offset}`;
  if (session) url += `&session=${session}`;
  const ws = new WebSocket(url);
  ws.binaryType = "arraybuffer";
  const conn = { ws, session: "", offset, out: "", closed: false };
  ws.onmessage = (e) => {
    if (typeof e.data === "string") {
      const m = JSON.parse(e.data);
      if (m.t === "ready") {
        conn.session = m.session;
        conn.offset = m.offset;
      }
    } else {
      conn.offset += e.data.byteLength;
      conn.out += new TextDecoder().decode(e.data);
    }
  };
  ws.onclose = () => { conn.closed = true; };
  await new Promise((res, rej) => {
    ws.onopen = res;
    ws.onerror = () => rej(new Error("websocket error"));
  });
  for (let i = 0; i < 100 && !conn.session; i++) await sleep(20);
  if (!conn.session) throw new Error("no ready frame");
  return conn;
}

const send = (conn, text) => conn.ws.send(new TextEncoder().encode(text));
const plain = (s) => s.replace(/\x1b\[[0-9;?]*[A-Za-z]/g, "");

const a = await connect(null, 0);
// 用拼接构造标记，避免命中的是 shell 回显的命令行本身。
send(a, "export MYTTY_KEEP=ALIVE; printf 'FIRST_%s\\n' MARK\r");
for (let i = 0; i < 100 && !plain(a.out).includes("FIRST_MARK"); i++) await sleep(20);
if (!plain(a.out).includes("FIRST_MARK")) throw new Error("first session produced no output");
const sid = a.session;
const off = a.offset;
a.ws.close();
await sleep(300);

const b = await connect(sid, off);
await sleep(200);
if (b.session !== sid) throw new Error("session id changed on resume");
if (plain(b.out).includes("FIRST_MARK")) throw new Error("replayed already-seen output");
send(b, "echo K=$MYTTY_KEEP\r");
for (let i = 0; i < 100 && !plain(b.out).includes("K=ALIVE"); i++) await sleep(20);
if (!plain(b.out).includes("K=ALIVE")) throw new Error("shell state lost after resume");

// {t:"close"}（文本帧）应立即结束会话
const off2 = b.offset;
b.ws.send(JSON.stringify({ t: "close" }));
for (let i = 0; i < 100 && !b.closed; i++) await sleep(20);
if (!b.closed) throw new Error("server did not close after {t:close}");

const c = await connect(sid, off2);
if (c.session === sid) throw new Error("close did not destroy the session");
c.ws.send(JSON.stringify({ t: "close" }));
c.ws.close();

// 注销必须让已经建立的终端立即断开；注销前签发、还没用的票据也不能再开新终端。
const t1 = await ticket();
const t2 = await ticket();
const live = new WebSocket(`${base.replace(/^http/, "ws")}/ws?ticket=${encodeURIComponent(t1)}`);
let liveClosed = false;
live.addEventListener("close", () => { liveClosed = true; });
await new Promise((res, rej) => {
  live.addEventListener("open", res, { once: true });
  live.addEventListener("error", () => rej(new Error("logout websocket failed to open")), { once: true });
});
await sleep(200);
const logout = await fetch(`${base}/api/auth/logout`, { method: "POST", headers: { cookie } });
if (logout.status !== 200) throw new Error("logout failed: " + logout.status);
for (let i = 0; i < 100 && !liveClosed; i++) await sleep(20);
if (!liveClosed) throw new Error("existing websocket stayed open after logout");

const stale = new WebSocket(`${base.replace(/^http/, "ws")}/ws?ticket=${encodeURIComponent(t2)}`);
const staleOpened = await new Promise((res) => {
  const timer = setTimeout(() => res(true), 1500);
  stale.addEventListener("open", () => { clearTimeout(timer); res(true); }, { once: true });
  stale.addEventListener("error", () => { clearTimeout(timer); res(false); }, { once: true });
  stale.addEventListener("close", () => { clearTimeout(timer); res(false); }, { once: true });
});
try { stale.close(); } catch {}
if (staleOpened) throw new Error("ticket issued before logout still opened a terminal");
const status = await fetch(`${base}/api/auth/status`, { headers: { cookie } });
if (status.status !== 401) throw new Error("session still active after logout: " + status.status);

console.log("session smoke: PASS");
process.exit(0);
