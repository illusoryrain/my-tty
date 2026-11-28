const std = @import("std");
const http = std.http;
const util = @import("../util.zig");

pub fn ifNoneMatch(request: *const http.Server.Request, tag: []const u8) bool {
    var it = request.iterateHeaders();
    while (it.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "if-none-match")) continue;
        var parts = std.mem.splitScalar(u8, header.value, ',');
        while (parts.next()) |part| {
            const value = std.mem.trim(u8, part, " \t");
            if (std.mem.eql(u8, value, tag) or std.mem.eql(u8, value, "*")) return true;
        }
    }
    return false;
}

pub fn respondNotModified(request: *http.Server.Request, cache_control: []const u8, tag: []const u8) !void {
    var extra = [_]http.Header{
        .{ .name = "cache-control", .value = cache_control },
        .{ .name = "etag", .value = tag },
        .{ .name = "vary", .value = "accept-encoding" },
    };
    var headers: [7]http.Header = undefined;
    const list = buildHeaders(&headers, &extra);
    return request.respond("", .{ .status = .not_modified, .extra_headers = list });
}
pub fn deny(request: *http.Server.Request) !void {
    // 未认证请求可能带着一个永远不会发完的 body；不要为了 keep-alive 去 drain 它。
    return respondClose(request, "{\"error\":\"unauthorized\"}\n", .unauthorized);
}

pub fn respond(request: *http.Server.Request, body: []const u8, status: http.Status) !void {
    var headers: [8]http.Header = undefined;
    const list = buildHeaders(&headers, &.{
        .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
        .{ .name = "cache-control", .value = "no-store" },
    });
    return request.respond(body, .{ .status = status, .extra_headers = list });
}

/// 请求体没有完整读完时用这个：明确让客户端关闭连接，避免残余 body 被当作下一个请求。
pub fn respondClose(request: *http.Server.Request, body: []const u8, status: http.Status) !void {
    var headers: [8]http.Header = undefined;
    const list = buildHeaders(&headers, &.{
        .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
        .{ .name = "cache-control", .value = "no-store" },
    });
    return request.respond(body, .{
        .status = status,
        .extra_headers = list,
        .keep_alive = false,
    });
}

pub fn buildHeaders(dst: []http.Header, extra: []const http.Header) []const http.Header {
    std.debug.assert(dst.len >= extra.len + util.security_headers.len);
    @memcpy(dst[0..extra.len], extra);
    @memcpy(dst[extra.len..][0..util.security_headers.len], &util.security_headers);
    return dst[0 .. extra.len + util.security_headers.len];
}
