# my-tty

[简体中文](README.md)

A single-binary web terminal: Zig serves HTTP/WebSocket and drives a Linux PTY;
the browser renders the terminal with xterm.js's **DOM renderer**. Static assets
are embedded at build time, so there is no Node/npm at runtime.

Status:

| Feature | Status |
|---|---|
| Login (modal / 7-day session / idle timeout / logout) | ✅ |
| Connection limit, Origin checks, graceful shutdown | ✅ |
| WebSocket ⇄ Linux PTY, real shell | ✅ |
| Built-in session persistence (refresh/automatic reconnect to the same shell, incremental replay) | ✅ |
| Multiple tabs, each with independent 1–4 panes and draggable splitters | ✅ |
| Font size adjustment | ✅ |
| Terminal search / links / mobile key bar | ✅ |
| File manager, text editor, chunked/resumable upload / download / directory tar | ✅ |
| Config file / environment / command-line precedence | ✅ |

## Build and run

```sh
zig build                    # Debug: debug info, large; local debugging only
zig test src/tests.zig
./zig-out/bin/my-tty --port 7387 --password 'change-me'
# open http://127.0.0.1:7387/ and enter the password in the dialog

./scripts/build-release.sh                # release: ReleaseSafe + strip, ~1.4 MiB
./scripts/build-release.sh aarch64-linux  # cross-compile for ARM64
```

`build-release.sh` is equivalent to `zig build -Doptimize=safe -Dstrip=true` and
takes an optional Zig target (`aarch64-linux`, `arm-linux-musleabihf`, ...), so
the host `strip` does not need to understand the target format. Deploy the
stripped binary; do not install the Debug build (tens of MiB).

Official releases are built by GitHub Actions on `v*` tags: static x86_64 and
aarch64 binaries, each compiled on a native runner of that architecture and
launched once (`--check-config`), then published automatically. CI passes an
explicit `-Dtarget` so the binaries use the architecture's baseline CPU, not the
runner's instruction set. There is no 32-bit ARM runner; use the cross-compile
target above if you need one.

Frontend assets are embedded at compile time, pre-compressed to gzip at startup
(about 730 KiB -> 218 KiB overall; the font is already compressed), and tagged with a per-process ETag.
References to scripts, stylesheets, and the font inside the page carry a content
hash (`/app.js?v=…`); those URLs are cached for a year as `immutable`, so opening
the page no longer revalidates every file, and any content change changes the
URL. The page itself and unversioned URLs still revalidate with `no-cache`, get
a 304 on a hit, and automatically pick up new files after a restart. JSON API responses above 1 KiB are gzipped on demand as
well (big directory listings and text file reads benefit most) and fall back to
plain text when the client does not accept it.

If `--password` is omitted, a random password is generated and printed to the
terminal; it changes on restart.

Choose a shell:

```sh
./zig-out/bin/my-tty --shell /bin/zsh --password 'change-me'
```

The shell inside the terminal is a **login shell**: its home directory and identity
come from the running user's `/etc/passwd`, not just `$HOME`. That means startup via
systemd, `rc.local`, or cron (where `HOME` may be missing) and `sudo`/`su` (where a
foreign `HOME` may linger) still start in the correct home directory. Like an SSH
login it loads `/etc/profile`, `~/.profile` (or the zsh equivalents), and
`/etc/environment`, so `PATH`, `EDITOR`, and similar variables are present;
`--shell` is also exported as `$SHELL`. An explicitly set, accessible `$HOME` still
takes precedence, which keeps temporary directories and tests working.

## Configuration

Precedence: **defaults < config file < environment < command line**.
Reads `./my-tty.json` by default (skipped if missing).

```json
{
  "host": "127.0.0.1",
  "port": 7387,
  "shell": "/bin/bash",
  "password": "please-change-me",
  "session_ttl_days": 7,
  "session_idle_hours": 24,
  "max_connections": 64,
  "max_sessions": 16,
  "pty_idle_minutes": 30
}
```

Environment variables: `MYTTY_CONFIG`, `MYTTY_HOST`, `MYTTY_PORT`, `MYTTY_SHELL`,
`MYTTY_PASSWORD`, `MYTTY_SESSION_TTL_DAYS`, `MYTTY_SESSION_IDLE_HOURS`,
`MYTTY_MAX_CONNECTIONS`, `MYTTY_MAX_SESSIONS`, `MYTTY_PTY_IDLE_MINUTES`.
See `my-tty --help` for all options; the repo includes `my-tty.example.json`.
`my-tty --check-config` validates the config and exits without starting the server.

## As a systemd service

The repo ships `deploy/my-tty.service`. It is a plain systemd unit: the single
binary runs directly; no Docker, no container, no runtime dependencies.

The unit's `User=my-tty`, `Group=my-tty`, and `WorkingDirectory=/srv/work`
require that user, group, and directory to exist. Create them before enabling
the service:

```sh
./scripts/build-release.sh              # build ReleaseSafe + strip first
sudo install -Dm755 zig-out/bin/my-tty /usr/local/bin/my-tty
sudo useradd --system --user-group --create-home --home-dir /srv/work --shell /bin/bash my-tty
sudo install -d -o my-tty -g my-tty -m 750 /srv/work
sudo install -d -o root -g my-tty -m 750 /etc/my-tty
sudo install -m640 -o root -g my-tty my-tty.example.json /etc/my-tty/my-tty.json
sudoedit /etc/my-tty/my-tty.json        # at least change password / shell
sudo install -Dm644 deploy/my-tty.service /etc/systemd/system/my-tty.service
sudo systemctl daemon-reload
sudo systemctl enable --now my-tty
journalctl -u my-tty -f
```

- Keep the password in `/etc/my-tty/my-tty.json` (`0640 root:my-tty`), never in
  `ExecStart`, where it would appear in `ps` and the journal.
- The service runs as the dedicated `my-tty` user with home `/srv/work`;
  everything the terminal can do is bounded by that user. `WorkingDirectory`
  is only the process cwd; the shell starts in the home directory from
  `/etc/passwd` for that user (not from `$HOME`), and the file panel starts at `/`.
- `--check-config` runs before startup; a bad config fails the service instead
  of running with it.
- Listens on `127.0.0.1` by default; for remote access use an SSH tunnel or an
  external reverse proxy. TLS is out of scope.
- On stop, `KillMode=mixed` sends SIGTERM only to the main process, which reaps
  all PTYs itself.

### Running as root (optional)

If the machine is yours alone and you want the terminal to be root directly
(no sudo), you can skip the dedicated user:

```sh
sudo install -d -m 700 /etc/my-tty
sudo install -m 600 my-tty.example.json /etc/my-tty/my-tty.json
sudoedit /etc/my-tty/my-tty.json        # at least change password / shell
```

Change `User=my-tty` to `User=root` in the unit and remove `Group=` and
`WorkingDirectory=` (or make sure `/srv/work` exists):

```ini
[Service]
Type=simple
User=root
ExecStartPre=/usr/local/bin/my-tty --config /etc/my-tty/my-tty.json --check-config
ExecStart=/usr/local/bin/my-tty --config /etc/my-tty/my-tty.json
```

The PTY and file API then run as root, equivalent to logging in over SSH as
root. Do not keep `User=my-tty` without creating that user, and do not enable
`ProtectSystem`/`PrivateTmp`-style sandboxing in root mode, since it would
restrict normal terminal work.

## Authentication

- A login dialog appears first; until you log in, terminals, the file API, and
  WebSockets are all rejected.
- The password lives only in the server config; the browser gets a random
  session cookie: `HttpOnly; SameSite=Strict; Path=/`, with `Secure` added
  automatically when a reverse proxy terminates HTTPS.
- Sessions last **7 days** by default (`--session-ttl-days`, 1–365); the idle
  timeout defaults to 24 hours (`--session-idle-hours`, 0 disables it). While the
  page is open it re-checks `/api/auth/status` every 5 minutes to keep the
  session alive: terminal keystrokes travel over the WebSocket and do not count
  as HTTP requests, so without this heartbeat a page left open without reloading
  would eventually hit the idle timeout.
- A transient network failure (phone just unlocked, Wi-Fi reassociating) no
  longer shows the password dialog: the page retries quietly and enters on its
  own once the network is back. Only an explicit 401 from the server asks for the
  password again.
- "Logout" (left icon rail on desktop / top bar on mobile) clears both the
  server-side session and the cookie; all terminals close.
- Sessions are in-memory: after a server restart you must log in again.
  One-time WS tickets expire after 30 seconds. Terminal sessions are in-memory
  too; shells do not survive a server restart.
- Concurrent connections are capped at 64 by default.

## File manager and editor

The left "Files" panel starts at `/` and can browse the whole filesystem. Drag
the splitter to resize it; double-click the splitter to restore the default
width. The setting is stored in the browser. Directories are shown as a tree:
click a directory name to select and expand it, click the triangle to
collapse/expand. Only the rows near the viewport are rendered, so directories
with thousands of entries stay smooth. New files and uploads go to the currently selected directory;
the breadcrumb at the top jumps directly to any level. When you `cd` in the
terminal or run `pwd`, the panel follows the shell's cwd.
The directory-follow toggle next to Refresh is on by default; turn it off and
the tree stops following the terminal, turn it back on and it realigns
immediately. The state is stored in the browser.
Supports creating files/directories, rename, recursive delete, upload/download,
and plain-text editing (≤1 MiB, `Ctrl+S` to save). New file/directory/rename use
an in-page dialog rather than the native `prompt`.
Upload by clicking ⇪, dragging into the panel, or dropping onto a directory row;
files are sent in 4 MiB chunks with progress and cancel, and an interrupted
upload resumes by asking the server for the committed offset. Single-file limit
64 MiB.
In-progress upload temp files are `0600`; after the final rename the file becomes
`0644`.
Downloads stream with `Content-Disposition: attachment`; directories download as
`.tar`.
A single listing returns at most 10,000 entries (the UI notes truncation);
directory archives cap at 50,000 entries / 8 GiB, then stop and write
`MY-TTY-TRUNCATED.txt` instead of producing a corrupt tar.
All path parameters are relative to `/`; absolute paths and `..` are rejected;
symlinks are not restricted.
HTTP API: `GET /api/fs/list|read|download`, `PUT /api/fs/write|upload`,
`POST /api/fs/mkdir|rename`, `DELETE /api/fs/delete`.
`read` returns a content hash `version`; when `write` is given `base=<version>`
and the file has been changed or deleted in the meantime, it answers
`409 {"error":"modified_on_disk"}` without writing (the editor then asks whether
to overwrite). Without `base` it overwrites as before.

## Panes

`+ Pane` adds up to 4: with 2 panes the width is split evenly; with 3 the left
pane spans the full height and the right side is split vertically with a
draggable splitter; with 4 it is a 2×2 grid, both splitters draggable. Each pane
has its own terminal, WebSocket, and PTY; closing a pane reaps its shell.
`Ctrl+Shift+F` searches, `Ctrl+Shift+±` adjusts font size, `F3` jumps to the next
match. On mobile an Esc/Tab/Ctrl/arrow/^C/^D/^L key bar is shown; on desktop the
top bar becomes a narrow 44px icon rail on the left; mobile keeps the top bar
and the bottom key bar and reserves the bottom safe area. On touch devices,
download/rename/delete buttons on file rows are always visible. Pane headers are
fixed above the terminal instead of floating over the content.

## Tabs

The tab bar sits at the top of the terminal area. `＋` adds a tab (max 8), click
a tab to switch, `✕` on the right closes it. `＋` follows the last tab; when the
width runs out, the oldest tabs collapse into a `⋯` menu on the left, while the
active tab stays visible. Each tab has its own 1–4 panes, split ratios, and
active pane; switching tabs does not disconnect background tabs' WebSockets or
lose output. Closing a tab ends all shells it contains.

The tab list and each pane's session id are kept in `sessionStorage`: reloading
restores the tabs and reattaches to the same shells. After a server restart the
tabs remain but get new shells. The total pane count is limited by the server's
`max_sessions` (default 16).

Copy/paste follows terminal semantics:

- `Ctrl+C`: copies when there is a selection, otherwise sends SIGINT to the
  shell. Copying clears the selection, so the next `Ctrl+C` interrupts.
- `Ctrl+V`, `Ctrl+Shift+V`, `Shift+Insert`: paste via the browser's native paste
  event (xterm handles bracketed paste); no clipboard read permission needed.
- `Ctrl+Insert`, `Ctrl+Shift+C`: always copy; the latter also calls
  `preventDefault` so Chrome/Edge DevTools' "inspect element" shortcut does not
  steal it (DevTools still opens from the menu).
- Only Ctrl is bound; on macOS, `Cmd+C`/`Cmd+V` go through xterm's native
  copy/paste events and the frontend no longer checks `metaKey`.
- The `^C` button on the desktop icon rail sends `0x03` to the active pane, for
  RDP/remote-desktop setups that swallow Ctrl or when you do not want the
  keyboard. On mobile only the bottom key bar keeps a `^C`; the top-bar one is
  hidden.

## Session persistence

No tmux/screen needed: the server keeps each pane's PTY and a ring buffer that
starts at 64 KiB and grows to 512 KiB as output accumulates.

- Reloading the page or reconnecting after a network drop attaches back to the
  **same shell**; environment variables, cwd, and running programs are
  preserved. The server replays only the bytes the client missed.
- The WebSocket carries an application-level heartbeat every 20 seconds. Half-open
  connections caused by a locked phone, a Wi-Fi drop, or a sleeping laptop are
  detected and **reconnected automatically**, with no need to click the status
  bar. Background tabs pause the heartbeat so browser throttling is not mistaken
  for a dead connection.
- When another window takes over the same session, the old window receives close
  code 4001 and shows "taken over by another window"; it does not auto-reconnect
  and fight for the session. Click the status bar to take it back.
- TCP keepalive is enabled (probe after 60 seconds idle, dead peer detected in
  about 2 minutes), so a client that disappears without a FIN does not leave a
  connection hanging on the server forever.
- Replay never calls `reset()` or recreates the Terminal, so scroll position and
  text selection survive; copy/paste keeps working after an in-page reconnect.
- After a disconnect the shell is kept for `--pty-idle-minutes` (default 30,
  0 = reap immediately); closing the pane button or logging out ends the shell
  immediately.
- Sessions are memory-only; a server restart drops them all (reconnecting gets a
  new shell).
- At most `max_sessions` sessions are kept; when the limit is hit, exited and
  least-recently-active idle sessions are evicted first.

## Logs

Logs go to **stderr** and land in the journal under systemd. Only key events are
logged:

- startup, exit, `accept` failures;
- login success/failure (source IP only, never the password);
- unauthenticated API/WebSocket requests (path, source IP, whether a cookie was
  sent);
- logout;
- WebSocket connect/disconnect;
- session create/reap (first 8 chars of the session id and the shell pid);
- file write, upload, mkdir, rename, delete (path and byte count only).

No HTTP access log; static asset requests produce nothing, and tickets/sessions
in query strings never reach the log. The "unauthenticated" line distinguishes a
real 401 from a plain network failure: it only appears when the server actually
rejected the request, and it is limited to one line per source IP per second so
anonymous requests cannot flood the journal. Behind a local reverse proxy the
source IP is logged as `127.0.0.1` (`X-Forwarded-For` is not read).

## Security model

- Listens on `127.0.0.1` by default; except for the login endpoint, **every
  `/api/*` and WebSocket requires a valid session**, otherwise 401.
- Constant-time password comparison.
- Request headers that take longer than 30 seconds are closed by the server
  (slowloris); large uploads/downloads and WebSockets are exempt. File writes and
  uploads get an overall limit of "32 KiB/s + 2 minutes", so a trickling body
  cannot pin a connection and a temp file forever.
- WebSocket requests with an `Origin` must match `Host`; one-time tickets are
  consumed on use, even when a cookie is also present.
- All non-GET/HEAD requests with an `Origin` must match `Host` / a trusted
  `X-Forwarded-Host`, otherwise 403. A reverse proxy must preserve the original
  `Host` or set `X-Forwarded-Host`, or writes will be rejected.
- Responses for requests whose body was not fully read close the connection, so
  leftover body bytes cannot be parsed as the next request.
- `X-Forwarded-Host` / `X-Forwarded-Proto` are trusted only when the peer is
  loopback (a local reverse proxy); a direct client forging them cannot change
  Origin checks or the cookie's `Secure` flag.
- Static assets/unknown paths do not accept request bodies; unauthenticated API
  requests do not drain a body just to keep the connection alive.
- `SIGTERM`/`SIGINT` stop accept, reap all PTYs, then exit.
- Sessions are capped by `max_sessions`; panes are capped at 4.

TLS is out of scope: bind to loopback and terminate plaintext HTTP/WS at an
external reverse proxy. This project contains no certificates, TLS code, or
reverse-proxy config.

## Frontend dependencies

`web/vendor/xterm/` contains build artifacts of `@xterm/xterm@6.0.0`,
`@xterm/addon-fit@0.11.0`, `@xterm/addon-search@0.16.0`, and
`@xterm/addon-web-links@0.12.0` (MIT, licenses alongside). xterm 6 uses the DOM
renderer by default, so text can be selected/copied natively; no WebGL/Canvas
addon is included.

The frontend patches one xterm 6.0 input issue: Safari and some IMEs (e.g., the
English mode of a Chinese IME) deliver a character's `input` event before its
`keydown`; xterm's `_keyDownSeen` dedup then drops the character as a duplicate.
Mobile browsers also send an extra composed `insertText` after keydown already
emitted the character, and clearing the flag unconditionally doubles characters
(`ls` → `llss`).

Current rule: on touch devices (`pointer: coarse`), printable characters go only
through the browser `input` path, never through xterm's keydown/keypress first;
desktop fine pointers keep the original keyboard path. `_keyDownSeen` is cleared
only when keydown produced no character (229/Process, composition,
Ctrl/Alt/Meta); normal keys stay deduped by xterm. Normal desktop Chrome/Safari
typing emits no `input` events, so behavior is unchanged.

To debug input, add `?debug-input=1` to the URL; the page logs raw
`keydown`/`keypress`/`beforeinput`/`input` fields.

`web/vendor/fonts/` bundles JetBrains Mono v2.304 (OFL 1.1). The DOM renderer
draws box/block characters with the font; system fonts (e.g., DejaVu) leave gaps
in `█` and borders, so the bundled font is loaded before the terminal is
created, keeping TUI borders and blocks continuous.

## Verification

```sh
zig test src/tests.zig        # config, auth/sessions, PTY env, protocol, file paths
./scripts/smoke.sh            # real process: auth, files/chunks/archive, WS+PTY, graceful shutdown
./scripts/browser_test.sh     # browser regression (npm --prefix tests/browser ci + chromium first)
./scripts/build-release.sh    # ReleaseSafe + strip, ~1.4 MiB
```

CI lives in `.github/workflows/ci.yml`: format check, build, unit tests, smoke,
and a separate browser job.

## License

Released under the MIT License; see [LICENSE](LICENSE). The embedded xterm.js
(MIT) and JetBrains Mono font (OFL 1.1) notices are in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md); release archives also ship the
full texts in their `licenses/` directory.
