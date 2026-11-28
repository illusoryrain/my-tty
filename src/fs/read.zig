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

pub fn read(io: Io, arena: Allocator, request: *http.Server.Request) !void {
    const rel = paths.normalized(arena, try query.param(arena, request, "path")) catch
        return respond.fail(request, arena, .bad_request, "invalid_path");
    if (rel.len == 0) return respond.fail(request, arena, .bad_request, "invalid_path");
    const abs = paths.resolveExisting(io, arena, rel) catch |err| return respond.failMapped(request, arena, err);

    const st = Dir.cwd().statFile(io, abs, .{ .follow_symlinks = false }) catch |err|
        return respond.failMapped(request, arena, err);
    if (st.kind != .file) return respond.fail(request, arena, .bad_request, "not_a_file");
    if (st.size > limits.max_read) return respond.fail(request, arena, .payload_too_large, "file_too_large");

    // .limited(N) 在恰好 N 字节时也会报 StreamTooLong，所以留 1 字节余量；
    // 超过 limits.max_read 的真实文件仍然拒绝。
    const bytes = Dir.cwd().readFileAlloc(io, abs, arena, .limited(limits.max_read + 1)) catch |err| switch (err) {
        error.StreamTooLong => return respond.fail(request, arena, .payload_too_large, "file_too_large"),
        else => return respond.failMapped(request, arena, err),
    };
    if (std.mem.indexOfScalar(u8, bytes, 0) != null or !std.unicode.utf8ValidateSlice(bytes))
        return respond.fail(request, arena, .unsupported_media_type, "binary_file");

    const Payload = struct { path: []const u8, content: []const u8, size: u64, version: []const u8 };
    const version = util.contentVersion(bytes);
    return respond.respondJson(request, arena, .ok, Payload{
        .path = rel,
        .content = bytes,
        .size = st.size,
        .version = &version,
    });
}
