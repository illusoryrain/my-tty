//! 监听、accept 循环、维护线程与退出流程。
//!
//! 只用 std.http.Server；一条连接一个线程，静态资源全部来自内存。
//! 单条连接的处理在 `http/connection.zig`，路由在 `http/route.zig`。
//! 这里没有任何 TLS 代码。

const std = @import("std");
const net = std.Io.net;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const linux = std.os.linux;
const posix = std.posix;

const assets = @import("assets.zig");
const auth = @import("auth.zig");
const config = @import("config.zig");
const session = @import("session.zig");
const conn = @import("http/conn.zig");
const connection = @import("http/connection.zig");

var shutting_down = std.atomic.Value(bool).init(false);
var listen_handle = std.atomic.Value(posix.fd_t).init(-1);

fn onSignal(_: posix.SIG) callconv(.c) void {
    shutting_down.store(true, .release);
    const fd = listen_handle.load(.acquire);
    if (fd >= 0) _ = linux.shutdown(fd, 2); // SHUT_RDWR
}

fn installSignalHandlers() void {
    const act: posix.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.TERM, &act, null);
    posix.sigaction(.INT, &act, null);
}
pub fn run(io: Io, gpa: Allocator, cfg: *const config.Config) !void {
    var auth_state = auth.Auth.init(io, cfg.password orelse unreachable, cfg.session_ttl_days, cfg.session_idle_hours);
    var manager = session.Manager.init(io, gpa, cfg);
    manager.auth_state = &auth_state;
    defer manager.deinit();

    const addr = try net.IpAddress.parseIp4(cfg.host, cfg.port);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    listen_handle.store(listener.socket.handle, .release);
    defer listen_handle.store(-1, .release);

    try conn.initSlots(gpa, cfg.max_connections);
    defer conn.deinitSlots(gpa);

    // 预压缩静态资源并生成本进程的 ETag；失败时逐个回退明文，不影响启动。
    assets.prepare(io, gpa);
    defer assets.deinit(gpa);

    installSignalHandlers();

    const maint = std.Thread.spawn(.{}, maintenance, .{ io, &auth_state, &manager }) catch null;

    std.debug.print("my-tty 监听 http://{s}:{d}  shell={s}  会话={d}天/{d}h  连接≤{d}  保持={d}分钟\n", .{
        cfg.host,
        cfg.port,
        cfg.shell,
        cfg.session_ttl_days,
        cfg.session_idle_hours,
        cfg.max_connections,
        cfg.pty_idle_minutes,
    });

    while (true) {
        const stream = listener.accept(io) catch |err| {
            if (shutting_down.load(.acquire)) break;
            switch (err) {
                error.Canceled => break,
                else => {
                    std.debug.print("accept 失败: {t}\n", .{err});
                    Io.sleep(io, Io.Duration.fromMilliseconds(100), .real) catch {};
                    continue;
                },
            }
        };

        if (!conn.acquire(cfg.max_connections)) {
            stream.close(io);
            continue;
        }

        conn.connAdd(io, stream.socket.handle);
        conn.tuneSocket(stream.socket.handle);
        const thread = std.Thread.spawn(.{}, connection.main, .{
            io, gpa, stream, cfg, &auth_state, &manager,
        }) catch {
            conn.connRemove(io, stream.socket.handle);
            conn.release();
            stream.close(io);
            continue;
        };
        thread.detach();
    }

    shutting_down.store(true, .release);
    // 必须先唤醒连接，再 join 维护线程：维护线程可能在 sweep() 里等一个
    // 卡在慢客户端写入上的 session 锁；连接不先 shutdown，就会永远 join 不返回。
    conn.shutdownAllConnections(io);
    if (maint) |t| t.join();

    std.debug.print("正在退出：回收 shell…\n", .{});
    // auth_state/manager 都在本函数的栈上，绝不能在线程还在使用时返回。
    var waited: u32 = 0;
    while (conn.active() > 0 and waited < 500) : (waited += 1) {
        Io.sleep(io, Io.Duration.fromMilliseconds(10), .real) catch break;
    }

    if (conn.active() == 0) {
        manager.shutdown();
    } else {
        // 还有连接卡在慢速传输里：不释放会话结构，只杀 shell 后直接退出。
        manager.killChildren();
        std.debug.print("仍有 {d} 个连接未退出，直接退出\n", .{conn.active()});
        std.process.exit(0);
    }
    std.debug.print("已退出\n", .{});
}

fn maintenance(io: Io, auth_state: *auth.Auth, manager: *session.Manager) void {
    var ticks: u32 = 0;
    // 1 秒一跳，便于 SIGTERM 时尽快 join；每 60 跳做一次清理。
    while (!shutting_down.load(.acquire)) {
        Io.sleep(io, Io.Duration.fromSeconds(1), .real) catch |err| {
            std.debug.print("维护线程休眠失败: {t}，停止清理\n", .{err});
            return;
        };
        if (shutting_down.load(.acquire)) break;
        ticks += 1;
        conn.sweepIdleConnections(io);
        // 会话回收每秒一次：pty_idle_minutes=0 也要在 ~1s 内生效；
        // 登录会话/票据的清理保持每分钟一次即可。
        manager.sweep();
        // 已建立的 WebSocket 绑定登录会话；注销/过期后下一次 tick 内踢掉。
        manager.enforceAuth(auth_state);
        if (ticks % 60 == 0) auth_state.sweep();
    }
}
