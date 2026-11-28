const std = @import("std");
const http = std.http;
const assets = @import("../assets.zig");
const util = @import("../util.zig");
const respond = @import("respond.zig");

/// 公开静态资源：页面外壳、脚本、样式、字体。调用方已设置整体响应时限。
pub fn serve(request: *http.Server.Request) !void {
    const path = util.pathOnly(request.head.target);

    if (std.mem.eql(u8, path, "/favicon.ico")) {
        return respond.respond(request, "", .no_content);
    }

    // 页面外壳与静态资源公开加载；真正的功能都在上面的 API/WS 后面。
    const asset = assets.find(path) orelse {
        return respond.respond(request, "not found\n", .not_found);
    };
    const use_gzip = asset.gzip != null and util.acceptsGzip(request);
    const tag = assets.etag(use_gzip);
    // 带着当前内容版本号的 URL 可以强缓存；旧版本号或没带版本号的仍走 no-cache。
    const cache_control = if (asset.versionMatches(util.queryParam(request.head.target, "v")))
        assets.immutable_cache_control
    else
        asset.cache_control;
    if (respond.ifNoneMatch(request, tag)) return respond.respondNotModified(request, cache_control, tag);

    var extra: [5]http.Header = undefined;
    var n: usize = 0;
    extra[n] = .{ .name = "content-type", .value = asset.mime };
    n += 1;
    extra[n] = .{ .name = "cache-control", .value = cache_control };
    n += 1;
    extra[n] = .{ .name = "etag", .value = tag };
    n += 1;
    extra[n] = .{ .name = "vary", .value = "accept-encoding" };
    n += 1;
    if (use_gzip) {
        extra[n] = .{ .name = "content-encoding", .value = "gzip" };
        n += 1;
    }
    var headers: [9]http.Header = undefined;
    const list = respond.buildHeaders(&headers, extra[0..n]);
    return request.respond(if (use_gzip) asset.gzip.? else asset.body, .{ .extra_headers = list });
}
