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

pub fn download(io: Io, arena: Allocator, request: *http.Server.Request) !void {
    const rel = paths.normalized(arena, try query.param(arena, request, "path")) catch
        return respond.fail(request, arena, .bad_request, "invalid_path");
    if (rel.len == 0) return respond.fail(request, arena, .bad_request, "invalid_path");

    const abs = paths.resolveExisting(io, arena, rel) catch |err| return respond.failMapped(request, arena, err);
    const st = Dir.cwd().statFile(io, abs, .{ .follow_symlinks = false }) catch |err|
        return respond.failMapped(request, arena, err);
    if (st.kind != .file) return respond.fail(request, arena, .bad_request, "not_a_file");

    var file = Dir.cwd().openFile(io, abs, .{ .mode = .read_only, .follow_symlinks = false }) catch |err|
        return respond.failMapped(request, arena, err);
    defer file.close(io);

    const name = paths.basename(rel);
    var disposition_buf: [paths.max_disposition_bytes]u8 = undefined;
    const disposition = paths.contentDisposition(&disposition_buf, name);

    var headers = [_]http.Header{
        .{ .name = "content-type", .value = "application/octet-stream" },
        .{ .name = "content-disposition", .value = disposition },
        .{ .name = "cache-control", .value = "no-store" },
        .{ .name = "x-content-type-options", .value = "nosniff" },
    };

    var stream_buf: [64 * 1024]u8 = undefined;
    var body = try request.respondStreaming(&stream_buf, .{
        .content_length = st.size,
        .respond_options = .{
            .extra_headers = &headers,
            .keep_alive = respond.keepAliveForRequest(request),
        },
    });

    var file_buf: [64 * 1024]u8 = undefined;
    var file_reader = file.reader(io, &file_buf);
    // 必须按 stat 得到的长度发送，否则文件在传输期间变长会多发字节、破坏
    // Content-Length 和 keep-alive 的帧边界。
    file_reader.interface.streamExact64(&body.writer, st.size) catch |err| return err;
    return body.end();
}
