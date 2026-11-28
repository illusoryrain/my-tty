//! 进程级配置。
//!
//! 优先级（后者覆盖前者）：默认值 < 配置文件 < 环境变量 < 命令行参数。
//! 配置文件是 JSON：`my-tty.json`（或 `--config` / `MYTTY_CONFIG` 指定）。
//!
//! 这里刻意不碰网络、不碰 PTY，方便单元测试。

const std = @import("std");
const net = std.Io.net;

pub const default_config_path = "my-tty.json";

/// 当前版本；发布时必须与 build.zig.zon 和 git tag 一致。
pub const version = "0.1.2";

pub const Config = struct {
    /// 监听地址。默认只绑回环：TLS 由外部反向代理终结，本进程不吃公网流量。
    host: []const u8 = "127.0.0.1",
    port: u16 = 7387,
    /// 登录 shell 的绝对路径。
    shell: []const u8 = "/bin/bash",
    /// 登录密码。未配置时由 main 生成随机密码并打印到终端。
    password: ?[]const u8 = null,
    /// 登录会话有效期（天）。
    session_ttl_days: u32 = 7,
    /// 会话空闲超时（小时）；0 表示只看绝对有效期。
    session_idle_hours: u32 = 24,
    /// 最大并发 TCP 连接数。
    max_connections: u32 = 64,
    /// 同时存在的终端会话上限，防止一次误操作 fork 出几百个 shell。
    max_sessions: u32 = 16,
    /// 前端断开后 shell 的保留时间（分钟）；0 表示断开即回收。
    pty_idle_minutes: u32 = 30,
    /// 子进程继承的环境变量。
    environ: std.process.Environ = .empty,

    pub const ParseError = error{
        UnknownArgument,
        InvalidPort,
        InvalidNumber,
        InvalidMaxSessions,
        InvalidHost,
        EmptyPassword,
        WeakPassword,
        InvalidShell,
        ShellNotFound,
        InvalidSessionTtl,
        InvalidMaxConnections,
        InvalidPtyIdle,
        ConfigReadFailed,
        ConfigInvalid,
        OutOfMemory,
        /// 由 `args.toSlice` 的 `try` 传播上来（例如参数不是合法 UTF-8）。
        Unexpected,
    };

    pub const usage =
        \\用法: my-tty [选项]
        \\
        \\  --config <path>      配置文件（默认 ./my-tty.json，存在才加载）
        \\  --host <ipv4>        监听地址（默认 127.0.0.1）
        \\  --port <1-65535>     监听端口（默认 7387）
        \\  --shell <path>       登录 shell（默认 $SHELL 或 /bin/bash）
        \\  --password <secret>  登录密码；不填则每次启动随机生成
        \\  --version            显示版本
        \\  --session-ttl-days <n>  登录有效期，默认 7 天
        \\  --session-idle-hours <n>  空闲超时，默认 24 小时（0 关闭）
        \\  --max-connections <n>  最大并发连接，默认 64
        \\  --check-config       只校验配置，然后退出
        \\  --max-sessions <n>   并发会话上限（默认 16）
        \\  --pty-idle-minutes <n>  断开后保留 shell 的分钟数（默认 30，0 关闭）
        \\  -h, --help           显示本帮助
        \\
        \\配置文件示例（my-tty.json，字段全部可选）:
        \\  {
        \\    "host": "127.0.0.1",
        \\    "port": 7387,
        \\    "shell": "/bin/bash",
        \\    "password": "replace-with-a-long-random-password",
        \\    "session_ttl_days": 7,
        \\    "session_idle_hours": 24,
        \\    "max_connections": 64,
        \\    "max_sessions": 16,
        \\    "pty_idle_minutes": 30
        \\  }
        \\
        \\环境变量: MYTTY_CONFIG / MYTTY_HOST / MYTTY_PORT / MYTTY_SHELL /
        \\          MYTTY_PASSWORD / MYTTY_SESSION_TTL_DAYS / MYTTY_SESSION_IDLE_HOURS /
        \\          MYTTY_MAX_CONNECTIONS / MYTTY_MAX_SESSIONS /
        \\          MYTTY_PTY_IDLE_MINUTES
        \\
        \\TLS 不在本程序范围内：请只监听回环地址，把明文 HTTP/WS 交给外部反向代理。
        \\
    ;

    /// 配置文件的结构；全部可选，未出现的字段不覆盖上一层。
    const FileConfig = struct {
        host: ?[]const u8 = null,
        port: ?u16 = null,
        shell: ?[]const u8 = null,
        password: ?[]const u8 = null,
        session_ttl_days: ?u32 = null,
        session_idle_hours: ?u32 = null,
        max_connections: ?u32 = null,
        max_sessions: ?u32 = null,
        pty_idle_minutes: ?u32 = null,
    };

    pub fn parse(alloc: std.mem.Allocator, init: std.process.Init) ParseError!Config {
        var cfg: Config = .{ .environ = init.minimal.environ };
        const args = try init.minimal.args.toSlice(alloc);
        const env = init.environ_map;
        var shell_set = false;

        // 1) 配置文件
        const explicit_path = scanOption(args, "--config") orelse env.get("MYTTY_CONFIG");
        if (explicit_path) |path| {
            shell_set = try loadConfigFile(init.io, alloc, path, &cfg, true);
        } else {
            shell_set = try loadConfigFile(init.io, alloc, default_config_path, &cfg, false);
        }

        // 2) 环境变量
        if (env.get("MYTTY_HOST")) |v| cfg.host = v;
        if (env.get("MYTTY_PASSWORD")) |v| cfg.password = v;
        if (env.get("MYTTY_SESSION_TTL_DAYS")) |v| cfg.session_ttl_days = try parseCount(v);
        if (env.get("MYTTY_SESSION_IDLE_HOURS")) |v| cfg.session_idle_hours = try parseCount(v);
        if (env.get("MYTTY_MAX_CONNECTIONS")) |v| cfg.max_connections = try parseCount(v);
        if (env.get("MYTTY_PORT")) |v| cfg.port = try parsePort(v);
        if (env.get("MYTTY_MAX_SESSIONS")) |v| cfg.max_sessions = try parseCount(v);
        if (env.get("MYTTY_PTY_IDLE_MINUTES")) |v| cfg.pty_idle_minutes = try parseCount(v);
        if (env.get("MYTTY_SHELL")) |v| {
            cfg.shell = v;
            shell_set = true;
        }

        // 3) 命令行
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                return error.UnknownArgument; // main 会先识别 help
            } else if (optionValue(args, &i, "--config")) |_| {
                // 文件已在第一步加载，这里只消费参数。
            } else if (optionValue(args, &i, "--host")) |v| {
                cfg.host = v;
            } else if (optionValue(args, &i, "--port")) |v| {
                cfg.port = try parsePort(v);
            } else if (optionValue(args, &i, "--shell")) |v| {
                cfg.shell = v;
                shell_set = true;
            } else if (optionValue(args, &i, "--password")) |v| {
                cfg.password = v;
            } else if (optionValue(args, &i, "--session-ttl-days")) |v| {
                cfg.session_ttl_days = try parseCount(v);
            } else if (optionValue(args, &i, "--session-idle-hours")) |v| {
                cfg.session_idle_hours = try parseCount(v);
            } else if (optionValue(args, &i, "--max-connections")) |v| {
                cfg.max_connections = try parseCount(v);
            } else if (std.mem.eql(u8, arg, "--check-config")) {
                // main 在启动前单独处理
            } else if (optionValue(args, &i, "--max-sessions")) |v| {
                cfg.max_sessions = try parseCount(v);
            } else if (optionValue(args, &i, "--pty-idle-minutes")) |v| {
                cfg.pty_idle_minutes = try parseCount(v);
            } else {
                return error.UnknownArgument;
            }
        }

        // 只有在没人显式配置 shell 时，才拿进程的 $SHELL 兜底。
        if (!shell_set) {
            if (env.get("SHELL")) |v| cfg.shell = v;
        }

        if (!std.fs.path.isAbsolute(cfg.shell)) return error.InvalidShell;
        const shell_st = std.Io.Dir.cwd().statFile(init.io, cfg.shell, .{}) catch
            return error.ShellNotFound;
        if (shell_st.kind != .file or (shell_st.permissions.toMode() & 0o111) == 0)
            return error.ShellNotFound;

        try cfg.validate();
        return cfg;
    }

    pub fn validate(cfg: *const Config) ParseError!void {
        // 只接受 IPv4 字面量：不做 DNS，配置越简单越好。
        _ = net.IpAddress.parseIp4(cfg.host, cfg.port) catch return error.InvalidHost;
        if (cfg.port == 0) return error.InvalidPort;
        if (cfg.max_sessions == 0) return error.InvalidMaxSessions;
        if (cfg.password) |p| {
            if (p.len == 0) return error.EmptyPassword;
            if (p.len < 8 or std.mem.eql(u8, p, "change-me") or std.mem.eql(u8, p, "password"))
                return error.WeakPassword;
        }
        if (cfg.session_ttl_days == 0 or cfg.session_ttl_days > 365) return error.InvalidSessionTtl;
        if (cfg.session_idle_hours > 8760) return error.InvalidSessionTtl;
        if (cfg.max_connections == 0 or cfg.max_connections > 4096) return error.InvalidMaxConnections;
        if (cfg.pty_idle_minutes > 10080) return error.InvalidPtyIdle;
    }
};

fn loadConfigFile(
    io: std.Io,
    alloc: std.mem.Allocator,
    path: []const u8,
    cfg: *Config,
    required: bool,
) Config.ParseError!bool {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(64 * 1024)) catch |err| {
        if (!required and err == error.FileNotFound) return false;
        return error.ConfigReadFailed;
    };

    // 忽略未知字段：旧配置里的 "root" 之类的历史键不会阻止启动。
    var parsed = std.json.parseFromSlice(Config.FileConfig, alloc, bytes, .{ .ignore_unknown_fields = true }) catch
        return error.ConfigInvalid;
    defer parsed.deinit();

    const file = parsed.value;
    if (file.host) |v| cfg.host = try alloc.dupe(u8, v);
    if (file.port) |v| cfg.port = v;
    if (file.shell) |v| cfg.shell = try alloc.dupe(u8, v);
    if (file.password) |v| cfg.password = try alloc.dupe(u8, v);
    if (file.session_ttl_days) |v| cfg.session_ttl_days = v;
    if (file.session_idle_hours) |v| cfg.session_idle_hours = v;
    if (file.max_connections) |v| cfg.max_connections = v;
    if (file.max_sessions) |v| cfg.max_sessions = v;
    if (file.pty_idle_minutes) |v| cfg.pty_idle_minutes = v;
    return file.shell != null;
}

/// `--key value` 或 `--key=value`；命中时前进下标并返回对应的值。
fn optionValue(args: []const [:0]const u8, i: *usize, comptime name: []const u8) ?[]const u8 {
    const arg = args[i.*];
    if (std.mem.eql(u8, arg, name)) {
        if (i.* + 1 >= args.len) return null;
        i.* += 1;
        return args[i.*];
    }
    if (std.mem.startsWith(u8, arg, name ++ "=")) return arg[name.len + 1 ..];
    return null;
}

/// 只读扫描（不消费下标），用于在正式解析前确定配置文件路径。
fn scanOption(args: []const [:0]const u8, comptime name: []const u8) ?[]const u8 {
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, name)) {
            if (i + 1 >= args.len) return null;
            return args[i + 1];
        }
        if (std.mem.startsWith(u8, arg, name ++ "=")) return arg[name.len + 1 ..];
    }
    return null;
}

fn parsePort(text: []const u8) Config.ParseError!u16 {
    const n = std.fmt.parseInt(u16, text, 10) catch return error.InvalidPort;
    if (n == 0) return error.InvalidPort;
    return n;
}

fn parseCount(text: []const u8) Config.ParseError!u32 {
    return std.fmt.parseInt(u32, text, 10) catch return error.InvalidNumber;
}

/// 定长时间比较，避免 token 逐字节泄漏长度/前缀。
pub fn constantTimeEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

test "constant time equality" {
    try std.testing.expect(constantTimeEql("abc", "abc"));
    try std.testing.expect(!constantTimeEql("abc", "abd"));
    try std.testing.expect(!constantTimeEql("abc", "ab"));
}

test "validate connection and idle bounds" {
    var cfg: Config = .{};
    try cfg.validate();
    cfg.max_connections = 0;
    try std.testing.expectError(error.InvalidMaxConnections, cfg.validate());
    cfg.max_connections = 4097;
    try std.testing.expectError(error.InvalidMaxConnections, cfg.validate());
    cfg.max_connections = 64;
    cfg.session_idle_hours = 8761;
    try std.testing.expectError(error.InvalidSessionTtl, cfg.validate());
    cfg.session_idle_hours = 24;
    cfg.pty_idle_minutes = 10081;
    try std.testing.expectError(error.InvalidPtyIdle, cfg.validate());
}

test "validate session ttl bounds" {
    var cfg: Config = .{};
    try cfg.validate();
    cfg.session_ttl_days = 0;
    try std.testing.expectError(error.InvalidSessionTtl, cfg.validate());
    cfg.session_ttl_days = 366;
    try std.testing.expectError(error.InvalidSessionTtl, cfg.validate());
}
