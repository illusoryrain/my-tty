#!/usr/bin/env node
// HTTP 请求边界回归：残余 body 不能被当成下一个请求；未登录的慢 body 必须立即关闭。
// 用法: node http_guard_test.mjs <http-base> <password>

import net from "node:net";

const base = process.argv[2];
if (!base) {
  console.error("usage: node http_guard_test.mjs <http-base>");
  process.exit(2);
}
const url = new URL(base);
const port = Number(url.port || 80);
const host = url.host;
const password = process.argv[3];

function exchange(raw, { waitMs = 1200, stopAfterHead = false, halfClose = false } = {}) {
  return new Promise((resolve, reject) => {
    const sock = net.createConnection({ host: "127.0.0.1", port });
    let out = Buffer.alloc(0);
    let done = false;
    const timer = setTimeout(finish, waitMs);
    function finish(err) {
      if (done) return;
      done = true;
      clearTimeout(timer);
      sock.destroy();
      if (err) reject(err);
      else resolve(out.toString("latin1"));
    }
    sock.on("data", (chunk) => {
      out = Buffer.concat([out, chunk]);
      if (stopAfterHead && out.includes("\r\n\r\n")) finish();
    });
    sock.on("close", () => finish());
    sock.on("error", (err) => finish(err));
    if (halfClose) sock.end(raw);
    else sock.write(raw);
  });
}

const head = (method, path, extra = "") =>
  `${method} ${path} HTTP/1.1\r\nHost: ${host}\r\n${extra}\r\n`;
const statuses = (out) => out.match(/HTTP\/1\.1 \d{3}/g) || [];
const assert = (c, m) => { if (!c) throw new Error("ASSERT: " + m); };

// 1) 超过 4 KiB 的登录 body 里藏第二个请求：只能返回一个响应并关闭连接。
const smuggled = "GET /api/auth/status HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n";
const body = "A".repeat(4097) + smuggled + "B".repeat(128);
const login =
  head("POST", "/api/auth/login", `Content-Type: application/json\r\nContent-Length: ${body.length}\r\n`) +
  body;
const loginOut = await exchange(login);
assert(statuses(loginOut).length === 1, "oversized login body must not be parsed as a second request");
assert(!loginOut.includes("401"), "smuggled request must not be answered");
assert(/connection: close/i.test(loginOut), "oversized login body must close the connection");

// 1b) chunked 登录 body 超限时同样不能把残余字节当成新请求。
const chunkPayload = "A".repeat(8192) + smuggled;
const chunkedBody = `${chunkPayload.length.toString(16)}\r\n${chunkPayload}\r\n0\r\n\r\n`;
const chunkedOut = await exchange(
  head("POST", "/api/auth/login", "Transfer-Encoding: chunked\r\n") + chunkedBody
);
assert(statuses(chunkedOut).length === 1, "chunked login body must not be parsed as a second request");
assert(!chunkedOut.includes("401"), "chunked smuggled request must not be answered");
assert(/connection: close/i.test(chunkedOut), "chunked login body must close the connection");

// 1c) 登录 body 在 Content-Length 之前断开：不能当成有效 JSON 继续处理。
const truncatedLogin =
  head("POST", "/api/auth/login", `Content-Type: application/json\r\nContent-Length: 64\r\n`) +
  `{"password":"short`;
const truncatedOut = await exchange(truncatedLogin, { halfClose: true });
assert(/HTTP\/1\.1 400/.test(truncatedOut), "truncated login body is rejected");
assert(/connection: close/i.test(truncatedOut), "truncated login body closes");

// 2) 未登录 API + 永远不发的 body：必须立即 401/close，而不是等待 body。
const t0 = Date.now();
const unauthOut = await exchange(
  head("PUT", "/api/fs/upload?path=x", "Content-Length: 100000000\r\n"),
  { waitMs: 1500, stopAfterHead: true }
);
assert(Date.now() - t0 < 1000, "unauthenticated slow body must not block");
assert(/HTTP\/1\.1 401/.test(unauthOut), "unauthenticated API still returns 401");
assert(/connection: close/i.test(unauthOut), "unauthenticated API must close");

// 3) 静态路径不接受请求体。
const staticOut = await exchange(head("GET", "/", "Content-Length: 100000000\r\n"));
assert(/HTTP\/1\.1 400/.test(staticOut), "static path with body is rejected");
assert(/connection: close/i.test(staticOut), "static path with body closes");

// 4) 正常流水线请求仍然复用连接。
const okOut = await exchange(
  head("GET", "/") + head("GET", "/app.js", "Connection: close\r\n")
);
assert(statuses(okOut).length === 2, "clean keep-alive requests are still served");

// 5) 已认证但被截断的 body 也不能让服务端 abort；写接口不能落半截文件。
if (password) {
  const login = await fetch(`${base}/api/auth/login`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ password }),
  });
  if (!login.ok) throw new Error("authenticated guard login failed: " + login.status);
  const cookie = login.headers.getSetCookie()[0].split(";")[0];
  const withCookie = (method, path, extra = "") =>
    head(method, path, `Cookie: ${cookie}\r\n${extra}`);

  const statusOut = await exchange(withCookie("GET", "/api/auth/status", "Content-Length: 5\r\n"));
  assert(/HTTP\/1\.1 400/.test(statusOut), "authenticated truncated body is rejected");
  assert(/connection: close/i.test(statusOut), "authenticated truncated body closes");

  // 用一个唯一的 /tmp 路径，避免写进 /；被截断的请求不应留下任何文件。
  const stamp = `mytty-guard-${process.pid}-${Date.now()}`;
  const writePath = `tmp/${stamp}.txt`;
  const uploadPath = `tmp/${stamp}.bin`;

  const writeOut = await exchange(
    withCookie("PUT", `/api/fs/write?path=${writePath}`, "Content-Length: 5\r\n"),
    { halfClose: true }
  );
  assert(/HTTP\/1\.1 400/.test(writeOut), "truncated write is rejected");
  assert(/connection: close/i.test(writeOut), "truncated write closes");

  const uploadOut = await exchange(
    withCookie("PUT", `/api/fs/upload?path=${uploadPath}`, "Content-Length: 5\r\n"),
    { halfClose: true }
  );
  assert(/HTTP\/1\.1 400/.test(uploadOut), "truncated upload is rejected");
  assert(/connection: close/i.test(uploadOut), "truncated upload closes");

  for (const path of [writePath, uploadPath]) {
    const res = await fetch(`${base}/api/fs/read?path=${path}`, { headers: { cookie } });
    assert(res.status === 404, `truncated request must not create ${path}`);
    await fetch(`${base}/api/fs/delete?path=${path}`, { method: "DELETE", headers: { cookie } });
  }

  // 非法百分号编码不能被当成空路径去列根目录；超长路径也不能变成 500。
  const badList = await exchange(withCookie("GET", "/api/fs/list?path=%zz"));
  assert(/HTTP\/1\.1 400/.test(badList), "malformed path must be 400");
  assert(/invalid_query/.test(badList), "malformed path error code");
  const longPath = "a".repeat(3000);
  const longOut = await exchange(withCookie("GET", `/api/fs/list?path=${longPath}`));
  assert(/HTTP\/1\.1 400/.test(longOut), "overlong path must be 400");
  assert(/path_too_long/.test(longOut), "overlong path error code");

  // 非法的 base 不能绕过并发修改检查。
  const guardPath = `tmp/mytty-guard-${process.pid}-${Date.now()}`;
  const put = async (value) => exchange(
    withCookie("PUT", `/api/fs/write?path=${guardPath}`,
      `Content-Type: text/plain\r\nContent-Length: ${value.length}\r\n`) + value
  );
  assert(/HTTP\/1\.1 200/.test(await put("old")), "guard setup write");
  const first = await fetch(`${base}/api/fs/read?path=${guardPath}`, { headers: { cookie } });
  const version = (await first.json()).version;
  assert(typeof version === "string" && version.length === 16, "guard version");
  assert(/HTTP\/1\.1 200/.test(await put("changed")), "guard external write");
  const badBase = await exchange(
    withCookie("PUT", `/api/fs/write?path=${guardPath}&base=%zz`,
      "Content-Type: text/plain\r\nContent-Length: 3\r\n") + "bad"
  );
  assert(/HTTP\/1\.1 400/.test(badBase), "malformed base must be 400");
  assert(/invalid_query/.test(badBase), "malformed base error code");
  const after = await fetch(`${base}/api/fs/read?path=${guardPath}`, { headers: { cookie } });
  assert((await after.json()).content === "changed", "malformed base must not overwrite");
  await fetch(`${base}/api/fs/delete?path=${guardPath}`, { method: "DELETE", headers: { cookie } });
}

console.log("http guard: PASS");
