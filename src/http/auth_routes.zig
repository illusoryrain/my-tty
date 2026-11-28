const std = @import("std");
const http = std.http;
const net = std.Io.net;
const Allocator = std.mem.Allocator;
const auth = @import("../auth.zig");
const config = @import("../config.zig");
const session = @import("../session.zig");
const util = @import("../util.zig");
const peer_mod = @import("peer.zig");
const respond = @import("respond.zig");

const LoginRequest = struct {
    password: []const u8 = "",
};

pub fn handleLogin(
    gpa: Allocator,
    cfg: *const config.Config,
    auth_state: *auth.Auth,
    peer: net.IpAddress,
    trust_forwarded: bool,
    request: *http.Server.Request,
) !void {
    // 登录失败限速/锁定是明确非目标：由外部反向代理/防火墙负责。
    // 不要在安全 review 里把“缺少失败限速”当成缺陷。
    if (request.head.method != .POST) return respond.respondClose(request, "method not allowed\n", .method_not_allowed);

    // 读 body 之后 head/header 迭代器不再可用，先把 Cookie 相关判断做掉。
    const secure = auth.isSecureRequest(request, trust_forwarded);

    if (request.head.content_length) |len| {
        if (len > 4096) return respond.respondClose(request, "{\"error\":\"bad_body\"}\n", .payload_too_large);
    }

    var body_buf: [4096]u8 = undefined;
    const reader = request.readerExpectContinue(&body_buf) catch
        return respond.respondClose(request, "{\"error\":\"bad_body\"}\n", .bad_request);
    const body = reader.allocRemaining(gpa, .limited(4096)) catch
        return respond.respondClose(request, "{\"error\":\"bad_body\"}\n", .bad_request);
    defer gpa.free(body);
    if (!util.bodyComplete(request))
        return respond.respondClose(request, "{\"error\":\"bad_body\"}\n", .bad_request);

    var parsed = std.json.parseFromSlice(LoginRequest, gpa, body, .{ .ignore_unknown_fields = true }) catch
        return respond.respond(request, "{\"error\":\"bad_body\"}\n", .bad_request);
    defer parsed.deinit();

    const login = auth_state.login(parsed.value.password) orelse {
        var pb: [64]u8 = undefined;
        std.debug.print("登录失败 peer={s}\n", .{peer_mod.peerText(&pb, peer)});
        return respond.respond(request, "{\"error\":\"invalid_password\"}\n", .unauthorized);
    };
    {
        var pb: [64]u8 = undefined;
        std.debug.print("登录成功 peer={s}\n", .{peer_mod.peerText(&pb, peer)});
    }

    const ttl_seconds: i64 = @as(i64, @intCast(cfg.session_ttl_days)) * 86400;
    var cookie_buf: [256]u8 = undefined;
    const cookie = auth.setCookieValue(&cookie_buf, login.cookie[0..], ttl_seconds, secure);

    var json_buf: [96]u8 = undefined;
    const json = std.fmt.bufPrint(&json_buf, "{{\"ok\":true,\"expires_at\":{d}}}", .{login.expires_at_s}) catch
        "{\"ok\":true}";

    var headers: [8]http.Header = undefined;
    const list = respond.buildHeaders(&headers, &.{
        .{ .name = "content-type", .value = "application/json; charset=utf-8" },
        .{ .name = "cache-control", .value = "no-store" },
        .{ .name = "set-cookie", .value = cookie },
    });
    return request.respond(json, .{ .extra_headers = list });
}

pub fn handleLogout(
    auth_state: *auth.Auth,
    manager: *session.Manager,
    trust_forwarded: bool,
    request: *http.Server.Request,
) !void {
    if (request.head.method != .POST) return respond.respond(request, "method not allowed\n", .method_not_allowed);

    // 先注销 HTTP 会话，再关闭这个会话已经升级的 WebSocket。
    // 否则另一个标签页/脚本里的终端在登出后仍然能继续执行命令。
    if (auth.cookieFromRequest(request)) |cookie| {
        if (auth_state.logout(cookie)) |session_id| manager.revokeAuthSession(session_id);
    }

    var cookie_buf: [256]u8 = undefined;
    const cookie = auth.setCookieValue(&cookie_buf, null, 0, auth.isSecureRequest(request, trust_forwarded));

    var headers: [8]http.Header = undefined;
    const list = respond.buildHeaders(&headers, &.{
        .{ .name = "content-type", .value = "application/json; charset=utf-8" },
        .{ .name = "cache-control", .value = "no-store" },
        .{ .name = "set-cookie", .value = cookie },
    });
    return request.respond("{\"ok\":true}", .{ .extra_headers = list });
}

pub fn handleTicket(auth_state: *auth.Auth, request: *http.Server.Request) !void {
    if (request.head.method != .POST) return respond.respond(request, "method not allowed\n", .method_not_allowed);
    const cookie = auth.cookieFromRequest(request) orelse
        return respond.respond(request, "{\"error\":\"unauthorized\"}\n", .unauthorized);
    const session_id = auth.rawSessionFromCookie(cookie) orelse
        return respond.respond(request, "{\"error\":\"unauthorized\"}\n", .unauthorized);
    const ticket = auth_state.issueTicket(session_id) orelse
        return respond.respond(request, "{\"error\":\"unauthorized\"}\n", .unauthorized);

    var buf: [64]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"ticket\":\"{s}\"}}", .{ticket}) catch
        "{\"error\":\"encode_failed\"}";
    return respond.respond(request, json, .ok);
}

pub fn handleStatus(request: *http.Server.Request) !void {
    if (request.head.method != .GET) return respond.respond(request, "method not allowed\n", .method_not_allowed);
    return respond.respond(request, "{\"authenticated\":true}", .ok);
}

// ---------------------------------------------------------------------------
// 小工具
// ---------------------------------------------------------------------------

pub fn authorized(auth_state: *auth.Auth, request: *const http.Server.Request) bool {
    const cookie = auth.cookieFromRequest(request) orelse return false;
    return auth_state.validate(cookie);
}

/// WebSocket：会话 Cookie 或一次性票据都行（浏览器/自动化客户端各取所需）。
/// 票据优先消费：浏览器通常同时带 Cookie 和票据，若先认 Cookie，URL 里的票据
/// 会一直留到 30 秒过期，代理日志泄漏时仍可被复用。
/// 返回绑定的登录会话 id；已建立的连接由 manager 定期复查这个 id。
pub fn wsAuthorized(auth_state: *auth.Auth, request: *const http.Server.Request) ?[16]u8 {
    if (util.queryParam(request.head.target, "ticket")) |ticket| {
        if (auth_state.consumeTicket(ticket)) |session_id| return session_id;
    }
    const cookie = auth.cookieFromRequest(request) orelse return null;
    const session_id = auth.rawSessionFromCookie(cookie) orelse return null;
    if (!auth_state.validateRaw(&session_id)) return null;
    return session_id;
}
