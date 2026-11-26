//! 内嵌静态资源。
//!
//! 所有前端文件在编译期用 `@embedFile` 打进二进制，运行时不读磁盘、不依赖
//! Node/npm。第三方 xterm.js 的版本与许可证见 `web/vendor/xterm/`。
//!
//! 启动时把可压缩的资源预压成 gzip（约 730 KiB → 218 KiB），并生成一个本进程
//! 唯一的 ETag：浏览器用 `no-cache` 每次校验，重启后 ETag 变化，不会拿旧文件。
//!
//! 子资源（脚本、样式、字体）还会按内容算一个版本号，并把 HTML/CSS 里对它们的
//! 引用改写成 `/app.js?v=<hash>`。带着当前版本号的请求可以长期强缓存
//! （immutable），打开页面时不再为每个文件发一次 304 校验；内容变了 URL 就变。

const std = @import("std");
const util = @import("util.zig");
const web = @import("web_assets");

pub const Asset = struct {
    path: []const u8,
    mime: []const u8,
    body: []const u8,
    /// 资源只随二进制变化，用 no-cache + ETag 让浏览器每次校验、命中回 304。
    cache_control: []const u8 = "no-cache",
    /// 启动时预压缩的 gzip 副本；null 表示按明文发送（太小或压缩失败）。
    gzip: ?[]const u8 = null,
    /// 内容版本号（16 位十六进制）；null 表示不参与版本化 URL（HTML 页面本身）。
    version: ?[16]u8 = null,
    /// 启动时改写引用后新分配的 body；deinit 时释放。
    owned_body: ?[]u8 = null,

    /// 请求带着与当前内容一致的 `?v=` 时可以强缓存。
    pub fn versionMatches(self: *const Asset, requested: ?[]const u8) bool {
        const v = self.version orelse return false;
        const r = requested orelse return false;
        return std.mem.eql(u8, &v, r);
    }
};

/// 版本化 URL 的缓存策略：内容变化时 URL 一定变化，所以可以缓存一年且不校验。
pub const immutable_cache_control = "public, max-age=31536000, immutable";

const html: []const u8 = "text/html; charset=utf-8";
const css: []const u8 = "text/css; charset=utf-8";
const js: []const u8 = "text/javascript; charset=utf-8";

pub var all = [_]Asset{
    .{
        .path = "/",
        .mime = html,
        .body = web.index_html,
    },
    .{
        .path = "/index.html",
        .mime = html,
        .body = web.index_html,
    },
    .{
        .path = "/app.js",
        .mime = js,
        .body = web.app_js,
    },
    .{
        .path = "/style.css",
        .mime = css,
        .body = web.style_css,
    },
    .{
        .path = "/vendor/xterm/xterm.css",
        .mime = css,
        .body = web.xterm_css,
    },
    .{
        .path = "/vendor/xterm/xterm.js",
        .mime = js,
        .body = web.xterm_js,
    },
    .{
        .path = "/vendor/xterm/addon-fit.js",
        .mime = js,
        .body = web.addon_fit_js,
    },
    .{
        .path = "/vendor/xterm/addon-search.js",
        .mime = js,
        .body = web.addon_search_js,
    },
    .{
        .path = "/vendor/xterm/addon-web-links.js",
        .mime = js,
        .body = web.addon_web_links_js,
    },
    .{
        .path = "/vendor/fonts/JetBrainsMono-Regular.woff2",
        .mime = "font/woff2",
        .body = web.jetbrains_mono_woff2,
    },
};

/// `"<32 hex>"` 与 `"<32 hex>-gz"`；两种编码使用不同 ETag，严格符合 Vary 语义。
var etag_plain: [34]u8 = undefined;
var etag_gzip: [37]u8 = undefined;

const min_gzip_bytes = 1024;

/// 启动时调用一次，之后 `all` 只读。内存不足时逐个回退成明文，不影响启动。
pub fn prepare(io: std.Io, allocator: std.mem.Allocator) void {
    var raw: [16]u8 = undefined;
    io.random(&raw);
    const hex = std.fmt.bytesToHex(raw, .lower);
    _ = std.fmt.bufPrint(&etag_plain, "\"{s}\"", .{&hex}) catch unreachable;
    _ = std.fmt.bufPrint(&etag_gzip, "\"{s}-gz\"", .{&hex}) catch unreachable;

    versionAssets(allocator);

    for (&all) |*asset| {
        if (asset.body.len < min_gzip_bytes) continue;
        const zipped = util.gzipAlloc(allocator, asset.body) catch continue;
        // woff2 之类本来就压缩过的资源再 gzip 只会更大，保持原样。
        if (zipped.len >= asset.body.len) {
            allocator.free(zipped);
            continue;
        }
        asset.gzip = zipped;
    }
}

pub fn deinit(allocator: std.mem.Allocator) void {
    for (&all) |*asset| {
        if (asset.gzip) |buf| allocator.free(buf);
        asset.gzip = null;
    }
    // "/" 与 "/index.html" 共用同一份改写结果，只释放一次。
    var freed: ?[*]u8 = null;
    for (&all) |*asset| {
        if (asset.owned_body) |buf| {
            if (freed != buf.ptr) allocator.free(buf);
            freed = buf.ptr;
            asset.owned_body = null;
        }
    }
}

fn isHtml(asset: *const Asset) bool {
    return std.mem.eql(u8, asset.mime, html);
}

fn isCss(asset: *const Asset) bool {
    return std.mem.eql(u8, asset.mime, css);
}

fn contentVersion(body: []const u8) [16]u8 {
    const h = std.hash.Wyhash.hash(0, body);
    var be: [8]u8 = undefined;
    std.mem.writeInt(u64, &be, h, .big);
    return std.fmt.bytesToHex(be, .lower);
}

/// 依赖顺序：先给不引用别人的资源（JS、字体）算版本；CSS 可能引用字体，
/// 改写后再算自己的版本；最后改写 HTML。任何一步内存不足都保留原文，
/// 对应引用退化成不带版本号的 no-cache URL，功能不受影响。
fn versionAssets(allocator: std.mem.Allocator) void {
    for (&all) |*asset| {
        if (isHtml(asset) or isCss(asset)) continue;
        asset.version = contentVersion(asset.body);
    }
    for (&all) |*asset| {
        if (!isCss(asset)) continue;
        if (rewriteRefs(allocator, asset.body)) |body| {
            asset.owned_body = body;
            asset.body = body;
        }
        asset.version = contentVersion(asset.body);
    }
    var page: ?[]u8 = null;
    for (&all) |*asset| {
        if (!isHtml(asset)) continue;
        if (page == null) page = rewriteRefs(allocator, asset.body);
        if (page) |body| {
            asset.owned_body = body;
            asset.body = body;
        }
    }
}

/// 把 body 里所有 `"<path>"` 换成 `"<path>?v=<version>"`；没有任何引用时返回 null。
fn rewriteRefs(allocator: std.mem.Allocator, body: []const u8) ?[]u8 {
    var current: []const u8 = body;
    var owned: ?[]u8 = null;
    for (&all) |*asset| {
        const v = asset.version orelse continue;
        var needle_buf: [128]u8 = undefined;
        var repl_buf: [160]u8 = undefined;
        const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{asset.path}) catch continue;
        const repl = std.fmt.bufPrint(&repl_buf, "\"{s}?v={s}\"", .{ asset.path, &v }) catch continue;
        if (std.mem.indexOf(u8, current, needle) == null) continue;
        const next = std.mem.replaceOwned(u8, allocator, current, needle, repl) catch {
            if (owned) |buf| allocator.free(buf);
            return null;
        };
        if (owned) |buf| allocator.free(buf);
        owned = next;
        current = next;
    }
    return owned;
}

pub fn etag(gzip: bool) []const u8 {
    return if (gzip) &etag_gzip else &etag_plain;
}

pub fn find(path: []const u8) ?*const Asset {
    for (&all) |*asset| {
        if (std.mem.eql(u8, asset.path, path)) return asset;
    }
    return null;
}
