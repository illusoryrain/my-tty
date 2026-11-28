const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const Io = std.Io;

/// 结束 shell 所在的进程组；-pid 失败时再单独杀直接子进程，并回收僵尸。
pub fn killChild(child: posix.pid_t) void {
    _ = linux.kill(-child, .KILL);
    _ = linux.kill(child, .KILL);
    var status: i32 = 0;
    _ = linux.waitpid(child, &status, 0);
}

/// 杀掉同一 session（sid == shell pid）里的所有进程，包括 job control 拆出去的
/// 后台作业。只读 /proc/<pid>/stat 的第 6 个字段，Linux 专用。
pub fn killSessionProcesses(io: Io, sid: posix.pid_t) void {
    var proc = std.Io.Dir.openDirAbsolute(io, "/proc", .{ .iterate = true }) catch return;
    defer proc.close(io);

    var it = proc.iterate();
    while (it.next(io) catch return) |entry| {
        const pid = std.fmt.parseInt(posix.pid_t, entry.name, 10) catch continue;
        if (pid <= 1 or pid == sid) continue;

        var path_buf: [std.fs.max_name_bytes + 16]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/proc/{s}/stat", .{entry.name}) catch continue;
        const fd = posix.openat(posix.AT.FDCWD, path, .{
            .ACCMODE = .RDONLY,
            .CLOEXEC = true,
        }, 0) catch continue;
        defer _ = linux.close(fd);

        var buf: [512]u8 = undefined;
        // 进程可能在 readdir 和 open/read 之间退出；直接用原始系统调用并把
        // ESRCH 当成“已经没了”，避免 std.Io 把 /proc 的竞态当成 programmer bug。
        const rc = linux.read(fd, &buf, buf.len);
        const n: usize = switch (linux.errno(rc)) {
            .SUCCESS => rc,
            else => continue,
        };
        if (n == 0) continue;
        const data = buf[0..n];

        // "pid (comm) state ppid pgrp session ..."；comm 里可能有空格/括号。
        const rparen = std.mem.lastIndexOfScalar(u8, data, ')') orelse continue;
        var fields = std.mem.tokenizeScalar(u8, data[rparen + 1 ..], ' ');
        _ = fields.next() orelse continue; // state
        _ = fields.next() orelse continue; // ppid
        _ = fields.next() orelse continue; // pgrp
        const session_text = fields.next() orelse continue;
        const session = std.fmt.parseInt(posix.pid_t, session_text, 10) catch continue;
        if (session == sid) _ = linux.kill(pid, .KILL);
    }
}
