//! Linux PTY：/dev/ptmx + fork/exec，不依赖 libc。
//!
//! 只支持 Linux（x86_64 / aarch64 等通用 ioctl 编码）；其它平台在编译期拒绝。
//! 子进程只调用异步信号安全的系统调用，因此可以安全地在多线程服务器里 fork。

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const posix = std.posix;
const Io = std.Io;
const winsize = posix.winsize;

comptime {
    if (builtin.os.tag != .linux) {
        @compileError("my-tty 只支持 Linux：PTY 层直接使用 Linux ioctl 与 fork/exec");
    }
}

pub const Pty = struct {
    /// PTY 主设备。读写它就是终端的输入输出。
    master: posix.fd_t,
    /// shell 的 pid（同时也是会话首进程）。
    child: posix.pid_t,
};

pub const SpawnError = error{
    OpenPtyFailed,
    UnlockPtyFailed,
    PtyNumberFailed,
    OpenSlaveFailed,
    ForkFailed,
} || std.mem.Allocator.Error;

pub const SpawnOptions = struct {
    shell: []const u8,
    environ: std.process.Environ,
    cols: u16 = 80,
    rows: u16 = 24,
};

const env_capacity = 512;
const default_path = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";

pub fn spawn(io: Io, gpa: std.mem.Allocator, opts: SpawnOptions) SpawnError!Pty {
    // fork 之后子进程不能再分配内存；argv/envp 必须先准备好。
    const shell_z = try gpa.dupeSentinel(u8, opts.shell, 0);
    defer gpa.free(shell_z);

    // 账号信息以 /etc/passwd（按真实 uid）为准，不能只信守护进程的 $HOME：
    // systemd/init/rc.local 启动时 HOME 可能压根不存在，sudo/su 也可能留下别人的 HOME。
    const account = resolveAccount(io, gpa) catch null;
    defer if (account) |a| a.deinit(gpa);

    const home_z = try chooseHome(io, gpa, account, opts.environ);
    defer gpa.free(home_z);

    // argv[0] 用 "-bash" 这种形式，再补一个 -l：login shell 才会读
    // /etc/profile 和 ~/.profile，PATH/EDITOR 等变量才会像 SSH 登录一样加载。
    const base = std.fs.path.basename(opts.shell);
    const login_z = try std.fmt.allocPrintSentinel(gpa, "-{s}", .{if (base.len > 0) base else opts.shell}, 0);
    defer gpa.free(login_z);

    var argv = [_]?[*:0]const u8{ login_z.ptr, "-l", null };
    var env = EnvBuilder{ .gpa = gpa };
    defer env.deinit();
    try env.build(io, account, home_z, opts.shell, opts.environ);

    const master = posix.openat(posix.AT.FDCWD, "/dev/ptmx", .{
        .ACCMODE = .RDWR,
        .NOCTTY = true,
        .CLOEXEC = true,
        // 读走 pump 的 poll，写走 writeAll 的 poll；非阻塞主端避免客户端输入
        // 把连接线程永久卡在 write(2) 上。
        .NONBLOCK = true,
    }, 0) catch return error.OpenPtyFailed;
    errdefer _ = linux.close(master);

    var unlock: c_int = 0;
    if (linux.errno(linux.ioctl(master, linux.T.IOCSPTLCK, @intFromPtr(&unlock))) != .SUCCESS)
        return error.UnlockPtyFailed;

    var ptn: c_uint = 0;
    if (linux.errno(linux.ioctl(master, linux.T.IOCGPTN, @intFromPtr(&ptn))) != .SUCCESS)
        return error.PtyNumberFailed;

    var path_buf: [64]u8 = undefined;
    const path_raw = std.fmt.bufPrint(&path_buf, "/dev/pts/{d}", .{ptn}) catch return error.OpenSlaveFailed;
    path_buf[path_raw.len] = 0;
    const slave_path = path_buf[0..path_raw.len :0];

    const slave = posix.openat(posix.AT.FDCWD, slave_path, .{
        .ACCMODE = .RDWR,
        .NOCTTY = true,
    }, 0) catch return error.OpenSlaveFailed;
    errdefer _ = linux.close(slave);

    resize(master, opts.cols, opts.rows);

    const rc = linux.fork();
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        else => return error.ForkFailed,
    }

    if (rc == 0) {
        // ---- 子进程 ----
        _ = linux.close(master);
        _ = linux.setsid();
        _ = linux.ioctl(slave, linux.T.IOCSCTTY, 0);
        _ = linux.dup2(slave, 0);
        _ = linux.dup2(slave, 1);
        _ = linux.dup2(slave, 2);
        if (slave > 2) _ = linux.close(slave);
        // 家目录不存在/没权限时退回 /，至少不要停在服务进程的 cwd 上。
        if (linux.errno(linux.chdir(home_z.ptr)) != .SUCCESS) {
            _ = linux.chdir("/");
        }
        _ = linux.execve(shell_z.ptr, @ptrCast(&argv), @ptrCast(&env.slots[0]));
        linux.exit(127);
    }

    // ---- 父进程 ----
    _ = linux.close(slave);
    return .{ .master = master, .child = @intCast(rc) };
}

/// 在 fork 前拼出 envp。
///
/// 规则：
///   - HOME/USER/LOGNAME/SHELL 按账号信息覆盖，避免继承到错误的 HOME；
///   - TERM/COLORTERM 固定成终端实际支持的值；
///   - /etc/environment 只补缺失的键（pam_env 的常见来源，登录 shell 不读它）；
///   - 其余变量原样继承。
const EnvBuilder = struct {
    gpa: std.mem.Allocator,
    slots: [env_capacity]?[*:0]const u8 = undefined,
    n: usize = 0,
    owned: std.ArrayList([:0]u8) = .empty,

    fn addRaw(self: *EnvBuilder, entry: [*:0]const u8) void {
        if (self.n + 4 >= self.slots.len) return;
        self.slots[self.n] = entry;
        self.n += 1;
    }

    fn addPair(self: *EnvBuilder, key: []const u8, value: []const u8) !void {
        const text = try std.fmt.allocPrintSentinel(self.gpa, "{s}={s}", .{ key, value }, 0);
        try self.owned.append(self.gpa, text);
        self.addRaw(text.ptr);
    }

    fn hasKey(self: *const EnvBuilder, key: []const u8) bool {
        for (self.slots[0..self.n]) |slot| {
            const text = std.mem.span(slot.?);
            const eq = std.mem.indexOfScalar(u8, text, '=') orelse continue;
            if (std.mem.eql(u8, text[0..eq], key)) return true;
        }
        return false;
    }

    fn deinit(self: *EnvBuilder) void {
        for (self.owned.items) |text| self.gpa.free(text);
        self.owned.deinit(self.gpa);
    }

    fn build(
        self: *EnvBuilder,
        io: Io,
        account: ?Account,
        home: []const u8,
        shell: []const u8,
        environ: std.process.Environ,
    ) !void {
        try self.addPair("HOME", home);
        if (account) |a| {
            try self.addPair("USER", a.user);
            try self.addPair("LOGNAME", a.user);
        }
        try self.addPair("SHELL", shell);

        const view = environ.block.view().slice;
        for (view) |entry| {
            const text = std.mem.span(entry);
            const eq = std.mem.indexOfScalar(u8, text, '=') orelse continue;
            const key = text[0..eq];
            if (isServerSecret(key) or
                std.mem.eql(u8, key, "HOME") or
                std.mem.eql(u8, key, "SHELL") or
                std.mem.eql(u8, key, "TERM") or
                std.mem.eql(u8, key, "COLORTERM") or
                (std.mem.eql(u8, key, "USER") and self.hasKey("USER")) or
                (std.mem.eql(u8, key, "LOGNAME") and self.hasKey("LOGNAME")))
            {
                continue;
            }
            self.addRaw(entry);
        }

        if (!self.hasKey("PATH")) try self.addPair("PATH", default_path);
        // 固定值必须先放进去，/etc/environment 才不会补出第二个 TERM/COLORTERM。
        try self.addPair("TERM", "xterm-256color");
        try self.addPair("COLORTERM", "truecolor");
        self.addEnvironmentFile(io) catch {};
        if (!self.hasKey("LANG") and !self.hasKey("LC_ALL")) try self.addPair("LANG", "C.UTF-8");
        self.slots[self.n] = null;
    }

    /// 补上 /etc/environment 里还没设置的变量；文件缺失/不可读时静默跳过。
    fn addEnvironmentFile(self: *EnvBuilder, io: Io) !void {
        const data = std.Io.Dir.cwd().readFileAlloc(io, "/etc/environment", self.gpa, .limited(64 * 1024)) catch return;
        defer self.gpa.free(data);
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |line| {
            const pair = parseEnvLine(line) orelse continue;
            if (isServerSecret(pair.key) or self.hasKey(pair.key)) continue;
            try self.addPair(pair.key, pair.value);
        }
    }
};

const Account = struct {
    home: [:0]u8,
    user: [:0]u8,

    fn deinit(self: Account, gpa: std.mem.Allocator) void {
        gpa.free(self.home);
        gpa.free(self.user);
    }
};

/// 用真实 uid 在 /etc/passwd 里找家目录和用户名。
fn resolveAccount(io: Io, gpa: std.mem.Allocator) !?Account {
    const uid: u32 = @intCast(linux.getuid());
    const data = std.Io.Dir.cwd().readFileAlloc(io, "/etc/passwd", gpa, .limited(512 * 1024)) catch return null;
    defer gpa.free(data);

    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        const hit = passwdEntry(line, uid) orelse continue;
        const home = try gpa.dupeSentinel(u8, hit.home, 0);
        errdefer gpa.free(home);
        const user = try gpa.dupeSentinel(u8, hit.user, 0);
        return .{ .home = home, .user = user };
    }
    return null;
}

const PasswdEntry = struct { home: []const u8, user: []const u8 };

fn passwdEntry(line_raw: []const u8, uid: u32) ?PasswdEntry {
    const line = std.mem.trimEnd(u8, line_raw, "\r");
    if (line.len == 0 or line[0] == '#') return null;
    var fields = std.mem.splitScalar(u8, line, ':');
    const name = fields.next() orelse return null;
    _ = fields.next() orelse return null; // password
    const uid_text = fields.next() orelse return null;
    _ = fields.next() orelse return null; // gid
    _ = fields.next() orelse return null; // gecos
    const home = fields.next() orelse return null;
    _ = fields.next() orelse return null; // shell
    const parsed = std.fmt.parseInt(u32, uid_text, 10) catch return null;
    if (parsed != uid or name.len == 0 or home.len == 0) return null;
    return .{ .home = home, .user = name };
}

/// 家目录优先级：可访问的 $HOME > passwd（当前 uid）> /。
///
/// 显式设置的 HOME 优先（便于测试/临时目录）；但守护进程常见的 HOME 缺失、
/// 或 sudo/su 留下的别人家目录不可用时，退回账号真正的家目录。
fn chooseHome(io: Io, gpa: std.mem.Allocator, account: ?Account, environ: std.process.Environ) ![:0]const u8 {
    const view = environ.block.view().slice;
    for (view) |entry| {
        const text = std.mem.span(entry);
        if (!std.mem.startsWith(u8, text, "HOME=")) continue;
        const value = text["HOME=".len..];
        if (value.len > 0 and value[0] == '/') {
            if (std.Io.Dir.accessAbsolute(io, value, .{ .execute = true })) |_| {
                return gpa.dupeSentinel(u8, value, 0);
            } else |_| {
                std.debug.print("HOME={s} 不可访问，改用账号家目录\n", .{value});
            }
        }
        break;
    }
    if (account) |a| return gpa.dupeSentinel(u8, a.home, 0);
    return gpa.dupeSentinel(u8, "/", 0);
}

const EnvPair = struct { key: []const u8, value: []const u8 };

fn parseEnvLine(line_raw: []const u8) ?EnvPair {
    const line = std.mem.trim(u8, line_raw, " \t\r");
    if (line.len == 0 or line[0] == '#') return null;
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    const key = std.mem.trim(u8, line[0..eq], " \t");
    var value = std.mem.trim(u8, line[eq + 1 ..], " \t");
    if (!isEnvName(key)) return null;
    if (value.len >= 2 and
        ((value[0] == '"' and value[value.len - 1] == '"') or
            (value[0] == '\'' and value[value.len - 1] == '\'')))
    {
        value = value[1 .. value.len - 1];
    }
    return .{ .key = key, .value = value };
}

/// 服务端自己的凭据不能出现在用户 shell 的环境里；否则 `env` 或任何子进程
/// 都能直接读到登录密码。配置文件路径等非机密变量仍可继承。
fn isServerSecret(key: []const u8) bool {
    return std.mem.eql(u8, key, "MYTTY_PASSWORD");
}

fn isEnvName(key: []const u8) bool {
    if (key.len == 0) return false;
    if (!std.ascii.isAlphabetic(key[0]) and key[0] != '_') return false;
    for (key[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

pub fn resize(master: posix.fd_t, cols: u16, rows: u16) void {
    var ws: winsize = .{
        .row = rows,
        .col = cols,
        .xpixel = 0,
        .ypixel = 0,
    };
    _ = linux.ioctl(master, linux.T.IOCSWINSZ, @intFromPtr(&ws));
}

/// 向 PTY 写入全部数据；主端是非阻塞的，队列满时最多等 10 秒。
/// 一个不读 stdin 的前台程序不能把连接线程/会话永久钉住。
pub fn writeAll(master: posix.fd_t, data: []const u8) !void {
    var fds = [_]posix.pollfd{.{ .fd = master, .events = posix.POLL.OUT, .revents = 0 }};
    var i: usize = 0;
    while (i < data.len) {
        const rc = linux.write(master, data[i..].ptr, data.len - i);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return error.WriteZero;
                i += rc;
            },
            .INTR => continue,
            .AGAIN => {
                fds[0].revents = 0;
                const ready = posix.poll(&fds, 10_000) catch return error.WriteFailed;
                if (ready == 0) return error.WriteTimeout;
                if (fds[0].revents & (posix.POLL.OUT | posix.POLL.ERR | posix.POLL.HUP) == 0)
                    return error.WriteFailed;
            },
            else => return error.WriteFailed,
        }
    }
}

/// 回收 shell，避免僵尸进程。优先 HUP（终端挂断语义），再等待；
/// 如果 shell 忽略 HUP/TERM，300ms 后 SIGKILL，避免销毁会话时永久卡住。
pub fn reap(child: posix.pid_t) void {
    _ = linux.kill(child, .HUP);
    _ = linux.kill(child, .TERM);

    var status: i32 = 0;
    var i: u8 = 0;
    while (i < 30) : (i += 1) {
        const rc = linux.waitpid(child, &status, posix.W.NOHANG);
        switch (linux.errno(rc)) {
            .SUCCESS => if (rc != 0) return,
            .CHILD => return,
            else => {},
        }
        const tick: linux.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
        _ = linux.nanosleep(&tick, null);
    }

    _ = linux.kill(-child, .KILL);
    _ = linux.kill(child, .KILL);
    _ = linux.waitpid(child, &status, 0);
}

test "env builder overrides identity and terminal variables" {
    var env = EnvBuilder{ .gpa = std.testing.allocator };
    defer env.deinit();

    // 手工构造一个 HOME 不对、TERM 也不对的环境。
    const fake = [_]?[*:0]const u8{ "TERM=dumb", "HOME=/wrong", "PATH=/bin", "CUSTOM=keep", "MYTTY_PASSWORD=secret", null };
    const block: std.process.Environ.Block = .{ .slice = fake[0..5 :null] };
    const environ: std.process.Environ = .{ .block = block };

    try env.build(std.testing.io, null, "/home/tester", "/bin/bash", environ);

    var saw_home = false;
    var saw_custom = false;
    var saw_term = false;
    var saw_colorterm = false;
    var saw_shell = false;
    var n: usize = 0;
    while (env.slots[n] != null) : (n += 1) {
        const text = std.mem.span(env.slots[n].?);
        if (std.mem.eql(u8, text, "HOME=/home/tester")) saw_home = true;
        if (std.mem.eql(u8, text, "SHELL=/bin/bash")) saw_shell = true;
        if (std.mem.eql(u8, text, "CUSTOM=keep")) saw_custom = true;
        if (std.mem.eql(u8, text, "TERM=xterm-256color")) saw_term = true;
        if (std.mem.eql(u8, text, "COLORTERM=truecolor")) saw_colorterm = true;
        try std.testing.expect(!std.mem.eql(u8, text, "HOME=/wrong"));
        try std.testing.expect(!std.mem.eql(u8, text, "TERM=dumb"));
        try std.testing.expect(!std.mem.startsWith(u8, text, "MYTTY_PASSWORD="));
    }
    try std.testing.expect(saw_home and saw_shell and saw_custom and saw_term and saw_colorterm);
}

test "passwd entry is matched by uid" {
    const line = "alice:x:1000:1000:Alice:/home/alice:/bin/bash";
    const hit = passwdEntry(line, 1000).?;
    try std.testing.expectEqualStrings("/home/alice", hit.home);
    try std.testing.expectEqualStrings("alice", hit.user);
    try std.testing.expect(passwdEntry(line, 0) == null);
    try std.testing.expect(passwdEntry("bad:line", 1000) == null);
    try std.testing.expect(passwdEntry("# comment", 1000) == null);
}

test "environment file lines" {
    const quoted = parseEnvLine("PATH=\"/usr/bin:/bin\"").?;
    try std.testing.expectEqualStrings("PATH", quoted.key);
    try std.testing.expectEqualStrings("/usr/bin:/bin", quoted.value);

    const spaced = parseEnvLine("  EDITOR = vim  ").?;
    try std.testing.expectEqualStrings("EDITOR", spaced.key);
    try std.testing.expectEqualStrings("vim", spaced.value);

    try std.testing.expect(parseEnvLine("# comment") == null);
    try std.testing.expect(parseEnvLine("not a pair") == null);
    try std.testing.expect(parseEnvLine("1BAD=x") == null);
}
