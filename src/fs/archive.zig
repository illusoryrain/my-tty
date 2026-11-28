const std = @import("std");
const http = std.http;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const linux = std.os.linux;
const posix = std.posix;
const util = @import("../util.zig");
const limits = @import("limits.zig");
const paths = @import("paths.zig");
const respond = @import("respond.zig");
const metadata = @import("metadata.zig");
const query = @import("query.zig");

pub fn archive(io: Io, arena: Allocator, request: *http.Server.Request) !void {
    const rel = paths.normalized(arena, try query.param(arena, request, "path")) catch
        return respond.fail(request, arena, .bad_request, "invalid_path");
    const abs = paths.resolveExisting(io, arena, rel) catch |err| return respond.failMapped(request, arena, err);
    const st = Dir.cwd().statFile(io, abs, .{ .follow_symlinks = false }) catch |err|
        return respond.failMapped(request, arena, err);
    if (st.kind != .directory) return respond.fail(request, arena, .bad_request, "not_a_directory");

    const base = paths.basename(rel);
    const root_name = if (base.len == 0) "root" else base;

    var name_buf: [512]u8 = undefined;
    const tar_name = std.fmt.bufPrint(&name_buf, "{s}.tar", .{root_name}) catch "archive.tar";
    var disposition_buf: [paths.max_disposition_bytes]u8 = undefined;
    const disposition = paths.contentDisposition(&disposition_buf, tar_name);

    var headers = [_]http.Header{
        .{ .name = "content-type", .value = "application/x-tar" },
        .{ .name = "content-disposition", .value = disposition },
        .{ .name = "cache-control", .value = "no-store" },
        .{ .name = "x-content-type-options", .value = "nosniff" },
    };

    var stream_buf: [64 * 1024]u8 = undefined;
    var body = try request.respondStreaming(&stream_buf, .{
        .respond_options = .{
            .extra_headers = &headers,
            .keep_alive = respond.keepAliveForRequest(request),
        },
    });

    var tw: std.tar.Writer = .{ .underlying_writer = &body.writer };
    tw.setRoot(root_name) catch return error.WriteFailed;
    var state: TarState = .{};
    try walkTar(io, arena, &tw, &state, abs, "", 0);
    if (state.truncated) {
        // 不能中途直接断流（客户端会当成损坏的 tar）；写完截止点再补一个说明文件。
        tw.writeFileBytes(
            "MY-TTY-TRUNCATED.txt",
            "归档内容超过服务端上限，已截断。请改为下载子目录，或单独下载文件。\n" ++
                "本文件由 my-tty 自动生成。\n",
            .{},
        ) catch return error.WriteFailed;
    }
    tw.finishPedantically() catch return error.WriteFailed;
    return body.end();
}

const TarState = struct {
    entries: usize = 0,
    bytes: u64 = 0,
    truncated: bool = false,
};

fn walkTar(
    io: Io,
    alloc: Allocator,
    tw: *std.tar.Writer,
    state: *TarState,
    dir_abs: []const u8,
    prefix: []const u8,
    depth: u32,
) !void {
    if (state.truncated) return;
    if (depth > 64) {
        state.truncated = true;
        return;
    }

    var dir = Dir.cwd().openDir(io, dir_abs, .{ .iterate = true, .follow_symlinks = false }) catch return;
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch return) |entry| {
        if (state.truncated) return;
        if (state.entries >= limits.max_tar_entries) {
            state.truncated = true;
            return;
        }

        const sub = if (prefix.len == 0)
            try alloc.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(alloc, "{s}/{s}", .{ prefix, entry.name });

        switch (entry.kind) {
            .directory => {
                state.entries += 1;
                tw.writeDir(sub, .{}) catch return error.WriteFailed;
                const child_abs = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir_abs, entry.name });
                try walkTar(io, alloc, tw, state, child_abs, sub, depth + 1);
            },
            .file => {
                var file = dir.openFile(io, entry.name, .{ .follow_symlinks = false }) catch continue;
                defer file.close(io);
                const st = file.stat(io) catch continue;
                // 流式 tar 的头部要预先写长度，不能一边超限一边回头改。
                // tar 的八进制 size 字段最大只能表示 limits.max_tar_bytes - 1。
                if (st.size > limits.max_tar_bytes - 1 - state.bytes) {
                    state.truncated = true;
                    return;
                }
                state.entries += 1;
                state.bytes += st.size;
                var buf: [64 * 1024]u8 = undefined;
                var fr = file.reader(io, &buf);
                // 这里一旦开始写 tar 头，读失败就不能再 continue：否则后续
                // 内容会错位，finish/end 甚至可能触发 unreachable。直接让
                // 连接关闭，客户端看到的是截断的 HTTP 响应而不是损坏的 tar。
                tw.writeFileStream(sub, st.size, &fr.interface, .{}) catch return error.WriteFailed;
            },
            else => {},
        }
    }
}
