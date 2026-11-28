//! 前端静态资源的编译期入口。
//!
//! 单独做成一个 module，是因为 Zig 只允许 `@embedFile` 读取模块根目录内的文件；
//! 根模块在 `src/` 下，直接写 `../web/...` 会被拒绝。
//!
//! JS/CSS 按功能拆在 `js/`、`css/` 下，这里按文件名顺序拼接成一个运行时文件。
//! 拼接保持原有顺序和单一作用域，不引入打包器，也不改变 `/app.js`、`/style.css`
//! 这两个对外 URL。

pub const index_html = @embedFile("index.html");
pub const app_js =
    @embedFile("js/00-core.js") ++
    @embedFile("js/10-tabs.js") ++
    @embedFile("js/20-terminal.js") ++
    @embedFile("js/30-files.js") ++
    @embedFile("js/40-editor.js") ++
    @embedFile("js/50-boot.js") ++
    @embedFile("js/60-find.js") ++
    @embedFile("js/70-clipboard.js") ++
    @embedFile("js/80-keys.js") ++
    @embedFile("js/90-gutter.js") ++
    @embedFile("js/99-auth.js");
pub const style_css =
    @embedFile("css/00-base.css") ++
    @embedFile("css/10-files.css") ++
    @embedFile("css/20-panes.css") ++
    @embedFile("css/30-editor.css") ++
    @embedFile("css/40-dialogs.css") ++
    @embedFile("css/50-find-keys.css") ++
    @embedFile("css/60-progress.css") ++
    @embedFile("css/70-splitters.css") ++
    @embedFile("css/90-mobile.css");
pub const xterm_css = @embedFile("vendor/xterm/xterm.css");
pub const xterm_js = @embedFile("vendor/xterm/xterm.js");
pub const addon_fit_js = @embedFile("vendor/xterm/addon-fit.js");
pub const addon_search_js = @embedFile("vendor/xterm/addon-search.js");
pub const addon_web_links_js = @embedFile("vendor/xterm/addon-web-links.js");
pub const jetbrains_mono_woff2 = @embedFile("vendor/fonts/JetBrainsMono-Regular.woff2");
