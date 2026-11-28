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

pub fn makeDir(io: Io, arena: Allocator, request: *http.Server.Request) !void {
    const rel = paths.normalized(arena, try query.param(arena, request, "path")) catch
        return respond.fail(request, arena, .bad_request, "invalid_path");
    if (rel.len == 0) return respond.fail(request, arena, .bad_request, "invalid_path");
    const abs = paths.joinAbs(arena, "/", rel) catch |err| return respond.failMapped(request, arena, err);

    Dir.cwd().createDirPath(io, abs) catch |err| return respond.failMapped(request, arena, err);

    var pb: [256]u8 = undefined;
    std.debug.print("新建目录 /{s}\n", .{util.logText(&pb, rel)});

    const Payload = struct { ok: bool };
    return respond.respondJson(request, arena, .ok, Payload{ .ok = true });
}

pub fn rename(io: Io, arena: Allocator, request: *http.Server.Request) !void {
    const from_rel = paths.normalized(arena, try query.param(arena, request, "from")) catch
        return respond.fail(request, arena, .bad_request, "invalid_path");
    const to_rel = paths.normalized(arena, try query.param(arena, request, "to")) catch
        return respond.fail(request, arena, .bad_request, "invalid_path");
    if (from_rel.len == 0 or to_rel.len == 0) return respond.fail(request, arena, .bad_request, "invalid_path");
    const overwrite = std.mem.eql(u8, try query.param(arena, request, "overwrite"), "1");

    const from_abs = paths.resolveLeaf(io, arena, from_rel) catch |err| return respond.failMapped(request, arena, err);
    const to_abs = paths.resolveNew(io, arena, to_rel) catch |err| return respond.failMapped(request, arena, err);
    if (std.mem.eql(u8, from_abs, "/")) return respond.fail(request, arena, .forbidden, "cannot_move_root");

    if (overwrite) {
        Dir.rename(.cwd(), from_abs, .cwd(), to_abs, io) catch |err| return respond.failMapped(request, arena, err);
    } else {
        Dir.renamePreserve(.cwd(), from_abs, .cwd(), to_abs, io) catch |err| return switch (err) {
            error.PathAlreadyExists => respond.fail(request, arena, .conflict, "already_exists"),
            else => respond.failMapped(request, arena, err),
        };
    }

    var fb: [256]u8 = undefined;
    var tb: [256]u8 = undefined;
    std.debug.print("重命名 /{s} -> /{s}\n", .{ util.logText(&fb, from_rel), util.logText(&tb, to_rel) });

    const Payload = struct { ok: bool };
    return respond.respondJson(request, arena, .ok, Payload{ .ok = true });
}

pub fn delete(io: Io, arena: Allocator, request: *http.Server.Request) !void {
    const rel = paths.normalized(arena, try query.param(arena, request, "path")) catch
        return respond.fail(request, arena, .bad_request, "invalid_path");
    if (rel.len == 0) return respond.fail(request, arena, .bad_request, "invalid_path");
    const abs = paths.resolveLeaf(io, arena, rel) catch |err| return respond.failMapped(request, arena, err);
    if (std.mem.eql(u8, abs, "/")) return respond.fail(request, arena, .forbidden, "cannot_delete_root");

    const st = Dir.cwd().statFile(io, abs, .{ .follow_symlinks = false }) catch |err|
        return respond.failMapped(request, arena, err);
    if (st.kind == .directory) {
        Dir.cwd().deleteTree(io, abs) catch |err| return respond.failMapped(request, arena, err);
    } else {
        Dir.cwd().deleteFile(io, abs) catch |err| return respond.failMapped(request, arena, err);
    }

    var pb: [256]u8 = undefined;
    std.debug.print("删除 /{s}\n", .{util.logText(&pb, rel)});

    const Payload = struct { ok: bool };
    return respond.respondJson(request, arena, .ok, Payload{ .ok = true });
}
