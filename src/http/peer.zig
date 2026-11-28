const std = @import("std");
const http = std.http;
const net = std.Io.net;
const Io = std.Io;
const conn = @import("conn.zig");

const AuthLogSlot = struct {
    addr: u32 = 0,
    last_ns: i96 = 0,
    used: bool = false,
};
const max_auth_log_ips = 16;
var auth_log_mutex: Io.Mutex = .init;
var auth_log_slots: [max_auth_log_ips]AuthLogSlot = @splat(.{});

pub fn shouldLogAuthFailure(io: Io, peer: net.IpAddress) bool {
    const addr: u32 = switch (peer) {
        .ip4 => |a| std.mem.readInt(u32, &a.bytes, .big),
        .ip6 => 0,
    };
    auth_log_mutex.lockUncancelable(io);
    defer auth_log_mutex.unlock(io);
    const now = conn.monotonicNs(io);
    var free: ?*AuthLogSlot = null;
    for (&auth_log_slots) |*s| {
        if (!s.used) {
            if (free == null) free = s;
            continue;
        }
        if (s.addr == addr) {
            if (now - s.last_ns < std.time.ns_per_s) return false;
            s.last_ns = now;
            return true;
        }
    }
    const slot = free orelse blk: {
        var oldest = &auth_log_slots[0];
        for (&auth_log_slots) |*s| {
            if (s.last_ns < oldest.last_ns) oldest = s;
        }
        break :blk oldest;
    };
    slot.* = .{ .addr = addr, .last_ns = now, .used = true };
    return true;
}
/// 日志里的客户端 IP（不带临时端口）。
pub fn peerText(buf: []u8, peer: net.IpAddress) []const u8 {
    return switch (peer) {
        .ip4 => |a| std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{
            a.bytes[0], a.bytes[1], a.bytes[2], a.bytes[3],
        }) catch "?",
        .ip6 => blk: {
            var w: Io.Writer = .fixed(buf);
            peer.format(&w) catch break :blk "?";
            break :blk w.buffered();
        },
    };
}

/// 对端是否为本机（127.0.0.0/8 或 ::1）。
pub fn peerIsLoopback(peer: net.IpAddress) bool {
    return switch (peer) {
        .ip4 => |a| a.bytes[0] == 127,
        .ip6 => |a| blk: {
            for (a.bytes[0..15]) |b| if (b != 0) break :blk false;
            break :blk a.bytes[15] == 1;
        },
    };
}

/// 浏览器带 Origin 时，必须与 Host 一致；非浏览器客户端可以不带。
///
/// `X-Forwarded-Host` 只在对端是回环（本机反向代理）时才认；否则直连客户端
/// 可以伪造该头绕过 Origin 比较。
pub fn originAllowed(request: *const http.Server.Request, trust_forwarded: bool) bool {
    var origin: ?[]const u8 = null;
    var host: ?[]const u8 = null;
    var forwarded_host: ?[]const u8 = null;
    var it = request.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "origin")) origin = header.value;
        if (std.ascii.eqlIgnoreCase(header.name, "host")) host = header.value;
        if (std.ascii.eqlIgnoreCase(header.name, "x-forwarded-host")) forwarded_host = header.value;
    }
    if (!trust_forwarded) forwarded_host = null;
    const o = origin orelse return true;
    const expected = blk: {
        if (host) |h| {
            // 反向代理如果把 Host 改写成上游地址，X-Forwarded-Host 才是外部名字。
            if (forwarded_host) |fh| {
                var parts = std.mem.splitScalar(u8, fh, ',');
                const first = std.mem.trim(u8, parts.first(), " \t");
                if (first.len > 0) break :blk first;
            }
            break :blk h;
        }
        if (forwarded_host) |fh| break :blk std.mem.trim(u8, fh, " \t");
        return false;
    };
    const rest = if (std.mem.startsWith(u8, o, "http://"))
        o["http://".len..]
    else if (std.mem.startsWith(u8, o, "https://"))
        o["https://".len..]
    else
        return false;
    const trimmed = std.mem.trimEnd(u8, rest, "/");
    return std.ascii.eqlIgnoreCase(trimmed, expected);
}
