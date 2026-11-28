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

/// `base` 为空表示调用方不做冲突检查（curl/新建文件）。目标不存在或超过
/// limits.max_read 时无法证明内容一致，按冲突处理；权限/目录等真实错误向上抛，
/// 由 HTTP 层返回对应状态，不要伪装成“文件已被修改”。
fn baseMatches(io: Io, arena: Allocator, abs: []const u8, base: []const u8) !bool {
    if (base.len == 0) return true;
    const current = Dir.cwd().readFileAlloc(io, abs, arena, .limited(limits.max_read + 1)) catch |err| switch (err) {
        error.FileNotFound, error.StreamTooLong => return false,
        else => return err,
    };
    const version = util.contentVersion(current);
    return std.mem.eql(u8, &version, base);
}

pub fn write(io: Io, gpa: Allocator, arena: Allocator, request: *http.Server.Request) !void {
    const rel = paths.normalized(arena, try query.param(arena, request, "path")) catch
        return respond.fail(request, arena, .bad_request, "invalid_path");
    if (rel.len == 0) return respond.fail(request, arena, .bad_request, "invalid_path");
    // 读 body 之后 request.head（含 target）就失效了，所有 query 参数必须先取出来。
    const base = try query.param(arena, request, "base");
    const exclusive = std.mem.eql(u8, try query.param(arena, request, "exclusive"), "1");
    if (!util.requestDeclaresBody(request))
        return respond.fail(request, arena, .length_required, "length_required");

    if (request.head.content_length) |len| {
        if (len > limits.max_write) return respond.failClose(request, arena, .payload_too_large, "body_too_large");
    }

    var body_buf: [4096]u8 = undefined;
    const body_reader = request.readerExpectContinue(&body_buf) catch return respond.fail(request, arena, .bad_request, "bad_body");
    const body = body_reader.allocRemaining(gpa, .limited(limits.max_write)) catch |err| switch (err) {
        error.StreamTooLong => return respond.failClose(request, arena, .payload_too_large, "body_too_large"),
        else => return respond.failClose(request, arena, .bad_request, "bad_body"),
    };
    defer gpa.free(body);
    // 客户端可能在 Content-Length 之前就断开；不能把半截内容写进目标文件。
    if (!util.bodyComplete(request)) return respond.failClose(request, arena, .bad_request, "bad_body");

    const abs = paths.resolveWriteTarget(io, arena, rel) catch |err| return respond.failMapped(request, arena, err);
    try metadata.ensureRegularOrMissing(io, arena, request, abs);

    const base_ok = baseMatches(io, arena, abs, base) catch |err| return respond.failMapped(request, arena, err);
    if (!base_ok) return respond.fail(request, arena, .conflict, "modified_on_disk");

    const meta = if (exclusive) null else metadata.existingMeta(io, arena, abs) catch |err| switch (err) {
        error.MetadataUnsafe => return respond.fail(request, arena, .conflict, "metadata_unsafe"),
        else => return respond.failMapped(request, arena, err),
    };
    var staged = metadata.stageWrite(io, abs, meta, !exclusive) catch |err|
        return respond.failMapped(request, arena, err);
    defer staged.atomic.deinit(io);
    staged.atomic.file.writeStreamingAll(io, body) catch |err| return respond.failMapped(request, arena, err);
    metadata.finishStaged(&staged, io, meta) catch |err| switch (err) {
        error.MetadataUnsafe => return respond.fail(request, arena, .conflict, "metadata_unsafe"),
        else => return respond.failMapped(request, arena, err),
    };
    if (exclusive) {
        staged.atomic.link(io) catch |err| return respond.failMapped(request, arena, err);
    } else {
        staged.atomic.replace(io) catch |err| return respond.failMapped(request, arena, err);
    }

    var pb: [256]u8 = undefined;
    std.debug.print("写入 /{s} ({d} B)\n", .{ util.logText(&pb, rel), body.len });

    const Payload = struct { ok: bool, path: []const u8, size: usize, version: []const u8 };
    const version = util.contentVersion(body);
    return respond.respondJson(request, arena, .ok, Payload{
        .ok = true,
        .path = rel,
        .size = body.len,
        .version = &version,
    });
}
