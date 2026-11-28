#!/usr/bin/env bash
# 端到端冒烟：真实二进制 + 真实登录 + 真实 PTY + 真实 WebSocket。
# 任何一个检查失败，脚本都会非零退出（set -e + pipefail）。
set -euo pipefail

cd "$(dirname "$0")/.."

PORT="${PORT:-17387}"
PASSWORD="smoke-pass-$(date +%s)"
BIN="./zig-out/bin/my-tty"
ROOT="$(mktemp -d)"
REL="${ROOT#/}"
LOG="$(mktemp)"
COOKIE_JAR="$(mktemp)"
UPLOAD_SRC="$(mktemp)"
UPLOAD_DST="$(mktemp)"
CHUNK_SRC="$(mktemp)"
TAR_FILE="$(mktemp)"
CONFIG="$(mktemp)"
echo '{}' >"$CONFIG"
PID=""
BASE="http://127.0.0.1:$PORT"
API="$BASE/api/fs"

cleanup() {
  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
  rm -rf "$ROOT" "$LOG" "$COOKIE_JAR" "$UPLOAD_SRC" "$UPLOAD_DST" "$CHUNK_SRC" "$TAR_FILE" "$CONFIG"
}
trap cleanup EXIT

pass() { echo "$1: PASS"; }

zig build

if curl -fsS "http://127.0.0.1:$PORT/" >/dev/null 2>&1; then
  echo "端口 $PORT 已被占用，请换一个 PORT" >&2
  exit 2
fi
"$BIN" --config "$CONFIG" --host 127.0.0.1 --port "$PORT" --password "$PASSWORD" >"$LOG" 2>&1 &
PID=$!

echo "== index =="
# 第一个真实请求自带连接重试，不单独发就绪探测请求。
curl -fsS --retry 50 --retry-connrefused --retry-delay 1 "$BASE/" | grep -c 'id="workspace"' >/dev/null
pass index

echo "== embedded vendor =="
curl -fsS "$BASE/vendor/xterm/xterm.js" -o /dev/null
pass xterm.js

echo "== check-config =="
"$BIN" --check-config 2>&1 | grep -c '配置检查通过' >/dev/null
pass check-config

echo "== security headers =="
curl -fsSI "$BASE/" | grep -ci 'x-content-type-options: nosniff' >/dev/null
pass headers

echo "== gzip and cache =="
cmp <(curl -fsS "$BASE/app.js") <(curl -fsS --compressed "$BASE/app.js")
curl -fsSI -H 'Accept-Encoding: gzip' "$BASE/app.js" | grep -qi '^content-encoding: gzip'
ETAG=$(curl -fsSI "$BASE/app.js" | tr -d '\r' | awk 'tolower($1)=="etag:" {print $2}')
[ -n "$ETAG" ]
[ "$(curl -sS -o /dev/null -w '%{http_code}' -H "If-None-Match: $ETAG" "$BASE/app.js")" = "304" ]
pass "gzip + etag"

# 页面里的子资源引用带内容版本号；带当前版本号的请求可以强缓存，裸 URL 仍是 no-cache。
# 先把整个响应读进变量，避免 curl 写管道时 head/grep -q 提前退出触发 SIGPIPE。
INDEX_HTML=$(curl -fsS "$BASE/")
APP_URL=$(printf '%s\n' "$INDEX_HTML" | grep -o '/app\.js?v=[0-9a-f]\{16\}' | sed -n '1p')
[ -n "$APP_URL" ]
curl -fsSI "$BASE$APP_URL" | tr -d '\r' | grep -qi '^cache-control: public, max-age=31536000, immutable$'
curl -fsSI "$BASE/app.js?v=0000000000000000" | tr -d '\r' | grep -qi '^cache-control: no-cache$'
curl -fsSI "$BASE/app.js" | tr -d '\r' | grep -qi '^cache-control: no-cache$'
STYLE_CSS=$(curl -fsS "$BASE/style.css")
FONT_URL=$(printf '%s\n' "$STYLE_CSS" | grep -o '/vendor/fonts/JetBrainsMono-Regular\.woff2?v=[0-9a-f]\{16\}' | sed -n '1p')
[ -n "$FONT_URL" ]
printf '%s\n' "$INDEX_HTML" | grep -F "href=\"$FONT_URL\"" >/dev/null
pass "versioned asset urls"

echo "== auth =="
for path in "/api/fs/list?path=" "/api/fs/download?path=x" "/api/fs/upload?path=x" "/api/auth/status" "/api/auth/ticket" "/api/auth/logout"; do
  code=$(curl -sS -o /dev/null -w '%{http_code}' -X GET "$BASE$path")
  [ "$code" = "401" ]
done
pass "all APIs except login require auth"

curl -fsS -c "$COOKIE_JAR" -H 'content-type: application/json' \
  -d "{\"password\":\"$PASSWORD\"}" "$BASE/api/auth/login" | grep -c '"ok":true' >/dev/null
pass login

code=$(curl -sS -o /dev/null -w '%{http_code}' -H 'content-type: application/json' \
  -d '{"password":"wrong"}' "$BASE/api/auth/login")
[ "$code" = "401" ]
pass "wrong password rejected"

echo "== csrf origin =="
code=$(curl -sS -o /dev/null -w '%{http_code}' -b "$COOKIE_JAR" \
  -H 'Origin: https://evil.example' -X POST "$API/mkdir?path=$REL/csrf-test")
[ "$code" = "403" ]
pass "cross-origin mutation rejected"

curl -fsS -b "$COOKIE_JAR" -H "Origin: $BASE" -X POST "$API/mkdir?path=$REL/origin-ok" | grep -c '"ok":true' >/dev/null
curl -fsS -b "$COOKIE_JAR" -X DELETE "$API/delete?path=$REL/origin-ok" >/dev/null
pass "same-origin mutation allowed"

echo "== fs api =="
curl -fsS -b "$COOKIE_JAR" "$API/list?path=$REL" | grep -c '"entries"' >/dev/null
pass list

curl -fsS -X PUT -b "$COOKIE_JAR" --data-binary 'smoke content' "$API/write?path=$REL/note.txt" | grep -c '"ok":true' >/dev/null
pass write

curl -fsS -b "$COOKIE_JAR" "$API/read?path=$REL/note.txt" | grep -c 'smoke content' >/dev/null
pass read

# 编辑器冲突检测：带着打开时的 version 保存，文件期间被改过就返回 409。
VERSION=$(curl -fsS -b "$COOKIE_JAR" "$API/read?path=$REL/note.txt" | grep -o '"version":"[0-9a-f]*"' | cut -d'"' -f4)
[ -n "$VERSION" ]
printf 'changed elsewhere' >"$ROOT/note.txt"
[ "$(curl -sS -o /dev/null -w '%{http_code}' -X PUT -b "$COOKIE_JAR" --data-binary 'stale' \
  "$API/write?path=$REL/note.txt&base=$VERSION")" = "409" ]
[ "$(cat "$ROOT/note.txt")" = "changed elsewhere" ]
VERSION=$(curl -fsS -b "$COOKIE_JAR" "$API/read?path=$REL/note.txt" | grep -o '"version":"[0-9a-f]*"' | cut -d'"' -f4)
curl -fsS -X PUT -b "$COOKIE_JAR" --data-binary 'smoke content' \
  "$API/write?path=$REL/note.txt&base=$VERSION" | grep -c '"ok":true' >/dev/null
pass "write conflict"

echo "== destructive write guards =="
printf 'keep' >"$ROOT/keep.txt"
code=$(curl -sS -o /dev/null -w '%{http_code}' -X PUT -b "$COOKIE_JAR" --data-binary 'new' \
  "$API/write?path=$REL/keep.txt&exclusive=1")
[ "$code" = "409" ]
[ "$(cat "$ROOT/keep.txt")" = "keep" ]
pass "exclusive create refuses existing file"

printf 'a' >"$ROOT/a.txt"
printf 'b' >"$ROOT/b.txt"
code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST -b "$COOKIE_JAR" \
  "$API/rename?from=$REL/a.txt&to=$REL/b.txt")
[ "$code" = "409" ]
[ "$(cat "$ROOT/b.txt")" = "b" ]
[ -f "$ROOT/a.txt" ]
pass "rename does not overwrite existing target"

# 覆盖一个非空目录必须返回 409，而不是把用户操作错误报成 500。
mkdir -p "$ROOT/ren-src" "$ROOT/ren-dst"
printf 'x' >"$ROOT/ren-src/x.txt"
printf 'y' >"$ROOT/ren-dst/y.txt"
code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST -b "$COOKIE_JAR" \
  "$API/rename?from=$REL/ren-src&to=$REL/ren-dst&overwrite=1")
[ "$code" = "409" ]
[ "$(cat "$ROOT/ren-src/x.txt")" = "x" ]
[ "$(cat "$ROOT/ren-dst/y.txt")" = "y" ]
pass "rename over non-empty directory reports conflict"
rm -rf "$ROOT/ren-src" "$ROOT/ren-dst"

# FIFO/设备节点不能让服务端卡在 open()，也不能被原子替换成普通文件。
mkfifo "$ROOT/fifo"
for endpoint in write upload; do
  code=$(timeout 5 curl -sS -o /dev/null -w '%{http_code}' -X PUT -b "$COOKIE_JAR" \
    --data-binary 'new' "$API/$endpoint?path=$REL/fifo")
  [ "$code" = "400" ]
  [ -p "$ROOT/fifo" ]
done
mkdir "$ROOT/write-dir"
for endpoint in write upload; do
  code=$(timeout 5 curl -sS -o /dev/null -w '%{http_code}' -X PUT -b "$COOKIE_JAR" \
    --data-binary 'new' "$API/$endpoint?path=$REL/write-dir")
  [ "$code" = "400" ]
  [ -d "$ROOT/write-dir" ]
done
pass "write/upload reject FIFO and directory targets"

printf 'old' >"$ROOT/hard.txt"
ln "$ROOT/hard.txt" "$ROOT/hard-link.txt"
code=$(curl -sS -o /dev/null -w '%{http_code}' -X PUT -b "$COOKIE_JAR" --data-binary 'new' \
  "$API/write?path=$REL/hard.txt")
[ "$code" = "409" ]
[ "$(cat "$ROOT/hard.txt")" = "old" ]
pass "hardlinked file is not atomically replaced"
rm -f "$ROOT/hard-link.txt"

# 长路径 + 大于 1 KiB 的写响应：body 读完后不能再碰 header。
LONG=$(printf 'd%.0s' $(seq 1 240))
LONGPATH="$REL/$LONG/$LONG/$LONG/$LONG"
curl -fsS -X POST -b "$COOKIE_JAR" "$API/mkdir?path=$LONGPATH" >/dev/null
curl -fsS -X PUT -b "$COOKIE_JAR" --data-binary 'long' "$API/write?path=$LONGPATH/probe.txt" \
  | grep -c '"ok":true' >/dev/null
pass "long path write does not abort server"

# 大 JSON（文本文件读取、大目录列表）应压缩；解压后必须和明文完全一致。
head -c 4096 /dev/zero | tr '\0' 'a' >"$UPLOAD_SRC"
curl -fsS -X PUT -b "$COOKIE_JAR" --data-binary @"$UPLOAD_SRC" "$API/write?path=$REL/gzip.txt" >/dev/null
cmp <(curl -fsS -b "$COOKIE_JAR" "$API/read?path=$REL/gzip.txt") \
  <(curl -fsS --compressed -b "$COOKIE_JAR" "$API/read?path=$REL/gzip.txt")
curl -sS -D - -o /dev/null -H 'Accept-Encoding: gzip' -b "$COOKIE_JAR" \
  "$API/read?path=$REL/gzip.txt" | grep -qi '^content-encoding: gzip'
curl -fsS -X DELETE -b "$COOKIE_JAR" "$API/delete?path=$REL/gzip.txt" >/dev/null
pass "json gzip"

echo "== fs hardening =="
printf 'mode' > "$ROOT/mode.txt"
chmod 600 "$ROOT/mode.txt"
curl -fsS -X PUT -b "$COOKIE_JAR" --data-binary 'mode2' "$API/write?path=$REL/mode.txt" >/dev/null
[ "$(stat -c%a "$ROOT/mode.txt")" = "600" ]
pass "write preserves permissions"

mkdir "$ROOT/victimdir"
ln -s victimdir "$ROOT/dirlink"
curl -fsS -X DELETE -b "$COOKIE_JAR" "$API/delete?path=$REL/dirlink" >/dev/null
[ ! -L "$ROOT/dirlink" ] && [ -d "$ROOT/victimdir" ]
pass "delete removes link, not target"

printf 'target' > "$ROOT/target.txt"
ln -s target.txt "$ROOT/link.txt"
curl -fsS -X POST -b "$COOKIE_JAR" "$API/rename?from=$REL/link.txt&to=$REL/link2.txt" >/dev/null
[ -L "$ROOT/link2.txt" ] && [ ! -e "$ROOT/link.txt" ] && [ "$(cat "$ROOT/target.txt")" = "target" ]
pass "rename moves link, not target"

yes a | head -c 1048576 > "$ROOT/exact.bin" || true
curl -fsS -b "$COOKIE_JAR" "$API/read?path=$REL/exact.bin" | grep -c '"size":1048576' >/dev/null
pass "1 MiB read"

printf '\xff\xfeA' > "$ROOT/latin1.txt"
code=$(curl -sS -o /dev/null -w '%{http_code}' -b "$COOKIE_JAR" "$API/read?path=$REL/latin1.txt")
[ "$code" = "415" ]
pass "non-UTF8 read rejected"

curl -fsS -X POST -b "$COOKIE_JAR" "$API/mkdir?path=$REL/a/b" | grep -c '"ok":true' >/dev/null
pass mkdir

# 对已存在的目录再次 mkdir 必须正常返回，不能因为路径切片越界把进程打崩。
curl -fsS -X POST -b "$COOKIE_JAR" "$API/mkdir?path=$REL/a/b" | grep -c '"ok":true' >/dev/null
pass "mkdir existing target"

curl -fsS -X POST -b "$COOKIE_JAR" "$API/rename?from=$REL/note.txt&to=$REL/a/note.txt" | grep -c '"ok":true' >/dev/null
pass rename

code=$(curl -sS -o /dev/null -w '%{http_code}' -b "$COOKIE_JAR" "$API/read?path=../etc/passwd")
[ "$code" = "400" ]
pass "traversal blocked"

curl -fsS -X DELETE -b "$COOKIE_JAR" "$API/delete?path=$REL/a" | grep -c '"ok":true' >/dev/null
pass delete

printf 'UPLOAD_CONTENT_123' > "$UPLOAD_SRC"
curl -fsS -X PUT -b "$COOKIE_JAR" --data-binary @"$UPLOAD_SRC" "$API/upload?path=$REL/up.bin" | grep -c '"ok":true' >/dev/null
pass upload
curl -fsS -b "$COOKIE_JAR" "$API/download?path=$REL/up.bin" -o "$UPLOAD_DST"
cmp -s "$UPLOAD_SRC" "$UPLOAD_DST"
pass "download round-trip"
curl -sS -D - -o /dev/null -b "$COOKIE_JAR" "$API/download?path=$REL/up.bin" | grep -ci 'content-disposition: attachment' >/dev/null
pass "download headers"
curl -fsS -X DELETE -b "$COOKIE_JAR" "$API/delete?path=$REL/up.bin" | grep -c '"ok":true' >/dev/null
pass "cleanup upload"

echo "== large upload =="
dd if=/dev/zero of="$CHUNK_SRC" bs=1024 count=3000 2>/dev/null
printf 'old' > "$ROOT/chunk.bin"
chmod 600 "$ROOT/chunk.bin"
curl -fsS -X PUT -b "$COOKIE_JAR" --data-binary @"$CHUNK_SRC" \
  "$API/upload?path=$REL/chunk.bin" >/dev/null
cmp -s "$CHUNK_SRC" "$ROOT/chunk.bin"
[ "$(stat -c%a "$ROOT/chunk.bin")" = "600" ]
pass "upload preserves permissions"
curl -fsS -X DELETE -b "$COOKIE_JAR" "$API/delete?path=$REL/chunk.bin" >/dev/null

# 上传中的临时文件必须是 0600，不能提前露出最终文件内容或宽权限。
mkdir "$ROOT/stage"
printf 'old' >"$ROOT/stage/target"
chmod 644 "$ROOT/stage/target"
dd if=/dev/zero of="$UPLOAD_SRC" bs=1024 count=128 2>/dev/null
curl -fsS --limit-rate 64k --max-time 30 -X PUT -b "$COOKIE_JAR" \
  --data-binary @"$UPLOAD_SRC" "$API/upload?path=$REL/stage/target" >/dev/null &
CURL_PID=$!
TEMP=""
for _ in $(seq 1 100); do
  TEMP=$(find "$ROOT/stage" -maxdepth 1 -type f ! -name target -print -quit)
  [ -n "$TEMP" ] && break
  sleep 0.02
done
[ -n "$TEMP" ]
[ "$(stat -c%a "$TEMP")" = "600" ]
wait "$CURL_PID"
cmp -s "$UPLOAD_SRC" "$ROOT/stage/target"
[ "$(stat -c%a "$ROOT/stage/target")" = "644" ]
pass "in-progress upload temp is 0600 and restores target mode"

echo "== archive =="
curl -fsS -X POST -b "$COOKIE_JAR" "$API/mkdir?path=$REL/tardir" >/dev/null
printf 'ARCHIVE_FILE' | curl -fsS -X PUT -b "$COOKIE_JAR" --data-binary @- "$API/upload?path=$REL/tardir/a.txt" >/dev/null
curl -fsS -b "$COOKIE_JAR" "$API/archive?path=$REL/tardir" -o "$TAR_FILE"
tar -tf "$TAR_FILE" | grep -c 'tardir/a.txt' >/dev/null
pass archive
curl -fsS -X DELETE -b "$COOKIE_JAR" "$API/delete?path=$REL/tardir" >/dev/null

echo "== origin check =="
code=$(curl -sS -o /dev/null -w '%{http_code}' -b "$COOKIE_JAR" \
  -H 'Origin: https://evil.example' \
  -H 'Upgrade: websocket' -H 'Connection: Upgrade' \
  -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' -H 'Sec-WebSocket-Version: 13' \
  "$BASE/ws?ticket=deadbeef")
[ "$code" = "403" ]
pass "cross-origin websocket rejected"

echo "== websocket + pty =="
node scripts/ws_test.mjs "$BASE" "$PASSWORD" "MYTTY_RESULT_OK" "Linux" "/dev/pts/"
pass "websocket + pty"

echo "== session resume =="
node scripts/session_test.mjs "$BASE" "$PASSWORD"
pass "session resume"

echo "== http body boundaries =="
node scripts/http_guard_test.mjs "$BASE" "$PASSWORD"
pass "http body boundaries"

echo "== logout =="
curl -fsS -b "$COOKIE_JAR" -c "$COOKIE_JAR" -X POST "$BASE/api/auth/logout" >/dev/null
code=$(curl -sS -o /dev/null -w '%{http_code}' -b "$COOKIE_JAR" "$API/list?path=")
[ "$code" = "401" ]
pass "logout invalidates session"

echo "== graceful shutdown =="
kill -TERM "$PID"
wait "$PID" 2>/dev/null || true
PID=""
grep -c '已退出' "$LOG" >/dev/null
pass "graceful shutdown"

echo
echo "全部通过（服务端日志见下方）"
sed -n '1,20p' "$LOG"
