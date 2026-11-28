const std = @import("std");
const http = std.http;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const util = @import("../util.zig");
const respond = @import("respond.zig");
const list = @import("list.zig");
const read = @import("read.zig");
const write = @import("write.zig");
const ops = @import("ops.zig");
const upload = @import("upload.zig");
const archive = @import("archive.zig");
const download = @import("download.zig");
const paths = @import("paths.zig");
const query = @import("query.zig");

pub fn handle(io: Io, gpa: Allocator, request: *http.Server.Request) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    return handleRequest(io, gpa, arena, request) catch |err| switch (err) {
        error.InvalidEncoding => respond.fail(request, arena, .bad_request, "invalid_query"),
        error.OutOfMemory => respond.fail(request, arena, .internal_server_error, "out_of_memory"),
        else => return err,
    };
}

fn handleRequest(io: Io, gpa: Allocator, arena: Allocator, request: *http.Server.Request) !void {
    const target = request.head.target;
    const path = util.pathOnly(target);

    if (std.mem.eql(u8, path, "/api/fs/list")) {
        if (request.head.method != .GET) return respond.fail(request, arena, .method_not_allowed, "method_not_allowed");
        return list.list(io, arena, request);
    }
    if (std.mem.eql(u8, path, "/api/fs/read")) {
        if (request.head.method != .GET) return respond.fail(request, arena, .method_not_allowed, "method_not_allowed");
        return read.read(io, arena, request);
    }
    if (std.mem.eql(u8, path, "/api/fs/write")) {
        if (request.head.method != .PUT) return respond.fail(request, arena, .method_not_allowed, "method_not_allowed");
        return write.write(io, gpa, arena, request);
    }
    if (std.mem.eql(u8, path, "/api/fs/mkdir")) {
        if (request.head.method != .POST) return respond.fail(request, arena, .method_not_allowed, "method_not_allowed");
        return ops.makeDir(io, arena, request);
    }
    if (std.mem.eql(u8, path, "/api/fs/rename")) {
        if (request.head.method != .POST) return respond.fail(request, arena, .method_not_allowed, "method_not_allowed");
        return ops.rename(io, arena, request);
    }
    if (std.mem.eql(u8, path, "/api/fs/delete")) {
        if (request.head.method != .DELETE) return respond.fail(request, arena, .method_not_allowed, "method_not_allowed");
        return ops.delete(io, arena, request);
    }
    if (std.mem.eql(u8, path, "/api/fs/upload")) {
        if (request.head.method != .PUT)
            return respond.fail(request, arena, .method_not_allowed, "method_not_allowed");
        return upload.uploadSingle(io, arena, paths.normalized(arena, try query.param(arena, request, "path")) catch
            return respond.fail(request, arena, .bad_request, "invalid_path"), request);
    }
    if (std.mem.eql(u8, path, "/api/fs/archive")) {
        if (request.head.method != .GET) return respond.fail(request, arena, .method_not_allowed, "method_not_allowed");
        return archive.archive(io, arena, request);
    }
    if (std.mem.eql(u8, path, "/api/fs/download")) {
        if (request.head.method != .GET) return respond.fail(request, arena, .method_not_allowed, "method_not_allowed");
        return download.download(io, arena, request);
    }
    return respond.fail(request, arena, .not_found, "not_found");
}
