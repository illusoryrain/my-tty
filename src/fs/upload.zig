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

pub fn uploadSingle(io: Io, arena: Allocator, rel: []const u8, request: *http.Server.Request) !void {
    if (rel.len == 0) return respond.fail(request, arena, .bad_request, "invalid_path");
    if (!util.requestDeclaresBody(request))
        return respond.fail(request, arena, .length_required, "length_required");
    if (request.head.content_length) |len| {
        if (len > limits.max_upload) return respond.failClose(request, arena, .payload_too_large, "upload_too_large");
    }

    const abs = paths.resolveWriteTarget(io, arena, rel) catch |err| return respond.failMapped(request, arena, err);
    try metadata.ensureRegularOrMissing(io, arena, request, abs);
    const meta = metadata.existingMeta(io, arena, abs) catch |err| switch (err) {
        error.MetadataUnsafe => return respond.fail(request, arena, .conflict, "metadata_unsafe"),
        else => return respond.failMapped(request, arena, err),
    };
    var staged = metadata.stageWrite(io, abs, meta, true) catch |err|
        return respond.failMapped(request, arena, err);
    defer staged.atomic.deinit(io);

    var head_buf: [16 * 1024]u8 = undefined;
    const body_reader = request.readerExpectContinue(&head_buf) catch
        return respond.fail(request, arena, .bad_request, "bad_body");

    var chunk: [64 * 1024]u8 = undefined;
    var total: u64 = 0;
    while (true) {
        const n = body_reader.readSliceShort(&chunk) catch |err| return respond.failMapped(request, arena, err);
        if (n == 0) break;
        total += n;
        if (total > limits.max_upload) return respond.failClose(request, arena, .payload_too_large, "upload_too_large");
        staged.atomic.file.writeStreamingAll(io, chunk[0..n]) catch |err| return respond.failMapped(request, arena, err);
    }

    if (!util.bodyComplete(request)) return respond.failClose(request, arena, .bad_request, "bad_body");
    metadata.finishStaged(&staged, io, meta) catch |err| switch (err) {
        error.MetadataUnsafe => return respond.fail(request, arena, .conflict, "metadata_unsafe"),
        else => return respond.failMapped(request, arena, err),
    };
    staged.atomic.replace(io) catch |err| return respond.failMapped(request, arena, err);

    var pb: [256]u8 = undefined;
    std.debug.print("上传 /{s} ({d} B)\n", .{ util.logText(&pb, rel), total });

    const Payload = struct { ok: bool, done: bool, path: []const u8, offset: u64 };
    return respond.respondJson(request, arena, .ok, Payload{ .ok = true, .done = true, .path = rel, .offset = total });
}
