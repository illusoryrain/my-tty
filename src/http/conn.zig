const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const Io = std.Io;

/// HTTP 阶段等待请求头的空闲上限（秒）。
///
/// 不能用 SO_RCVTIMEO 做超时：std.Io.Threaded 的 netRead 把 EAGAIN 当成
/// “programmer bug” 直接 panic。这里维护一张“正在等请求头”的连接表，
/// 由维护线程主动 shutdown 超时连接；请求开始处理后立刻移出表，
/// 避免误杀慢速的大文件传输。
const idle_seconds: i96 = 30;
var active_connections = std.atomic.Value(u32).init(0);

pub fn active() u32 {
    return active_connections.load(.acquire);
}

/// 占用一个连接名额；超过上限时立刻退还并返回 false。
pub fn acquire(max: usize) bool {
    const prev = active_connections.fetchAdd(1, .acq_rel);
    if (prev >= max) {
        _ = active_connections.fetchSub(1, .acq_rel);
        return false;
    }
    return true;
}

pub fn release() void {
    _ = active_connections.fetchSub(1, .acq_rel);
}

var conn_mutex: Io.Mutex = .init;

const ConnSlot = struct {
    fd: posix.fd_t = -1,
    last_ns: i96 = 0,
    /// 0 = 无截止时间；非 0 时到点就 shutdown，用于未登录登录请求的慢 body。
    deadline_ns: i96 = 0,
    waiting_head: bool = false,
};
var conn_slots: []ConnSlot = &.{};

/// 启动时按 `max_connections` 分配连接表；默认 64，而不是固定 4096。
pub fn initSlots(gpa: std.mem.Allocator, max: usize) !void {
    const slots = try gpa.alloc(ConnSlot, @intCast(max));
    for (slots) |*s| s.* = .{};
    conn_slots = slots;
}

pub fn deinitSlots(gpa: std.mem.Allocator) void {
    gpa.free(conn_slots);
    conn_slots = &.{};
}

pub fn monotonicNs(io: Io) i96 {
    return Io.Clock.awake.now(io).nanoseconds;
}
/// 登记一条已接受的连接；表满时也返回（该连接只是不参与超时/退出唤醒）。
pub fn connAdd(io: Io, fd: posix.fd_t) void {
    conn_mutex.lockUncancelable(io);
    defer conn_mutex.unlock(io);
    const ts = monotonicNs(io);
    for (conn_slots) |*s| {
        if (s.fd == fd) {
            s.last_ns = ts;
            return;
        }
    }
    for (conn_slots) |*s| {
        if (s.fd < 0) {
            s.* = .{ .fd = fd, .last_ns = ts };
            return;
        }
    }
}

/// 标记连接正在等请求头。
pub fn armIdle(io: Io, fd: posix.fd_t) void {
    conn_mutex.lockUncancelable(io);
    defer conn_mutex.unlock(io);
    const ts = monotonicNs(io);
    for (conn_slots) |*s| {
        if (s.fd == fd) {
            s.waiting_head = true;
            s.last_ns = ts;
            return;
        }
    }
    for (conn_slots) |*s| {
        if (s.fd < 0) {
            s.* = .{ .fd = fd, .last_ns = ts, .waiting_head = true };
            return;
        }
    }
}

/// 请求头已经收到：处理请求期间不再参与空闲清理。
pub fn disarmIdle(io: Io, fd: posix.fd_t) void {
    conn_mutex.lockUncancelable(io);
    defer conn_mutex.unlock(io);
    for (conn_slots) |*s| {
        if (s.fd == fd) s.waiting_head = false;
    }
}

/// 给一个连接设置整体截止时间（秒）；用于登录这种小 body 的请求。
pub fn connSetDeadline(io: Io, fd: posix.fd_t, seconds: i96) void {
    conn_mutex.lockUncancelable(io);
    defer conn_mutex.unlock(io);
    const ts = monotonicNs(io);
    for (conn_slots) |*s| {
        if (s.fd == fd) {
            s.deadline_ns = ts + seconds * std.time.ns_per_s;
            return;
        }
    }
}

pub fn connClearDeadline(io: Io, fd: posix.fd_t) void {
    conn_mutex.lockUncancelable(io);
    defer conn_mutex.unlock(io);
    for (conn_slots) |*s| {
        if (s.fd == fd) s.deadline_ns = 0;
    }
}

pub fn connRemove(io: Io, fd: posix.fd_t) void {
    conn_mutex.lockUncancelable(io);
    defer conn_mutex.unlock(io);
    for (conn_slots) |*s| {
        if (s.fd == fd) {
            s.* = .{};
            return;
        }
    }
}

pub fn sweepIdleConnections(io: Io) void {
    conn_mutex.lockUncancelable(io);
    defer conn_mutex.unlock(io);
    const ts = monotonicNs(io);
    for (conn_slots) |*s| {
        if (s.fd < 0) continue;
        if (s.waiting_head and ts - s.last_ns > idle_seconds * std.time.ns_per_s) {
            _ = linux.shutdown(s.fd, 2); // 唤醒阻塞在 receiveHead 的线程
        } else if (s.deadline_ns != 0 and ts > s.deadline_ns) {
            _ = linux.shutdown(s.fd, 2); // 请求整体超时（慢 body）
        }
    }
}

/// 让内核自己发现死连接：空闲 60 秒后每 15 秒探测一次，4 次失败后断开。
/// 客户端掉电/掉 Wi-Fi/手机锁屏不会发 FIN，没有它服务端会永远挂着一个僵尸前端。
/// 同时关掉 Nagle，终端按键不用等 40ms。
pub fn tuneSocket(fd: posix.fd_t) void {
    var one: c_int = 1;
    posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.KEEPALIVE, std.mem.asBytes(&one)) catch {};
    var idle: c_int = 60;
    posix.setsockopt(fd, posix.IPPROTO.TCP, linux.TCP.KEEPIDLE, std.mem.asBytes(&idle)) catch {};
    var interval: c_int = 15;
    posix.setsockopt(fd, posix.IPPROTO.TCP, linux.TCP.KEEPINTVL, std.mem.asBytes(&interval)) catch {};
    var count: c_int = 4;
    posix.setsockopt(fd, posix.IPPROTO.TCP, linux.TCP.KEEPCNT, std.mem.asBytes(&count)) catch {};
    var nodelay: c_int = 1;
    posix.setsockopt(fd, posix.IPPROTO.TCP, linux.TCP.NODELAY, std.mem.asBytes(&nodelay)) catch {};
}

/// 退出时唤醒所有已接受连接（包括正在传文件的），让连接线程尽快返回。
pub fn shutdownAllConnections(io: Io) void {
    conn_mutex.lockUncancelable(io);
    defer conn_mutex.unlock(io);
    for (conn_slots) |*s| {
        if (s.fd >= 0) _ = linux.shutdown(s.fd, 2);
    }
}
