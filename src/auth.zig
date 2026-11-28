//! 登录会话：密码登录 -> 随机 session id -> HttpOnly Cookie。
//!
//! 会话只存在内存里：进程重启后全部失效，需要重新登录。容量固定 256 个，
//! 过期或被覆盖的槽位直接复用，不需要额外的清理线程。

const std = @import("std");
const Io = std.Io;
const http = std.http;
const config = @import("config.zig");

pub const cookie_name = "my_tty_session";
/// 每个槽位只有几十字节，256 个约 10 KiB；留足余量，避免反复登录/多设备测试时
/// 把还在用的旧会话挤掉（被挤掉的浏览器下次请求就是 401）。
pub const max_sessions = 256;

pub const Auth = struct {
    io: Io,
    password: []const u8,
    ttl_days: u32,
    idle_hours: u32,
    /// 上一次命中的槽位；单用户/单浏览器时把常见的查找变成一次比较。
    last_slot: usize = 0,
    mutex: Io.Mutex = .init,
    sessions: [max_sessions]Session = @splat(.{}),
    tickets: [max_tickets]Ticket = @splat(.{}),

    const Session = struct {
        id: [16]u8 = @splat(0),
        expires_ns: i96 = 0,
        last_seen_ns: i96 = 0,
        used: bool = false,
    };

    pub const max_tickets = 32;
    pub const ticket_ttl_ns: i96 = 30 * std.time.ns_per_s;

    const Ticket = struct {
        id: [16]u8 = @splat(0),
        /// 票据签发时绑定的登录会话；会话注销/过期后票据立即失效。
        session: [16]u8 = @splat(0),
        expires_ns: i96 = 0,
        used: bool = false,
    };

    pub const Login = struct {
        /// 32 个十六进制字符，直接放进 Cookie。
        cookie: [32]u8,
        expires_at_s: i64,
    };

    pub fn init(io: Io, password: []const u8, ttl_days: u32, idle_hours: u32) Auth {
        return .{
            .io = io,
            .password = password,
            .ttl_days = ttl_days,
            .idle_hours = idle_hours,
        };
    }

    fn idleNs(self: *const Auth) i96 {
        const hours: i96 = @intCast(self.idle_hours);
        return hours * 60 * 60 * std.time.ns_per_s;
    }

    fn ttlNs(self: *const Auth) i96 {
        const days: i96 = @intCast(self.ttl_days);
        return days * 24 * 60 * 60 * std.time.ns_per_s;
    }

    fn nowNs(self: *const Auth) i96 {
        return Io.Clock.awake.now(self.io).nanoseconds;
    }

    /// 先做定长哈希再比较，避免长度不同时提前返回泄露密码长度。
    fn passwordMatches(candidate: []const u8, expected: []const u8) bool {
        var a: [32]u8 = undefined;
        var b: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(candidate, &a, .{});
        std.crypto.hash.sha2.Sha256.hash(expected, &b, .{});
        return std.crypto.timing_safe.eql([32]u8, a, b);
    }

    /// 密码正确时分配一个会话；返回 Cookie 值与绝对过期时间（Unix 秒）。
    pub fn login(self: *Auth, candidate: []const u8) ?Login {
        if (!passwordMatches(candidate, self.password)) return null;

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const now = self.nowNs();
        const ttl = self.ttlNs();

        var slot: usize = 0;
        var lru: i96 = std.math.maxInt(i96);
        for (&self.sessions, 0..) |*s, i| {
            if (!s.used or s.expires_ns <= now) {
                slot = i;
                break;
            }
            // 满员时淘汰“最久没被任何请求碰过”的会话，而不是最早登录的那个：
            // 所有会话都是 now+7天，按 expires 淘汰等于专挑用户每天在用的老窗口，
            // 反而留下刚登录后再没动过的槽位。
            if (s.last_seen_ns < lru) {
                lru = s.last_seen_ns;
                slot = i;
            }
        }

        var raw: [16]u8 = undefined;
        self.io.random(&raw);
        self.sessions[slot] = .{
            .id = raw,
            .expires_ns = now + ttl,
            .last_seen_ns = now,
            .used = true,
        };

        const now_s: i64 = @intCast(@divTrunc(Io.Clock.real.now(self.io).nanoseconds, std.time.ns_per_s));
        const expires_at_s = now_s + @as(i64, @intCast(self.ttl_days)) * 86400;
        return .{
            .cookie = std.fmt.bytesToHex(raw, .lower),
            .expires_at_s = expires_at_s,
        };
    }

    /// 校验 Cookie 值是否对应一个未过期会话。
    pub fn validate(self: *Auth, cookie_value: []const u8) bool {
        const raw = rawSessionFromCookie(cookie_value) orelse return false;
        return self.validateRaw(&raw);
    }

    /// 校验 16 字节原始会话 id，并刷新活跃时间。WebSocket 升级时也走这里。
    pub fn validateRaw(self: *Auth, raw: *const [16]u8) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const now = self.nowNs();
        const idle_limit = self.idleNs();

        // 先看上次命中的槽位：一个浏览器一直开着时，几乎总是这里直接命中。
        if (self.checkSession(self.last_slot, raw, now, idle_limit)) return true;
        for (0..self.sessions.len) |i| {
            if (i == self.last_slot) continue;
            if (self.checkSession(i, raw, now, idle_limit)) return true;
        }
        return false;
    }

    /// 只检查会话是否仍然有效，不刷新 last_seen。用于已经建立的 WebSocket：
    /// 终端流量不应该替 HTTP 会话续命，但会话注销/过期后必须能把它踢掉。
    pub fn sessionValid(self: *Auth, raw: *const [16]u8) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.sessionValidLocked(raw, self.nowNs(), self.idleNs());
    }

    fn sessionValidLocked(self: *Auth, raw: *const [16]u8, now: i96, idle_limit: i96) bool {
        for (&self.sessions) |*s| {
            if (!s.used or s.expires_ns <= now) continue;
            if (self.idle_hours != 0 and now - s.last_seen_ns > idle_limit) continue;
            if (config.constantTimeEql(&s.id, raw)) return true;
        }
        return false;
    }

    /// 校验单个槽位；顺带清理过期/空闲会话，命中时刷新 last_seen。
    fn checkSession(self: *Auth, i: usize, raw: *const [16]u8, now: i96, idle_limit: i96) bool {
        const s = &self.sessions[i];
        if (!s.used) return false;
        if (s.expires_ns <= now) {
            s.used = false;
            return false;
        }
        if (self.idle_hours != 0 and now - s.last_seen_ns > idle_limit) {
            s.used = false;
            return false;
        }
        if (!config.constantTimeEql(&s.id, raw)) return false;
        s.last_seen_ns = now;
        self.last_slot = i;
        return true;
    }

    /// 为 WebSocket 升级签发一次性短票据：浏览器无法给 WS 请求加自定义头，
    /// 又不想把长期会话放进 URL。票据 30 秒有效、用一次即废。
    pub fn issueTicket(self: *Auth, session: [16]u8) ?[32]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const now = self.nowNs();
        if (!self.sessionValidLocked(&session, now, self.idleNs())) return null;
        var slot: usize = 0;
        var oldest: i96 = std.math.maxInt(i96);
        for (&self.tickets, 0..) |*t, i| {
            if (!t.used or t.expires_ns <= now) {
                slot = i;
                break;
            }
            if (t.expires_ns < oldest) {
                oldest = t.expires_ns;
                slot = i;
            }
        }

        var raw: [16]u8 = undefined;
        self.io.random(&raw);
        self.tickets[slot] = .{
            .id = raw,
            .session = session,
            .expires_ns = now + ticket_ttl_ns,
            .used = true,
        };
        return std.fmt.bytesToHex(raw, .lower);
    }

    pub fn consumeTicket(self: *Auth, value: []const u8) ?[16]u8 {
        if (value.len != 32) return null;
        var raw: [16]u8 = undefined;
        _ = std.fmt.hexToBytes(&raw, value) catch return null;

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const now = self.nowNs();
        const idle_limit = self.idleNs();
        for (&self.tickets) |*t| {
            if (!t.used) continue;
            if (t.expires_ns <= now) {
                t.used = false;
                continue;
            }
            if (config.constantTimeEql(&t.id, &raw)) {
                t.used = false;
                if (self.sessionValidLocked(&t.session, now, idle_limit)) return t.session;
                return null;
            }
        }
        return null;
    }

    /// 定期清理过期/空闲会话与一次性票据。
    pub fn sweep(self: *Auth) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const now = self.nowNs();
        const idle_limit = self.idleNs();
        for (&self.sessions) |*s| {
            if (!s.used) continue;
            if (s.expires_ns <= now) {
                s.used = false;
                continue;
            }
            if (self.idle_hours != 0 and now - s.last_seen_ns > idle_limit) s.used = false;
        }
        for (&self.tickets) |*t| {
            if (t.used and t.expires_ns <= now) t.used = false;
        }
    }

    /// 注销会话；返回被注销的原始 id，调用方据此关闭它打开的 WebSocket。
    pub fn logout(self: *Auth, cookie_value: []const u8) ?[16]u8 {
        const raw = rawSessionFromCookie(cookie_value) orelse return null;

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        for (&self.sessions) |*s| {
            if (s.used and config.constantTimeEql(&s.id, &raw)) {
                s.used = false;
                s.expires_ns = 0;
                return raw;
            }
        }
        return null;
    }
};

/// 把 32 位十六进制 Cookie 值解析成 16 字节原始会话 id。
pub fn rawSessionFromCookie(cookie_value: []const u8) ?[16]u8 {
    if (cookie_value.len != 32) return null;
    var raw: [16]u8 = undefined;
    _ = std.fmt.hexToBytes(&raw, cookie_value) catch return null;
    return raw;
}

/// 从 `Cookie:` 头的值里取出会话 id。
pub fn sessionFromCookieHeader(header: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, header, ';');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        const name = std.mem.trim(u8, trimmed[0..eq], " \t");
        if (std.mem.eql(u8, name, cookie_name)) {
            return std.mem.trim(u8, trimmed[eq + 1 ..], " \t");
        }
    }
    return null;
}

/// 在请求头里找 Cookie。
pub fn cookieFromRequest(request: *const http.Server.Request) ?[]const u8 {
    var it = request.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "cookie")) {
            if (sessionFromCookieHeader(header.value)) |value| return value;
        }
    }
    return null;
}

/// 反向代理在终止 TLS 后通常会带 `X-Forwarded-Proto: https`；只有这时才加
/// `Secure`，本地明文访问不受影响。
///
/// 该头只能由本机反向代理覆盖，所以只在对端是回环地址时才信任；否则任何
/// 直连客户端都能伪造它。
pub fn isSecureRequest(request: *const http.Server.Request, trust_forwarded: bool) bool {
    if (!trust_forwarded) return false;
    var it = request.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "x-forwarded-proto")) {
            return std.ascii.eqlIgnoreCase(std.mem.trim(u8, header.value, " \t"), "https");
        }
    }
    return false;
}

/// 生成 `Set-Cookie` 头内容。`value` 为 null 表示清除。
pub fn setCookieValue(buf: []u8, value: ?[]const u8, max_age_seconds: i64, secure: bool) []const u8 {
    const tail = if (secure)
        "; Path=/; HttpOnly; SameSite=Strict; Secure"
    else
        "; Path=/; HttpOnly; SameSite=Strict";
    if (value) |v| {
        return std.fmt.bufPrint(buf, "{s}={s}; Max-Age={d}{s}", .{
            cookie_name, v, max_age_seconds, tail,
        }) catch "";
    }
    return std.fmt.bufPrint(buf, "{s}=; Max-Age=0{s}", .{ cookie_name, tail }) catch "";
}

test "cookie header parsing" {
    try std.testing.expectEqualStrings(
        "abc123",
        sessionFromCookieHeader("other=1; my_tty_session=abc123; theme=dark").?,
    );
    try std.testing.expect(sessionFromCookieHeader("other=1; theme=dark") == null);
    try std.testing.expectEqualStrings(
        "v",
        sessionFromCookieHeader("my_tty_session = v").?,
    );
}

test "login validate logout" {
    const io = std.testing.io;
    var auth = Auth.init(io, "correct horse", 7, 24);

    try std.testing.expect(auth.login("wrong") == null);

    const session = auth.login("correct horse").?;
    const raw = rawSessionFromCookie(&session.cookie).?;
    try std.testing.expect(auth.validate(&session.cookie));
    try std.testing.expect(auth.sessionValid(&raw));
    try std.testing.expect(!auth.validate("00000000000000000000000000000000"));

    _ = auth.logout(&session.cookie);
    try std.testing.expect(!auth.validate(&session.cookie));
    try std.testing.expect(!auth.sessionValid(&raw));
}

test "full session table evicts the least recently used session" {
    const io = std.testing.io;
    var auth = Auth.init(io, "pw", 7, 24);

    var cookies: [max_sessions][32]u8 = undefined;
    for (&cookies) |*c| c.* = auth.login("pw").?.cookie;

    // 第一个会话刚被请求过（last_seen 最新）；第二个会话登录后再没动过。
    try std.testing.expect(auth.validate(&cookies[0]));

    const extra = auth.login("pw").?;
    // 正在用的窗口不能被挤掉，淘汰的应该是第二个会话。
    try std.testing.expect(auth.validate(&cookies[0]));
    try std.testing.expect(auth.validate(&extra.cookie));
    try std.testing.expect(!auth.validate(&cookies[1]));
}

test "validate switches between two sessions" {
    const io = std.testing.io;
    var auth = Auth.init(io, "pw", 7, 24);
    const a = auth.login("pw").?.cookie;
    const b = auth.login("pw").?.cookie;
    try std.testing.expect(auth.validate(&a));
    try std.testing.expect(auth.validate(&b));
    try std.testing.expect(auth.validate(&a));
}

test "zero ttl expires immediately" {
    const io = std.testing.io;
    var auth = Auth.init(io, "pw", 0, 24);
    const session = auth.login("pw").?;
    try std.testing.expect(!auth.validate(&session.cookie));
}

test "ticket is one time and bound to a live session" {
    const io = std.testing.io;
    var auth = Auth.init(io, "pw", 7, 24);
    const login = auth.login("pw").?;
    const session = rawSessionFromCookie(&login.cookie).?;
    const ticket = auth.issueTicket(session).?;
    try std.testing.expectEqualSlices(u8, &session, &auth.consumeTicket(&ticket).?);
    try std.testing.expect(auth.consumeTicket(&ticket) == null);
    try std.testing.expect(auth.consumeTicket("nope") == null);

    const next = auth.issueTicket(session).?;
    _ = auth.logout(&login.cookie);
    try std.testing.expect(auth.consumeTicket(&next) == null);
    try std.testing.expect(auth.issueTicket(session) == null);
}

test "set cookie format" {
    var buf: [256]u8 = undefined;
    const v = setCookieValue(&buf, "abc", 604800, false);
    try std.testing.expect(std.mem.indexOf(u8, v, "my_tty_session=abc") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "Max-Age=604800") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "HttpOnly") != null);

    const cleared = setCookieValue(&buf, null, 0, true);
    try std.testing.expect(std.mem.indexOf(u8, cleared, "Max-Age=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, cleared, "Secure") != null);
}
