const std = @import("std");
const http = std.http;
const net = std.Io.net;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const posix = std.posix;
const auth = @import("../auth.zig");
const config = @import("../config.zig");
const session = @import("../session.zig");
const fsapi = @import("../fs/api.zig");
const util = @import("../util.zig");
const conn = @import("conn.zig");
const peer_mod = @import("peer.zig");
const respond = @import("respond.zig");
const auth_routes = @import("auth_routes.zig");
const static = @import("static.zig");

pub fn handle(
    io: Io,
    gpa: Allocator,
    cfg: *const config.Config,
    auth_state: *auth.Auth,
    manager: *session.Manager,
    peer: net.IpAddress,
    fd: posix.fd_t,
    request: *http.Server.Request,
) !void {
    const path = util.pathOnly(request.head.target);
    // X-Forwarded-* 只有本机反向代理才有资格设置；直连客户端伪造的不认。
    const trust_forwarded = peer_mod.peerIsLoopback(peer);

    // TE + CL 同时出现时，代理和后端可能选不同的长度，直接拒绝。
    if (request.head.transfer_encoding != .none and request.head.content_length != null)
        return respond.respondClose(request, "{\"error\":\"bad_request\"}\n", .bad_request);

    // 只有登录和文件写入/上传会读取请求体。其余路径一旦带 body 就直接关闭，
    // 既不 drain 一个可能永远发不完的 body，也不给 std.http 的 keep-alive
    // 逻辑机会把残余字节解释成下一个请求。
    if (util.requestHasBody(request) and !acceptsRequestBody(path, request.head.method)) {
        return respond.respondClose(request, "{\"error\":\"unexpected_body\"}\n", .bad_request);
    }

    // 浏览器发起的写操作必须来自当前站点。SameSite=Strict 是第一层防护，
    // 这里再显式校验 Origin，覆盖同站子域/localhost 不同端口等 Cookie 仍会发送的场景。
    // 非浏览器客户端可以不带 Origin（curl/自动化工具），不影响现有用法。
    if (request.head.method != .GET and request.head.method != .HEAD and
        !peer_mod.originAllowed(request, trust_forwarded))
    {
        return respond.respondClose(request, "{\"error\":\"bad_origin\"}\n", .forbidden);
    }

    // 唯一的例外：登录端点本身。没有它就无法获得会话。
    if (std.mem.eql(u8, path, "/api/auth/login")) {
        // 这是唯一会读取未登录请求 body 的地方，而且 body 只有 4 KiB；
        // 给整个请求 10 秒上限，挡住慢 body 占住连接线程。
        conn.connSetDeadline(io, fd, 10);
        defer conn.connClearDeadline(io, fd);
        return auth_routes.handleLogin(gpa, cfg, auth_state, peer, trust_forwarded, request);
    }

    // 其余所有 API（含注销、状态、票据）都必须先通过会话认证。
    if (std.mem.startsWith(u8, path, "/api/")) {
        if (!auth_routes.authorized(auth_state, request)) {
            // 登录过期和“网络没恢复”在浏览器里看起来一样；这条日志用来区分：
            // 真的 401 会打 cookie=yes/no，纯网络失败则什么都不会打。
            if (peer_mod.shouldLogAuthFailure(io, peer)) {
                var pb: [64]u8 = undefined;
                var lb: [256]u8 = undefined;
                std.debug.print("未认证 API path={s} peer={s} cookie={s}\n", .{
                    util.logText(&lb, path),
                    peer_mod.peerText(&pb, peer),
                    if (auth.cookieFromRequest(request) == null) "no" else "yes",
                });
            }
            return respond.deny(request);
        }
        if (std.mem.eql(u8, path, "/api/auth/logout")) {
            var pb: [64]u8 = undefined;
            std.debug.print("注销 peer={s}\n", .{peer_mod.peerText(&pb, peer)});
            return auth_routes.handleLogout(auth_state, manager, trust_forwarded, request);
        }
        if (std.mem.eql(u8, path, "/api/auth/status")) return auth_routes.handleStatus(request);
        if (std.mem.eql(u8, path, "/api/auth/ticket")) return auth_routes.handleTicket(auth_state, request);
        if (std.mem.startsWith(u8, path, "/api/fs/")) {
            // 所有已认证 API 都有总上限；下载/归档没有 body 长度，没有它慢客户端
            // 可以永久占住连接槽。上传/写入再按体积收紧。
            conn.connSetDeadline(io, fd, 600);
            defer conn.connClearDeadline(io, fd);
            if (request.head.method == .PUT and util.requestHasBody(request)) {
                // chunked 上传没有 Content-Length；按 64 MiB 上限给时间，不能按 0 算。
                const bytes: i96 = if (request.head.content_length) |n| @intCast(n) else 64 * 1024 * 1024;
                const seconds = @min(@as(i96, 3600), 120 + @divTrunc(bytes, 32 * 1024));
                conn.connSetDeadline(io, fd, seconds);
            }
            return fsapi.handle(io, gpa, request);
        }
        return respond.respond(request, "{\"error\":\"not_found\"}\n", .not_found);
    }

    // HEAD 由 respond 透明处理（省略 body），所以和 GET 走同一套路由。
    if (request.head.method != .GET and request.head.method != .HEAD) {
        return respond.respond(request, "method not allowed\n", .method_not_allowed);
    }

    // 静态资源是公开入口，而且体积可能很大；客户端只收响应头、不读 body 时
    // 会永久占住连接线程（接收窗口为 0 时 TCP keepalive 也救不了）。给整个
    // 响应一个总时限，超时由维护线程 shutdown 唤醒阻塞的写操作。
    conn.connSetDeadline(io, fd, 60);
    defer conn.connClearDeadline(io, fd);

    return static.serve(request);
}
/// 只允许这些端点自己读取 body；其余请求体一律拒绝。
pub fn acceptsRequestBody(path: []const u8, method: http.Method) bool {
    if (std.mem.eql(u8, path, "/api/auth/login")) return method == .POST;
    if (std.mem.eql(u8, path, "/api/fs/write")) return method == .PUT;
    if (std.mem.eql(u8, path, "/api/fs/upload")) return method == .PUT;
    return false;
}
