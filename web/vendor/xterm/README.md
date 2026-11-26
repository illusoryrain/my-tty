# 前端第三方依赖

这些文件是从 npm 包中原样拷出的 **构建产物**，构建 `my-tty` 时不需要 Node/npm。

| 文件 | 来源 | 版本 | 许可证 |
|---|---|---|---|
| `xterm.js` / `xterm.css` | `@xterm/xterm` | 6.0.0 | MIT（见 `LICENSE`） |
| `addon-fit.js` | `@xterm/addon-fit` | 0.11.0 | MIT（见 `LICENSE.addon-fit`） |
| `addon-search.js` | `@xterm/addon-search` | 0.16.0 | MIT（见 `LICENSE.addon-search`） |
| `addon-web-links.js` | `@xterm/addon-web-links` | 0.12.0 | MIT（见 `LICENSE.addon-web-links`） |

## 为什么只需要这几个

- xterm 6 的默认渲染器就是 **DOM renderer**（`CoreBrowserTerminal._createRenderer()` 直接
  实例化 `DomRenderer`），不需要、也不引入 WebGL/Canvas addon。
  DOM 渲染保留浏览器原生文本选择，复制粘贴符合直觉。
- `addon-fit` 只负责根据容器尺寸计算行列数，与渲染方式无关。
- `addon-search` 提供查找；因为 decorations 属于 proposed API，前端只用它做选择/滚动，不开启装饰。
- `addon-web-links` 把终端里的 URL 变成可点击链接（纯 DOM 覆盖层）。

## 升级方式

```sh
npm pack @xterm/xterm@6.0.0 @xterm/addon-fit@0.11.0
tar xzf xterm-6.0.0.tgz
cp package/lib/xterm.js package/css/xterm.css package/LICENSE web/vendor/xterm/
tar xzf xterm-addon-fit-0.11.0.tgz
cp package/lib/addon-fit.js package/LICENSE web/vendor/xterm/LICENSE.addon-fit
# addon-search@0.16.0 / addon-web-links@0.12.0 同理：
# cp package/lib/addon-search.js package/LICENSE web/vendor/xterm/LICENSE.addon-search
# cp package/lib/addon-web-links.js package/LICENSE web/vendor/xterm/LICENSE.addon-web-links
```

升级后跑 `zig test src/tests.zig` 和 `scripts/smoke.sh`，并在浏览器里确认选择/复制仍然可用。

**注意私有字段**：`web/app.js` 的输入法/移动端去重直接读写 xterm 内部的
`term._core._keyDownSeen` 和 `term._core._keyDownHandled`。它们不是公开 API，升级后可能
改名或语义变化而不报错。升级时务必跑 `scripts/browser_test.sh`：其中
`tests/browser/features.cjs` 覆盖了 “input 补发字符” 和 “移动端重复输入（ls → llss）” 两条回归。
