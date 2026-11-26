单文件 Web 终端：一个静态链接的 Zig 二进制，内置 PTY、多标签/分屏、密码登录、文件管理器和内嵌前端，不需要 Node、数据库或反向代理。

## 本次更新（v0.1.1）

**修复**

- 手机软键盘每个字符只发一次：兼容 keyup 早于 input、input 非 composed 等事件顺序，`l` 不再变成 `ll`。
- Enter 不再重复发送：keydown 已经发出回车时，紧随其后的 keypress 被压掉。
- 编辑器保存冲突：文件在打开后被外部修改或删除时返回 `409 modified_on_disk`，不再静默覆盖；权限、目录等真实错误不再误报成“文件已被修改”。
- 自动重连竞态：等待 ticket 期间遇到 `online` 或页面回到前台，不会再为同一分屏建出第二条 WebSocket/PTY。
- 测试稳定性：修掉 smoke 的 SIGPIPE 偶发失败和编辑器浏览器测试的偶发竞态。

**改进**

- 静态资源引用带内容哈希（`?v=…`），命中当前版本时以 `immutable` 强缓存一年；页面本身仍是 `no-cache` + ETag，打开页面不再逐个发 304。
- 终端输出在 xterm 解析期间合并写入，单批最多 256 KiB，刷屏开销更低。
- 编辑器行号按帧合并，行数不变不重建 DOM；保存请求未返回时继续输入仍标记为未保存。
- 网络恢复或页面回到前台立即重连，不再等完最长 30 秒退避。
- localStorage 不可用时页面仍能启动；分屏拖动只在松手时写一次；删除、丢弃修改、覆盖冲突改用应用内确认框。
- 预加载终端字体；触屏设备隐藏快捷键提示；复用 TextEncoder。

**测试**

- 新增 `editor` 浏览器测试：保存冲突流程、应用内确认、存储禁用启动、批量输出、偏好持久化。
- 新增 `mobile_input` 浏览器测试：多种手机输入事件顺序、纯 input、touch、退格/回车只发一次。
- smoke 增加版本化资源缓存头和写冲突 409 检查。

## 下载

| 文件 | 平台 |
|---|---|
| `my-tty-@VERSION@-x86_64-linux.tar.gz` | x86_64 Linux |
| `my-tty-@VERSION@-aarch64-linux.tar.gz` | ARM64 / aarch64 Linux |
| `SHA256SUMS` | 全部资产的校验和 |

每个包里是静态链接的 `my-tty`、中英文 README、`my-tty.example.json` 和 `deploy/my-tty.service`，无运行时依赖。

## 运行

```bash
tar xzf my-tty-@VERSION@-x86_64-linux.tar.gz   # ARM64 换成 aarch64 包名
cd my-tty-@VERSION@-x86_64
./my-tty --host 127.0.0.1 --port 7387 --password '换成你的密码'
```

浏览器打开 `http://127.0.0.1:7387`。自身不处理 TLS，对外部署请放在本机反向代理后面。`deploy/my-tty.service` 是 systemd 示例，配置项和默认值见 `my-tty.example.json` 与 README。

## 功能

- **会话持久**：PTY 由服务端持有，刷新页面或断网重连都回到同一个 shell；输出环形缓冲从 64 KiB 按需增长到 512 KiB，断线期间不丢尾部。
- **多标签 / 分屏**：xterm.js + WebSocket，支持搜索、剪贴板、字体缩放和移动端按键栏；20 秒心跳与自动重连，接管同一会话时有明确提示。
- **文件管理**：树状浏览（只渲染视口附近的行，几千项的目录也流畅）、分片上传与断点偏移续传、下载、在线编辑、目录 tar 下载。
- **登录与边界**：密码登录，HttpOnly cookie，默认 7 天过期 / 24 小时空闲过期；同源检查、连接数上限、未认证请求日志按来源 IP 限速、慢上传整体时限。
- **传输**：前端资源编译期内嵌、启动时预压缩，ETag + `no-cache`（命中回 304）；大于 1 KiB 的 JSON 响应按需 gzip。
- **构建**：CI 用 Zig 0.17.1 在 x86_64 和 ARM64 原生 runner 上编译并剥离符号，二进制在各自架构上直接启动检查。

## 校验

```bash
sha256sum -c SHA256SUMS
```

## 许可证

本项目以 MIT 许可证发布。包内 `LICENSE` 是项目许可证，`licenses/` 是内嵌的
xterm.js（MIT）和 JetBrains Mono（OFL 1.1）的完整文本。

---

Static single-binary web terminal for Linux (x86_64, aarch64): PTY sessions survive reloads, tabs/panes, password auth, file manager, embedded gzip assets. No Node, database, or reverse proxy required. Built with Zig 0.17.1; see README.en.md.

v0.1.1 fixes duplicated mobile keyboard input, double-sent Enter, editor save conflicts, and reconnect races. Static assets now use content-hashed URLs with immutable caching, terminal output is batched, and large-file gutter work is deferred.
