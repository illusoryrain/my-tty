#!/usr/bin/env bash
# 浏览器回归：需要先在 tests/browser 里 npm ci 并安装 chromium。
set -euo pipefail
cd "$(dirname "$0")/.."

PORT="${PORT:-17389}"
PASSWORD="browser-$(date +%s)"
ROOT="$(mktemp -d)"
LOG="$(mktemp)"
PID=""

cleanup() {
  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
  rm -rf "$ROOT" "$LOG"
}
trap cleanup EXIT

if [ ! -d tests/browser/node_modules ]; then
  echo "缺少 tests/browser/node_modules，请先执行：npm --prefix tests/browser ci" >&2
  exit 2
fi

zig build -Doptimize=safe
HOME="$ROOT" ./zig-out/bin/my-tty --port "$PORT" --password "$PASSWORD" >"$LOG" 2>&1 &
PID=$!

for _ in $(seq 1 50); do
  curl -fsS "http://127.0.0.1:$PORT/" >/dev/null 2>&1 && break
  sleep 0.1
done

export BASE="http://127.0.0.1:$PORT"
export PASSWORD ROOT

failures=0

run_test() {
  local name="$1"
  local output
  if output=$(node "tests/browser/$name.cjs" 2>&1); then
    printf '%s\n' "$output"
    return 0
  fi
  printf '%s\n' "$output"
  # 把失败测试名和最后一行错误写进 GitHub annotation：公开 API 也能看到，
  # 不必登录下载 Actions 日志。
  local msg
  msg=$(printf '%s\n' "$output" | tr -d '\r' | awk 'NF { line = $0 } END { print line }' | sed 's/%/%25/g')
  echo "::error title=browser:$name::$msg"
  # 不在第一个失败处退出：一次跑完，避免一个失败掩盖后面的失败。
  failures=$((failures + 1))
  return 0
}

run_test ui
run_test tabs
run_test features
run_test mobile_input
run_test clipboard
run_test session
run_test files
run_test cwd

if [ "$failures" -ne 0 ]; then
  echo "browser tests: $failures failed" >&2
  exit 1
fi

echo "browser tests: ALL PASS"
