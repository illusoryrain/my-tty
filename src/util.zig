//! HTTP 小工具：从 request target 里取路径和查询参数。
//! 单独放一个文件，测试时就不必把静态资源和整个 server 拉进来。

const std = @import("std");
const http = std.http;
const flate = std.compress.flate;

/// gzip 压缩器约 224 KiB，每次响应都新建/清零没有意义。这里只保留一份，
/// 用互斥锁串行使用；压缩本身是 CPU 密集的，并发请求串行不会成为瓶颈。
var gzip_lock: std.atomic.Mutex = .unlocked;
var gzip_window: [flate.max_window_len]u8 = undefined;
var gzip_comp: flate.Compress = undefined;

/// 用 gzip 容器压缩一段资源。调用方负责释放返回值。
/// `noinline` 避免把压缩器的初始化/调用帧并进 main 的栈。
pub noinline fn gzipAlloc(alloc: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = try std.Io.Writer.Allocating.initCapacity(alloc, 64);
    errdefer out.deinit();

    // util.zig 不持有 Io，无法用 Io.Mutex 的 futex 等待；压缩是短临界区，
    // 让出 CPU 比原地自旋更合适。
    while (!gzip_lock.tryLock()) std.Thread.yield() catch {};
    defer gzip_lock.unlock();
    gzip_comp = try flate.Compress.init(&out.writer, &gzip_window, .gzip, .default);
    try gzip_comp.writer.writeAll(input);
    try gzip_comp.finish();
    return out.toOwnedSlice();
}

/// 内容版本号：16 位十六进制。静态资源用它生成 `?v=` 缓存键，编辑器用它
/// 检测“打开之后文件又被改过”。用内容哈希而不是 mtime：粗粒度时间戳的文件
/// 系统上，同一秒内的两次写入 mtime 相同，哈希不会。
pub fn contentVersion(body: []const u8) [16]u8 {
    const h = std.hash.Wyhash.hash(0, body);
    var be: [8]u8 = undefined;
    std.mem.writeInt(u64, &be, h, .big);
    return std.fmt.bytesToHex(be, .lower);
}

/// 所有响应共用的安全头。API 和静态资源都带上，避免两套路由逐渐走偏。
/// `Accept-Encoding` 是否接受 gzip（忽略 q 值，只要出现 gzip 就当作可以）。
pub fn acceptsGzip(request: *const http.Server.Request) bool {
    // body 读完后 head buffer 已失效；std 的 iterateHeaders 会断言。
    if (request.server.reader.state != .received_head) return false;
    var it = request.iterateHeaders();
    while (it.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "accept-encoding")) continue;
        var parts = std.mem.splitScalar(u8, header.value, ',');
        while (parts.next()) |part| {
            const semi = std.mem.indexOfScalar(u8, part, ';') orelse part.len;
            const token = std.mem.trim(u8, part[0..semi], " \t");
            if (std.ascii.eqlIgnoreCase(token, "gzip")) return true;
        }
    }
    return false;
}

pub const security_headers = [_]http.Header{
    .{ .name = "x-content-type-options", .value = "nosniff" },
    .{ .name = "referrer-policy", .value = "no-referrer" },
    .{ .name = "x-frame-options", .value = "DENY" },
    .{ .name = "content-security-policy", .value = "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self' ws: wss:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'" },
};

/// 请求是否声明了 body（Transfer-Encoding 或 Content-Length，允许 0）。
pub fn requestDeclaresBody(request: *const http.Server.Request) bool {
    if (request.head.transfer_encoding != .none) return true;
    return request.head.content_length != null;
}

/// 请求是否真的带非空 body。
pub fn requestHasBody(request: *const http.Server.Request) bool {
    if (!requestDeclaresBody(request)) return false;
    if (request.head.transfer_encoding != .none) return true;
    return (request.head.content_length orelse 0) != 0;
}

/// body 是否已经被完整读走；没读完就不能复用这条连接。
pub fn bodyComplete(request: *const http.Server.Request) bool {
    return switch (request.server.reader.state) {
        .ready => true,
        else => false,
    };
}

pub fn pathOnly(target: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, target, "?#") orelse target.len;
    return target[0..end];
}

/// 写日志前把控制字符替换掉，防止请求路径里的换行伪造 journal 行。
pub fn logText(buf: []u8, raw: []const u8) []const u8 {
    const n = @min(raw.len, buf.len);
    for (raw[0..n], 0..) |c, i| buf[i] = if (c < 0x20 or c == 0x7f) '?' else c;
    return buf[0..n];
}

pub const DecodeError = error{ InvalidEncoding, OutOfMemory };

/// 解码 query 参数（application/x-www-form-urlencoded：`+` 表示空格，`%XX`）。
/// 只解码一次；调用方仍要对结果做路径/长度校验。
pub fn queryParamDecoded(
    alloc: std.mem.Allocator,
    target: []const u8,
    key: []const u8,
) DecodeError!?[]u8 {
    const raw = queryParam(target, key) orelse return null;
    return try decodeForm(alloc, raw);
}

fn decodeForm(alloc: std.mem.Allocator, raw: []const u8) DecodeError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, raw.len);

    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        if (c == '+') {
            try out.append(alloc, ' ');
        } else if (c == '%') {
            if (i + 2 >= raw.len) return error.InvalidEncoding;
            const hi = std.fmt.charToDigit(raw[i + 1], 16) catch return error.InvalidEncoding;
            const lo = std.fmt.charToDigit(raw[i + 2], 16) catch return error.InvalidEncoding;
            try out.append(alloc, hi << 4 | lo);
            i += 2;
        } else {
            try out.append(alloc, c);
        }
    }
    return try out.toOwnedSlice(alloc);
}

pub fn queryParam(target: []const u8, key: []const u8) ?[]const u8 {
    const qmark = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var it = std.mem.splitScalar(u8, target[qmark + 1 ..], '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
    }
    return null;
}

test "query param extraction" {
    try std.testing.expectEqualStrings("abc", queryParam("/ws?token=abc", "token").?);
    try std.testing.expectEqualStrings("x", queryParam("/ws?a=1&token=x&b=2", "token").?);
    try std.testing.expect(queryParam("/ws?a=1", "token") == null);
    try std.testing.expect(queryParam("/ws", "token") == null);
}

test "query decoding" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try std.testing.expectEqualStrings("a b", (try queryParamDecoded(a, "/x?q=a+b", "q")).?);
    try std.testing.expectEqualStrings("中文.txt", (try queryParamDecoded(a, "/x?q=%E4%B8%AD%E6%96%87.txt", "q")).?);
    try std.testing.expectEqualStrings("a+b", (try queryParamDecoded(a, "/x?q=a%2Bb", "q")).?);
    try std.testing.expectEqualStrings("..", (try queryParamDecoded(a, "/x?q=%2e%2e", "q")).?);
    try std.testing.expect((try queryParamDecoded(a, "/x", "q")) == null);
    try std.testing.expectError(error.InvalidEncoding, queryParamDecoded(a, "/x?q=%2", "q"));
    try std.testing.expectError(error.InvalidEncoding, queryParamDecoded(a, "/x?q=%zz", "q"));
}

test "path strips query and fragment" {
    try std.testing.expectEqualStrings("/", pathOnly("/?a=1"));
    try std.testing.expectEqualStrings("/app.js", pathOnly("/app.js?v=1"));
    try std.testing.expectEqualStrings("/a", pathOnly("/a#x"));
}

test "content version changes with content" {
    const a = contentVersion("hello\n");
    const b = contentVersion("hello!\n");
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
    const again = contentVersion("hello\n");
    try std.testing.expectEqualSlices(u8, &a, &again);
}

test "gzip compresses repetitive input" {
    var input: [8192]u8 = undefined;
    @memset(&input, 'a');
    const out = try gzipAlloc(std.testing.allocator, &input);
    defer std.testing.allocator.free(out);
    try std.testing.expect(out.len > 16);
    try std.testing.expectEqual(@as(u8, 0x1f), out[0]);
    try std.testing.expectEqual(@as(u8, 0x8b), out[1]);
    try std.testing.expect(out.len < input.len / 4);
}
