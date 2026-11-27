//! my-tty：把 Linux PTY 暴露成浏览器里的终端。
//!
//! 只做三件事：静态页面、WebSocket 升级、PTY 桥接。
//! TLS、鉴权体系、反向代理配置都不在本项目内。

const std = @import("std");
const config = @import("config.zig");
const server = @import("server.zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = init.minimal.args.toSlice(arena) catch {
        std.debug.print("无法解析命令行参数\n", .{});
        std.process.exit(2);
    };

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{config.Config.usage});
            return;
        }
        if (std.mem.eql(u8, arg, "--version")) {
            std.debug.print("my-tty {s}\n", .{config.version});
            return;
        }
    }

    var cfg = config.Config.parse(arena, init) catch |err| {
        std.debug.print("配置错误: {s}\n\n{s}", .{ describe(err), config.Config.usage });
        std.process.exit(2);
    };

    if (argsContain(args, "--check-config")) {
        std.debug.print("配置检查通过: host={s} port={d} sessions={d}d/{d}h conns={d} pty_idle={d}m\n", .{
            cfg.host, cfg.port, cfg.session_ttl_days, cfg.session_idle_hours, cfg.max_connections, cfg.pty_idle_minutes,
        });
        return;
    }

    if (cfg.password == null) {
        var raw: [12]u8 = undefined;
        init.io.random(&raw);
        const hex = std.fmt.bytesToHex(raw, .lower);
        cfg.password = arena.dupe(u8, &hex) catch {
            std.debug.print("无法生成随机密码\n", .{});
            std.process.exit(2);
        };
        std.debug.print("未配置密码，本次启动使用随机密码: {s}\n（重启会更换；请用 --password 或配置文件固定）\n", .{cfg.password.?});
    }

    server.run(init.io, init.gpa, &cfg) catch |err| {
        std.debug.print("启动失败: {t}\n", .{err});
        std.process.exit(1);
    };
}

fn argsContain(args: []const [:0]const u8, needle: []const u8) bool {
    for (args[1..]) |arg| if (std.mem.eql(u8, arg, needle)) return true;
    return false;
}

fn describe(err: config.Config.ParseError) []const u8 {
    return switch (err) {
        error.UnknownArgument => "未知参数",
        error.InvalidPort => "端口不合法",
        error.InvalidNumber => "数字不合法（需要非负整数）",
        error.InvalidMaxSessions => "会话数上限至少为 1",
        error.InvalidHost => "监听地址必须是 IPv4 字面量",
        error.EmptyPassword => "密码不能为空",
        error.WeakPassword => "密码太弱：至少 8 位，且不能使用 change-me/password",
        error.InvalidShell => "shell 必须是绝对路径",
        error.ShellNotFound => "shell 不存在或不可执行",
        error.InvalidSessionTtl => "登录有效期必须在 1–365 天，空闲超时不得超过 8760 小时",
        error.InvalidMaxConnections => "最大连接数必须在 1–4096 之间",
        error.InvalidPtyIdle => "pty 保留时间不得超过 7 天（10080 分钟）",
        error.ConfigReadFailed => "配置文件读取失败",
        error.ConfigInvalid => "配置文件不是合法 JSON 或字段类型不对",
        else => "未知错误",
    };
}
