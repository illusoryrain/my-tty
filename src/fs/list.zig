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

const Entry = struct {
    name: []const u8,
    kind: []const u8,
    size: u64,
};
pub fn list(io: Io, arena: Allocator, request: *http.Server.Request) !void {
    const rel = paths.normalized(arena, try query.param(arena, request, "path")) catch
        return respond.fail(request, arena, .bad_request, "invalid_path");
    const abs = paths.resolveExisting(io, arena, rel) catch |err| return respond.failMapped(request, arena, err);

    var dir = Dir.cwd().openDir(io, abs, .{ .iterate = true, .follow_symlinks = false }) catch |err|
        return respond.failMapped(request, arena, err);
    defer dir.close(io);

    var entries: std.ArrayList(Entry) = .empty;
    var truncated = false;
    var it = dir.iterate();
    while (it.next(io) catch |err| return respond.failMapped(request, arena, err)) |entry| {
        // 目录可能非常大；先截断再排序，避免一次请求吃光内存。
        if (entries.items.len >= limits.max_list_entries) {
            truncated = true;
            break;
        }
        // 前端用 JSON 字符串展示/操作文件名；非 UTF-8 名字会被 JSON 编码成
        // 数字数组，可能被字符串化成另一个路径。直接跳过，避免误操作别的文件。
        if (!std.unicode.utf8ValidateSlice(entry.name)) {
            truncated = true;
            continue;
        }
        const name = arena.dupe(u8, entry.name) catch return respond.fail(request, arena, .internal_server_error, "out_of_memory");
        // 列表按链接指向的类型展示：指向文件的链接可以编辑，指向目录的可以展开。
        var kind = entry.kind;
        var size: u64 = 0;
        if (entry.kind == .sym_link) {
            if (dir.statFile(io, entry.name, .{ .follow_symlinks = true })) |st| {
                kind = st.kind;
                if (kind == .file) size = st.size;
            } else |_| {}
        } else if (entry.kind == .file) {
            if (dir.statFile(io, entry.name, .{ .follow_symlinks = false })) |st| size = st.size else |_| {}
        }
        entries.append(arena, .{
            .name = name,
            .kind = @tagName(kind),
            .size = size,
        }) catch return respond.fail(request, arena, .internal_server_error, "out_of_memory");
    }

    std.mem.sort(Entry, entries.items, {}, entryLessThan);

    const Payload = struct { path: []const u8, entries: []const Entry, truncated: bool };
    return respond.respondJson(request, arena, .ok, Payload{
        .path = rel,
        .entries = entries.items,
        .truncated = truncated,
    });
}
fn entryLessThan(_: void, a: Entry, b: Entry) bool {
    const a_dir = std.mem.eql(u8, a.kind, "directory");
    const b_dir = std.mem.eql(u8, b.kind, "directory");
    if (a_dir != b_dir) return a_dir;
    return std.mem.lessThan(u8, a.name, b.name);
}
