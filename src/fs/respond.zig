const std = @import("std");
const http = std.http;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const linux = std.os.linux;
const posix = std.posix;
const util = @import("../util.zig");
const limits = @import("limits.zig");
const paths = @import("paths.zig");
const metadata = @import("metadata.zig");

pub fn keepAliveForRequest(request: *const http.Server.Request) bool {
    if (!util.requestHasBody(request)) return true;
    return util.bodyComplete(request);
}

/// JSON / 固定文本响应的头：和 server.zig 的静态资源用同一套安全头。
fn apiHeaders(buf: *[2 + util.security_headers.len]http.Header) []const http.Header {
    buf[0] = .{ .name = "content-type", .value = "application/json; charset=utf-8" };
    buf[1] = .{ .name = "cache-control", .value = "no-store" };
    @memcpy(buf[2..], &util.security_headers);
    return buf;
}

pub fn respondJson(request: *http.Server.Request, alloc: Allocator, status: http.Status, value: anytype) anyerror!void {
    return respondJsonKeepAlive(request, alloc, status, value, keepAliveForRequest(request));
}

/// JSON 小于这个值时压缩的头比省下的字节还多，不值得。
const min_json_gzip_bytes = 1024;

fn respondJsonKeepAlive(
    request: *http.Server.Request,
    alloc: Allocator,
    status: http.Status,
    value: anytype,
    keep_alive: bool,
) anyerror!void {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    std.json.Stringify.value(value, .{}, &out.writer) catch
        return respondStatic(request, .internal_server_error, "{\"error\":\"json_encode_failed\"}");

    // 大目录列表和文本文件读取的 JSON 都是高度可压缩的文本：3000 项列表
    // 约 131 KiB -> 20 KiB。压缩失败或反而更大时回退明文。
    var body: []const u8 = out.written();
    var gzipped: ?[]u8 = null;
    if (body.len >= min_json_gzip_bytes and util.acceptsGzip(request)) {
        if (util.gzipAlloc(alloc, body) catch null) |buf| {
            if (buf.len < body.len) {
                gzipped = buf;
                body = buf;
            } else alloc.free(buf);
        }
    }

    var header_buf: [4 + util.security_headers.len]http.Header = undefined;
    var n: usize = 0;
    header_buf[n] = .{ .name = "content-type", .value = "application/json; charset=utf-8" };
    n += 1;
    header_buf[n] = .{ .name = "cache-control", .value = "no-store" };
    n += 1;
    if (gzipped != null) {
        header_buf[n] = .{ .name = "content-encoding", .value = "gzip" };
        n += 1;
        header_buf[n] = .{ .name = "vary", .value = "accept-encoding" };
        n += 1;
    }
    @memcpy(header_buf[n..][0..util.security_headers.len], &util.security_headers);
    n += util.security_headers.len;
    return request.respond(body, .{
        .status = status,
        .extra_headers = header_buf[0..n],
        .keep_alive = keep_alive,
    });
}

/// 不经过 JSON 编码 / 分配器的固定响应，避免 OOM 时递归调用自身。
pub fn respondStatic(request: *http.Server.Request, status: http.Status, body: []const u8) !void {
    var header_buf: [2 + util.security_headers.len]http.Header = undefined;
    return request.respond(body, .{
        .status = status,
        .extra_headers = apiHeaders(&header_buf),
        .keep_alive = keepAliveForRequest(request),
    });
}

pub fn fail(request: *http.Server.Request, alloc: Allocator, status: http.Status, code: []const u8) anyerror!void {
    const Payload = struct { @"error": []const u8 };
    return respondJson(request, alloc, status, Payload{ .@"error" = code });
}

/// body 没有读完的错误必须关连接，避免残余字节被当成下一个请求。
pub fn failClose(request: *http.Server.Request, alloc: Allocator, status: http.Status, code: []const u8) anyerror!void {
    const Payload = struct { @"error": []const u8 };
    return respondJsonKeepAlive(request, alloc, status, Payload{ .@"error" = code }, false);
}

pub fn failMapped(request: *http.Server.Request, alloc: Allocator, err: anyerror) anyerror!void {
    return switch (err) {
        error.InvalidPath => fail(request, alloc, .bad_request, "invalid_path"),
        error.FileNotFound => fail(request, alloc, .not_found, "not_found"),
        error.PathAlreadyExists => fail(request, alloc, .conflict, "already_exists"),
        error.DirNotEmpty => fail(request, alloc, .conflict, "not_empty"),
        error.CrossDevice => fail(request, alloc, .conflict, "cross_device"),
        error.NotDir => fail(request, alloc, .conflict, "not_a_directory"),
        error.IsDir => fail(request, alloc, .conflict, "is_a_directory"),
        error.AccessDenied => fail(request, alloc, .forbidden, "access_denied"),
        error.NameTooLong => fail(request, alloc, .bad_request, "path_too_long"),
        error.OutOfMemory => fail(request, alloc, .internal_server_error, "out_of_memory"),
        else => fail(request, alloc, .internal_server_error, "io_error"),
    };
}

// ---------------------------------------------------------------------------
