//! 文件系统 API：列目录、读、写、建目录、重命名、删除。
//!
//! 所有路径参数都是相对 `/` 的 POSIX 路径：拒绝绝对路径和 `..` 是为了 API
//! 语义明确，符号链接可以指向任意位置。delete/rename 只解析父目录，操作
//! 符号链接本身而不是它指向的目标。
//!
//! 只处理文本：读取上限 1 MiB，含 NUL 或非 UTF-8 视为二进制拒绝。

const std = @import("std");
const http = std.http;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const linux = std.os.linux;
const posix = std.posix;
const util = @import("util.zig");

pub const max_read: usize = 1024 * 1024;
pub const max_write: usize = 1024 * 1024;
pub const max_upload: usize = 64 * 1024 * 1024;

/// 单次 list 最多返回的条目数；超出时截断并标记 `truncated`。
pub const max_list_entries: usize = 10_000;
/// 目录归档的条目/字节上限；超出时停止追加并写入说明文件。
pub const max_tar_entries: usize = 50_000;
pub const max_tar_bytes: u64 = 8 * 1024 * 1024 * 1024;

const Entry = struct {
    name: []const u8,
    kind: []const u8,
    size: u64,
};

pub fn handle(io: Io, gpa: Allocator, request: *http.Server.Request) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    return handleRequest(io, gpa, arena, request) catch |err| switch (err) {
        error.InvalidEncoding => fail(request, arena, .bad_request, "invalid_query"),
        error.OutOfMemory => fail(request, arena, .internal_server_error, "out_of_memory"),
        else => return err,
    };
}

fn handleRequest(io: Io, gpa: Allocator, arena: Allocator, request: *http.Server.Request) !void {
    const target = request.head.target;
    const path = util.pathOnly(target);

    if (std.mem.eql(u8, path, "/api/fs/list")) {
        if (request.head.method != .GET) return fail(request, arena, .method_not_allowed, "method_not_allowed");
        return list(io, arena, request);
    }
    if (std.mem.eql(u8, path, "/api/fs/read")) {
        if (request.head.method != .GET) return fail(request, arena, .method_not_allowed, "method_not_allowed");
        return read(io, arena, request);
    }
    if (std.mem.eql(u8, path, "/api/fs/write")) {
        if (request.head.method != .PUT) return fail(request, arena, .method_not_allowed, "method_not_allowed");
        return write(io, gpa, arena, request);
    }
    if (std.mem.eql(u8, path, "/api/fs/mkdir")) {
        if (request.head.method != .POST) return fail(request, arena, .method_not_allowed, "method_not_allowed");
        return makeDir(io, arena, request);
    }
    if (std.mem.eql(u8, path, "/api/fs/rename")) {
        if (request.head.method != .POST) return fail(request, arena, .method_not_allowed, "method_not_allowed");
        return rename(io, arena, request);
    }
    if (std.mem.eql(u8, path, "/api/fs/delete")) {
        if (request.head.method != .DELETE) return fail(request, arena, .method_not_allowed, "method_not_allowed");
        return delete(io, arena, request);
    }
    if (std.mem.eql(u8, path, "/api/fs/upload")) {
        if (request.head.method != .PUT)
            return fail(request, arena, .method_not_allowed, "method_not_allowed");
        return uploadSingle(io, arena, normalized(arena, try param(arena, request, "path")) catch
            return fail(request, arena, .bad_request, "invalid_path"), request);
    }
    if (std.mem.eql(u8, path, "/api/fs/archive")) {
        if (request.head.method != .GET) return fail(request, arena, .method_not_allowed, "method_not_allowed");
        return archive(io, arena, request);
    }
    if (std.mem.eql(u8, path, "/api/fs/download")) {
        if (request.head.method != .GET) return fail(request, arena, .method_not_allowed, "method_not_allowed");
        return download(io, arena, request);
    }
    return fail(request, arena, .not_found, "not_found");
}

/// 取 query 参数并按 urlencoded 解码（`+` = 空格，`%XX`）。编码非法时按空串处理，
/// 由各接口返回 invalid_path / invalid_id 之类的参数错误。
fn param(arena: Allocator, request: *http.Server.Request, key: []const u8) util.DecodeError![]const u8 {
    return (try util.queryParamDecoded(arena, request.head.target, key)) orelse "";
}

fn list(io: Io, arena: Allocator, request: *http.Server.Request) !void {
    const rel = normalized(arena, try param(arena, request, "path")) catch
        return fail(request, arena, .bad_request, "invalid_path");
    const abs = resolveExisting(io, arena, rel) catch |err| return failMapped(request, arena, err);

    var dir = Dir.cwd().openDir(io, abs, .{ .iterate = true, .follow_symlinks = false }) catch |err|
        return failMapped(request, arena, err);
    defer dir.close(io);

    var entries: std.ArrayList(Entry) = .empty;
    var truncated = false;
    var it = dir.iterate();
    while (it.next(io) catch |err| return failMapped(request, arena, err)) |entry| {
        // 目录可能非常大；先截断再排序，避免一次请求吃光内存。
        if (entries.items.len >= max_list_entries) {
            truncated = true;
            break;
        }
        // 前端用 JSON 字符串展示/操作文件名；非 UTF-8 名字会被 JSON 编码成
        // 数字数组，可能被字符串化成另一个路径。直接跳过，避免误操作别的文件。
        if (!std.unicode.utf8ValidateSlice(entry.name)) {
            truncated = true;
            continue;
        }
        const name = arena.dupe(u8, entry.name) catch return fail(request, arena, .internal_server_error, "out_of_memory");
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
        }) catch return fail(request, arena, .internal_server_error, "out_of_memory");
    }

    std.mem.sort(Entry, entries.items, {}, entryLessThan);

    const Payload = struct { path: []const u8, entries: []const Entry, truncated: bool };
    return respondJson(request, arena, .ok, Payload{
        .path = rel,
        .entries = entries.items,
        .truncated = truncated,
    });
}

fn read(io: Io, arena: Allocator, request: *http.Server.Request) !void {
    const rel = normalized(arena, try param(arena, request, "path")) catch
        return fail(request, arena, .bad_request, "invalid_path");
    if (rel.len == 0) return fail(request, arena, .bad_request, "invalid_path");
    const abs = resolveExisting(io, arena, rel) catch |err| return failMapped(request, arena, err);

    const st = Dir.cwd().statFile(io, abs, .{ .follow_symlinks = false }) catch |err|
        return failMapped(request, arena, err);
    if (st.kind != .file) return fail(request, arena, .bad_request, "not_a_file");
    if (st.size > max_read) return fail(request, arena, .payload_too_large, "file_too_large");

    // .limited(N) 在恰好 N 字节时也会报 StreamTooLong，所以留 1 字节余量；
    // 超过 max_read 的真实文件仍然拒绝。
    const bytes = Dir.cwd().readFileAlloc(io, abs, arena, .limited(max_read + 1)) catch |err| switch (err) {
        error.StreamTooLong => return fail(request, arena, .payload_too_large, "file_too_large"),
        else => return failMapped(request, arena, err),
    };
    if (std.mem.indexOfScalar(u8, bytes, 0) != null or !std.unicode.utf8ValidateSlice(bytes))
        return fail(request, arena, .unsupported_media_type, "binary_file");

    const Payload = struct { path: []const u8, content: []const u8, size: u64, version: []const u8 };
    const version = util.contentVersion(bytes);
    return respondJson(request, arena, .ok, Payload{
        .path = rel,
        .content = bytes,
        .size = st.size,
        .version = &version,
    });
}

/// `base` 为空表示调用方不做冲突检查（curl/新建文件）。目标不存在或超过
/// max_read 时无法证明内容一致，按冲突处理；权限/目录等真实错误向上抛，
/// 由 HTTP 层返回对应状态，不要伪装成“文件已被修改”。
fn baseMatches(io: Io, arena: Allocator, abs: []const u8, base: []const u8) !bool {
    if (base.len == 0) return true;
    const current = Dir.cwd().readFileAlloc(io, abs, arena, .limited(max_read + 1)) catch |err| switch (err) {
        error.FileNotFound, error.StreamTooLong => return false,
        else => return err,
    };
    const version = util.contentVersion(current);
    return std.mem.eql(u8, &version, base);
}

fn write(io: Io, gpa: Allocator, arena: Allocator, request: *http.Server.Request) !void {
    const rel = normalized(arena, try param(arena, request, "path")) catch
        return fail(request, arena, .bad_request, "invalid_path");
    if (rel.len == 0) return fail(request, arena, .bad_request, "invalid_path");
    // 读 body 之后 request.head（含 target）就失效了，所有 query 参数必须先取出来。
    const base = try param(arena, request, "base");
    const exclusive = std.mem.eql(u8, try param(arena, request, "exclusive"), "1");
    if (!util.requestDeclaresBody(request))
        return fail(request, arena, .length_required, "length_required");

    if (request.head.content_length) |len| {
        if (len > max_write) return failClose(request, arena, .payload_too_large, "body_too_large");
    }

    var body_buf: [4096]u8 = undefined;
    const body_reader = request.readerExpectContinue(&body_buf) catch return fail(request, arena, .bad_request, "bad_body");
    const body = body_reader.allocRemaining(gpa, .limited(max_write)) catch |err| switch (err) {
        error.StreamTooLong => return failClose(request, arena, .payload_too_large, "body_too_large"),
        else => return failClose(request, arena, .bad_request, "bad_body"),
    };
    defer gpa.free(body);
    // 客户端可能在 Content-Length 之前就断开；不能把半截内容写进目标文件。
    if (!util.bodyComplete(request)) return failClose(request, arena, .bad_request, "bad_body");

    const abs = resolveWriteTarget(io, arena, rel) catch |err| return failMapped(request, arena, err);
    try ensureRegularOrMissing(io, arena, request, abs);

    const base_ok = baseMatches(io, arena, abs, base) catch |err| return failMapped(request, arena, err);
    if (!base_ok) return fail(request, arena, .conflict, "modified_on_disk");

    const meta = if (exclusive) null else existingMeta(io, arena, abs) catch |err| switch (err) {
        error.MetadataUnsafe => return fail(request, arena, .conflict, "metadata_unsafe"),
        else => return failMapped(request, arena, err),
    };
    var staged = stageWrite(io, abs, meta, !exclusive) catch |err|
        return failMapped(request, arena, err);
    defer staged.atomic.deinit(io);
    staged.atomic.file.writeStreamingAll(io, body) catch |err| return failMapped(request, arena, err);
    finishStaged(&staged, io, meta) catch |err| switch (err) {
        error.MetadataUnsafe => return fail(request, arena, .conflict, "metadata_unsafe"),
        else => return failMapped(request, arena, err),
    };
    if (exclusive) {
        staged.atomic.link(io) catch |err| return failMapped(request, arena, err);
    } else {
        staged.atomic.replace(io) catch |err| return failMapped(request, arena, err);
    }

    var pb: [256]u8 = undefined;
    std.debug.print("写入 /{s} ({d} B)\n", .{ logText(&pb, rel), body.len });

    const Payload = struct { ok: bool, path: []const u8, size: usize, version: []const u8 };
    const version = util.contentVersion(body);
    return respondJson(request, arena, .ok, Payload{
        .ok = true,
        .path = rel,
        .size = body.len,
        .version = &version,
    });
}

fn makeDir(io: Io, arena: Allocator, request: *http.Server.Request) !void {
    const rel = normalized(arena, try param(arena, request, "path")) catch
        return fail(request, arena, .bad_request, "invalid_path");
    if (rel.len == 0) return fail(request, arena, .bad_request, "invalid_path");
    const abs = joinAbs(arena, "/", rel) catch |err| return failMapped(request, arena, err);

    Dir.cwd().createDirPath(io, abs) catch |err| return failMapped(request, arena, err);

    var pb: [256]u8 = undefined;
    std.debug.print("新建目录 /{s}\n", .{logText(&pb, rel)});

    const Payload = struct { ok: bool };
    return respondJson(request, arena, .ok, Payload{ .ok = true });
}

fn rename(io: Io, arena: Allocator, request: *http.Server.Request) !void {
    const from_rel = normalized(arena, try param(arena, request, "from")) catch
        return fail(request, arena, .bad_request, "invalid_path");
    const to_rel = normalized(arena, try param(arena, request, "to")) catch
        return fail(request, arena, .bad_request, "invalid_path");
    if (from_rel.len == 0 or to_rel.len == 0) return fail(request, arena, .bad_request, "invalid_path");
    const overwrite = std.mem.eql(u8, try param(arena, request, "overwrite"), "1");

    const from_abs = resolveLeaf(io, arena, from_rel) catch |err| return failMapped(request, arena, err);
    const to_abs = resolveNew(io, arena, to_rel) catch |err| return failMapped(request, arena, err);
    if (std.mem.eql(u8, from_abs, "/")) return fail(request, arena, .forbidden, "cannot_move_root");

    if (overwrite) {
        Dir.rename(.cwd(), from_abs, .cwd(), to_abs, io) catch |err| return failMapped(request, arena, err);
    } else {
        Dir.renamePreserve(.cwd(), from_abs, .cwd(), to_abs, io) catch |err| return switch (err) {
            error.PathAlreadyExists => fail(request, arena, .conflict, "already_exists"),
            else => failMapped(request, arena, err),
        };
    }

    var fb: [256]u8 = undefined;
    var tb: [256]u8 = undefined;
    std.debug.print("重命名 /{s} -> /{s}\n", .{ logText(&fb, from_rel), logText(&tb, to_rel) });

    const Payload = struct { ok: bool };
    return respondJson(request, arena, .ok, Payload{ .ok = true });
}

fn delete(io: Io, arena: Allocator, request: *http.Server.Request) !void {
    const rel = normalized(arena, try param(arena, request, "path")) catch
        return fail(request, arena, .bad_request, "invalid_path");
    if (rel.len == 0) return fail(request, arena, .bad_request, "invalid_path");
    const abs = resolveLeaf(io, arena, rel) catch |err| return failMapped(request, arena, err);
    if (std.mem.eql(u8, abs, "/")) return fail(request, arena, .forbidden, "cannot_delete_root");

    const st = Dir.cwd().statFile(io, abs, .{ .follow_symlinks = false }) catch |err|
        return failMapped(request, arena, err);
    if (st.kind == .directory) {
        Dir.cwd().deleteTree(io, abs) catch |err| return failMapped(request, arena, err);
    } else {
        Dir.cwd().deleteFile(io, abs) catch |err| return failMapped(request, arena, err);
    }

    var pb: [256]u8 = undefined;
    std.debug.print("删除 /{s}\n", .{logText(&pb, rel)});

    const Payload = struct { ok: bool };
    return respondJson(request, arena, .ok, Payload{ .ok = true });
}

fn parseU64(text: []const u8) ?u64 {
    return std.fmt.parseInt(u64, text, 10) catch null;
}

fn failOffset(request: *http.Server.Request, alloc: Allocator, status: http.Status, code: []const u8, offset: u64) !void {
    const Payload = struct { @"error": []const u8, offset: u64 };
    return respondJson(request, alloc, status, Payload{ .@"error" = code, .offset = offset });
}

fn uploadSingle(io: Io, arena: Allocator, rel: []const u8, request: *http.Server.Request) !void {
    if (rel.len == 0) return fail(request, arena, .bad_request, "invalid_path");
    if (!util.requestDeclaresBody(request))
        return fail(request, arena, .length_required, "length_required");
    if (request.head.content_length) |len| {
        if (len > max_upload) return failClose(request, arena, .payload_too_large, "upload_too_large");
    }

    const abs = resolveWriteTarget(io, arena, rel) catch |err| return failMapped(request, arena, err);
    try ensureRegularOrMissing(io, arena, request, abs);
    const meta = existingMeta(io, arena, abs) catch |err| switch (err) {
        error.MetadataUnsafe => return fail(request, arena, .conflict, "metadata_unsafe"),
        else => return failMapped(request, arena, err),
    };
    var staged = stageWrite(io, abs, meta, true) catch |err|
        return failMapped(request, arena, err);
    defer staged.atomic.deinit(io);

    var head_buf: [16 * 1024]u8 = undefined;
    const body_reader = request.readerExpectContinue(&head_buf) catch
        return fail(request, arena, .bad_request, "bad_body");

    var chunk: [64 * 1024]u8 = undefined;
    var total: u64 = 0;
    while (true) {
        const n = body_reader.readSliceShort(&chunk) catch |err| return failMapped(request, arena, err);
        if (n == 0) break;
        total += n;
        if (total > max_upload) return failClose(request, arena, .payload_too_large, "upload_too_large");
        staged.atomic.file.writeStreamingAll(io, chunk[0..n]) catch |err| return failMapped(request, arena, err);
    }

    if (!util.bodyComplete(request)) return failClose(request, arena, .bad_request, "bad_body");
    finishStaged(&staged, io, meta) catch |err| switch (err) {
        error.MetadataUnsafe => return fail(request, arena, .conflict, "metadata_unsafe"),
        else => return failMapped(request, arena, err),
    };
    staged.atomic.replace(io) catch |err| return failMapped(request, arena, err);

    var pb: [256]u8 = undefined;
    std.debug.print("上传 /{s} ({d} B)\n", .{ util.logText(&pb, rel), total });

    const Payload = struct { ok: bool, done: bool, path: []const u8, offset: u64 };
    return respondJson(request, arena, .ok, Payload{ .ok = true, .done = true, .path = rel, .offset = total });
}

fn archive(io: Io, arena: Allocator, request: *http.Server.Request) !void {
    const rel = normalized(arena, try param(arena, request, "path")) catch
        return fail(request, arena, .bad_request, "invalid_path");
    const abs = resolveExisting(io, arena, rel) catch |err| return failMapped(request, arena, err);
    const st = Dir.cwd().statFile(io, abs, .{ .follow_symlinks = false }) catch |err|
        return failMapped(request, arena, err);
    if (st.kind != .directory) return fail(request, arena, .bad_request, "not_a_directory");

    const base = basename(rel);
    const root_name = if (base.len == 0) "root" else base;

    var name_buf: [512]u8 = undefined;
    const tar_name = std.fmt.bufPrint(&name_buf, "{s}.tar", .{root_name}) catch "archive.tar";
    var disposition_buf: [1024]u8 = undefined;
    const disposition = contentDisposition(&disposition_buf, tar_name);

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
            .keep_alive = keepAliveForRequest(request),
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
        if (state.entries >= max_tar_entries) {
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
                // tar 的八进制 size 字段最大只能表示 max_tar_bytes - 1。
                if (st.size > max_tar_bytes - 1 - state.bytes) {
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

fn download(io: Io, arena: Allocator, request: *http.Server.Request) !void {
    const rel = normalized(arena, try param(arena, request, "path")) catch
        return fail(request, arena, .bad_request, "invalid_path");
    if (rel.len == 0) return fail(request, arena, .bad_request, "invalid_path");

    const abs = resolveExisting(io, arena, rel) catch |err| return failMapped(request, arena, err);
    const st = Dir.cwd().statFile(io, abs, .{ .follow_symlinks = false }) catch |err|
        return failMapped(request, arena, err);
    if (st.kind != .file) return fail(request, arena, .bad_request, "not_a_file");

    var file = Dir.cwd().openFile(io, abs, .{ .mode = .read_only, .follow_symlinks = false }) catch |err|
        return failMapped(request, arena, err);
    defer file.close(io);

    const name = basename(rel);
    var disposition_buf: [1024]u8 = undefined;
    const disposition = contentDisposition(&disposition_buf, name);

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
            .keep_alive = keepAliveForRequest(request),
        },
    });

    var file_buf: [64 * 1024]u8 = undefined;
    var file_reader = file.reader(io, &file_buf);
    // 必须按 stat 得到的长度发送，否则文件在传输期间变长会多发字节、破坏
    // Content-Length 和 keep-alive 的帧边界。
    file_reader.interface.streamExact64(&body.writer, st.size) catch |err| return err;
    return body.end();
}

/// 日志里的路径：控制字符换成 `?`，避免文件名伪造日志行。
fn logText(buf: []u8, raw: []const u8) []const u8 {
    const n = @min(raw.len, buf.len);
    for (raw[0..n], 0..) |c, i| buf[i] = if (c < 0x20 or c == 0x7f) '?' else c;
    return buf[0..n];
}

fn basename(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[slash + 1 ..];
}

fn isUrlSafe(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~';
}

/// `attachment` + ASCII 回退名 + RFC 5987 的 UTF-8 文件名。
fn contentDisposition(buf: []u8, name: []const u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.writeAll("attachment; filename=\"") catch return "attachment";
    for (name) |c| {
        const safe = c >= 0x20 and c < 0x7f and c != '"' and c != '\\';
        w.writeByte(if (safe) c else '_') catch return "attachment";
    }
    w.writeAll("\"; filename*=UTF-8''") catch return "attachment";
    for (name) |c| {
        if (isUrlSafe(c)) {
            w.writeByte(c) catch return "attachment";
        } else {
            w.print("%{X:0>2}", .{c}) catch return "attachment";
        }
    }
    return w.buffered();
}

// ---------------------------------------------------------------------------
// 路径处理与响应
// ---------------------------------------------------------------------------

const PathError = error{
    InvalidPath,
    FileNotFound,
    AccessDenied,
    NameTooLong,
    OutOfMemory,
    IoError,
};

/// 归一化相对路径：拒绝绝对路径、`..`、NUL；丢弃空段与 `.`。
fn normalized(alloc: Allocator, raw: []const u8) ![]const u8 {
    if (raw.len != 0 and raw[0] == '/') return error.InvalidPath;
    if (std.mem.indexOfScalar(u8, raw, 0) != null) return error.InvalidPath;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    var it = std.mem.splitScalar(u8, raw, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) return error.InvalidPath;
        if (out.items.len != 0) try out.append(alloc, '/');
        try out.appendSlice(alloc, part);
    }
    // 前端和 JSON 都按 UTF-8 表示路径；列表已经跳过非 UTF-8 文件名，
    // 这里也拒绝，避免 API 生成字符串数组形式的 path 或让文件凭空消失。
    if (!std.unicode.utf8ValidateSlice(out.items)) return error.InvalidPath;
    return try alloc.dupe(u8, out.items);
}

fn joinAbs(alloc: Allocator, root: []const u8, rel: []const u8) ![]const u8 {
    if (rel.len == 0) return alloc.dupe(u8, root);
    if (std.mem.eql(u8, root, "/")) return std.fmt.allocPrint(alloc, "/{s}", .{rel});
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ root, rel });
}

/// 解析已存在的目标；realpath 用于消除符号链接，便于后续按文件/目录处理。
fn resolveExisting(io: Io, alloc: Allocator, rel: []const u8) PathError![:0]u8 {
    const joined = joinAbs(alloc, "/", rel) catch return error.OutOfMemory;
    return Dir.cwd().realPathFileAlloc(io, joined, alloc) catch |err| switch (err) {
        error.FileNotFound => error.FileNotFound,
        error.AccessDenied, error.PermissionDenied => error.AccessDenied,
        error.NameTooLong => error.NameTooLong,
        error.NotDir, error.SymLinkLoop, error.BadPathName => error.InvalidPath,
        error.OutOfMemory => error.OutOfMemory,
        else => error.IoError,
    };
}

/// 目标可以不存在，但父目录必须存在。
fn resolveNew(io: Io, alloc: Allocator, rel: []const u8) PathError![]const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, rel, '/') orelse {
        const parent = try resolveExisting(io, alloc, "");
        return joinAbs(alloc, parent, rel);
    };
    const parent_rel = rel[0..slash];
    const base = rel[slash + 1 ..];
    if (base.len == 0 or std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, ".."))
        return error.InvalidPath;
    const parent = try resolveExisting(io, alloc, parent_rel);
    return joinAbs(alloc, parent, base);
}

/// 写入目标：目标是符号链接时写到它指向的真实文件，避免替换链接本身。
fn resolveWriteTarget(io: Io, alloc: Allocator, rel: []const u8) PathError![]const u8 {
    return resolveExisting(io, alloc, rel) catch |err| switch (err) {
        error.FileNotFound => resolveNew(io, alloc, rel),
        else => err,
    };
}

const Xattr = struct {
    name: [:0]const u8,
    value: []const u8,
};

const StagedFile = struct {
    atomic: std.Io.File.Atomic,
    /// 新文件在 umask/default ACL 生效后的 mode；覆盖时保留原文件元数据。
    final_perms: ?std.Io.File.Permissions = null,
};

/// 在目标目录创建临时文件。所有目标都先以 0600 写入：目录的 default ACL
/// 可能覆盖 open() 的 mode，所以创建后必须再 chmod 一次（同时把 ACL mask
/// 清零），否则半截文件在写入期间可能被其他用户读到。
fn stageWrite(io: Io, abs: []const u8, meta: ?FileMeta, replace: bool) !StagedFile {
    var staged = StagedFile{
        .atomic = try Dir.cwd().createFileAtomic(io, abs, .{
            .replace = replace,
            .permissions = .default_file,
        }),
    };
    errdefer staged.atomic.deinit(io);
    if (meta == null) {
        const st = staged.atomic.file.stat(io) catch |err| return err;
        staged.final_perms = st.permissions;
    }
    staged.atomic.file.setPermissions(io, std.Io.File.Permissions.fromMode(0o600)) catch |err|
        return err;
    return staged;
}

/// 写入完成后恢复元数据：覆盖文件恢复原 mode/owner/xattr，新文件恢复创建时
/// 由 umask/default ACL 决定的 mode。
fn finishStaged(staged: *StagedFile, io: Io, meta: ?FileMeta) !void {
    if (meta) |m| {
        applyMeta(io, staged.atomic.file, m) catch return error.MetadataUnsafe;
    } else if (staged.final_perms) |perms| {
        staged.atomic.file.setPermissions(io, perms) catch |err| return err;
    }
}

/// 写入/上传前确认目标要么不存在，要么是普通文件。FIFO/设备/目录直接拒绝，
/// 避免 open() 阻塞或把设备节点原子替换成普通文件。
fn ensureRegularOrMissing(
    io: Io,
    alloc: Allocator,
    request: *http.Server.Request,
    abs: []const u8,
) !void {
    const st = Dir.cwd().statFile(io, abs, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return failMapped(request, alloc, err),
    };
    if (st.kind != .file) return fail(request, alloc, .bad_request, "not_a_file");
}

const FileMeta = struct {
    uid: linux.uid_t,
    gid: linux.gid_t,
    mode: posix.mode_t,
    xattrs: []const Xattr,
};

/// 原子替换会换 inode。能在新 inode 上重建的属性就重建；重建不了的
/// （硬链接、无法 chown 的属主）直接拒绝，避免静默改坏文件。
fn existingMeta(io: Io, alloc: Allocator, abs: []const u8) !?FileMeta {
    // O_NONBLOCK 让 FIFO 立即返回而不是卡在 open(2)；O_NOFOLLOW 保证最后
    // 一段不会被换成符号链接。普通文件不受这两个标志影响。
    const fd = posix.openat(posix.AT.FDCWD, abs, .{
        .ACCMODE = .RDONLY,
        .CLOEXEC = true,
        .NONBLOCK = true,
        .NOFOLLOW = true,
    }, 0) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.SymLinkLoop => return error.MetadataUnsafe,
        else => return err,
    };
    var file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
    defer file.close(io);

    var stx: linux.Statx = undefined;
    const rc = linux.statx(file.handle, "", linux.AT.EMPTY_PATH, .{
        .MODE = true,
        .NLINK = true,
        .UID = true,
        .GID = true,
    }, &stx);
    if (posix.errno(rc) != .SUCCESS) return error.MetadataUnsafe;
    if (!linux.S.ISREG(stx.mode)) return error.MetadataUnsafe;
    if (stx.nlink > 1 or stx.uid != linux.geteuid()) return error.MetadataUnsafe;

    return .{
        .uid = stx.uid,
        .gid = stx.gid,
        .mode = stx.mode & 0o7777,
        .xattrs = try readXattrs(alloc, file),
    };
}

/// 替换 inode 后需要手动恢复的扩展属性：POSIX ACL、文件 capability 和
/// 用户自定义属性。SELinux 标签由内核按新文件所在目录重新计算，IMA/EVM
/// 签名在内容变化后本来就会失效，因此都不复制。
fn shouldPreserveXattr(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "user.") or
        std.mem.startsWith(u8, name, "system.posix_acl_") or
        std.mem.eql(u8, name, "security.capability");
}

fn readXattrs(alloc: Allocator, file: std.Io.File) ![]const Xattr {
    var empty: [0]u8 = .{};
    const list_len = linux.flistxattr(file.handle, &empty, 0);
    switch (posix.errno(list_len)) {
        .SUCCESS => {},
        .OPNOTSUPP => return &.{}, // 文件系统不支持 xattr
        else => return error.MetadataUnsafe,
    }

    const names = try alloc.alloc(u8, list_len);
    const n = linux.flistxattr(file.handle, names.ptr, names.len);
    if (posix.errno(n) != .SUCCESS or n > names.len) return error.MetadataUnsafe;

    var out: std.ArrayList(Xattr) = .empty;
    var at: usize = 0;
    while (at < n) {
        const end = std.mem.indexOfScalar(u8, names[at..n], 0) orelse
            return error.MetadataUnsafe;
        const name: [:0]u8 = names[at .. at + end :0];
        at += end + 1;
        if (!shouldPreserveXattr(name)) continue;
        const value_len = linux.fgetxattr(file.handle, name.ptr, &empty, 0);
        if (posix.errno(value_len) == .NODATA) continue;
        if (posix.errno(value_len) != .SUCCESS) return error.MetadataUnsafe;
        const value = try alloc.alloc(u8, value_len);
        const got = linux.fgetxattr(file.handle, name.ptr, value.ptr, value.len);
        if (posix.errno(got) != .SUCCESS or got != value_len)
            return error.MetadataUnsafe;
        try out.append(alloc, .{ .name = name, .value = value });
    }
    return out.items;
}

fn applyMeta(io: Io, file: std.Io.File, meta: FileMeta) !void {
    if (posix.errno(linux.fchown(file.handle, meta.uid, meta.gid)) != .SUCCESS)
        return error.MetadataUnsafe;

    var has_access_acl = false;
    for (meta.xattrs) |xattr| {
        if (std.mem.eql(u8, xattr.name, "system.posix_acl_access")) has_access_acl = true;
        if (posix.errno(linux.fsetxattr(file.handle, xattr.name.ptr, xattr.value.ptr, xattr.value.len, 0)) != .SUCCESS)
            return error.MetadataUnsafe;
    }
    // 临时文件创建在目标目录里，会继承目录的 default ACL。原文件没有 ACL
    // 时必须把继承来的 access ACL 去掉，否则覆盖会悄悄增加权限。
    if (!has_access_acl) {
        const rc = linux.fremovexattr(file.handle, "system.posix_acl_access");
        switch (posix.errno(rc)) {
            .SUCCESS, .NODATA, .OPNOTSUPP => {},
            else => return error.MetadataUnsafe,
        }
    }
    file.setPermissions(io, std.Io.File.Permissions.fromMode(meta.mode)) catch
        return error.MetadataUnsafe;
}

/// 只规范化父目录，不解析最后一段。delete/rename 用它来操作符号链接本身，
/// 而不是把链接解析到目标，避免“删除一个链接却删掉整个目标目录”。
fn resolveLeaf(io: Io, alloc: Allocator, rel: []const u8) PathError![]const u8 {
    if (rel.len == 0) return error.InvalidPath;
    const slash = std.mem.lastIndexOfScalar(u8, rel, '/') orelse {
        const parent = try resolveExisting(io, alloc, "");
        return joinAbs(alloc, parent, rel);
    };
    const parent_rel = rel[0..slash];
    const base = rel[slash + 1 ..];
    if (base.len == 0 or std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, ".."))
        return error.InvalidPath;
    const parent = try resolveExisting(io, alloc, parent_rel);
    return joinAbs(alloc, parent, base);
}

fn entryLessThan(_: void, a: Entry, b: Entry) bool {
    const a_dir = std.mem.eql(u8, a.kind, "directory");
    const b_dir = std.mem.eql(u8, b.kind, "directory");
    if (a_dir != b_dir) return a_dir;
    return std.mem.lessThan(u8, a.name, b.name);
}

/// body 没读干净就关连接，避免 std.http 为了 keep-alive 去 drain 一个
/// 可能已经被客户端截断的 body（那会触发断言并中止整个进程）。
fn keepAliveForRequest(request: *const http.Server.Request) bool {
    if (!util.requestHasBody(request)) return true;
    return util.bodyComplete(request);
}

/// JSON / 固定文本响应的头：和 server.zig 的静态资源用同一套安全头。
fn apiHeaders(buf: *[2 + util.security_headers.len]http.Header) []const http.Header {
    buf[0] = .{ .name = "content-type", .value = "application/json; charset=utf-8" };
    buf[1] = .{ .name = "cache-control", .value = "no-store" };
    @memcpy(buf[2..], &util.security_headers);
    return buf;
}

fn respondJson(request: *http.Server.Request, alloc: Allocator, status: http.Status, value: anytype) anyerror!void {
    return respondJsonKeepAlive(request, alloc, status, value, keepAliveForRequest(request));
}

/// JSON 小于这个值时压缩的头比省下的字节还多，不值得。
const min_json_gzip_bytes = 1024;

fn respondJsonKeepAlive(
    request: *http.Server.Request,
    alloc: Allocator,
    status: http.Status,
    value: anytype,
    keep_alive: bool,
) anyerror!void {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    std.json.Stringify.value(value, .{}, &out.writer) catch
        return respondStatic(request, .internal_server_error, "{\"error\":\"json_encode_failed\"}");

    // 大目录列表和文本文件读取的 JSON 都是高度可压缩的文本：3000 项列表
    // 约 131 KiB -> 20 KiB。压缩失败或反而更大时回退明文。
    var body: []const u8 = out.written();
    var gzipped: ?[]u8 = null;
    if (body.len >= min_json_gzip_bytes and util.acceptsGzip(request)) {
        if (util.gzipAlloc(alloc, body) catch null) |buf| {
            if (buf.len < body.len) {
                gzipped = buf;
                body = buf;
            } else alloc.free(buf);
        }
    }

    var header_buf: [4 + util.security_headers.len]http.Header = undefined;
    var n: usize = 0;
    header_buf[n] = .{ .name = "content-type", .value = "application/json; charset=utf-8" };
    n += 1;
    header_buf[n] = .{ .name = "cache-control", .value = "no-store" };
    n += 1;
    if (gzipped != null) {
        header_buf[n] = .{ .name = "content-encoding", .value = "gzip" };
        n += 1;
        header_buf[n] = .{ .name = "vary", .value = "accept-encoding" };
        n += 1;
    }
    @memcpy(header_buf[n..][0..util.security_headers.len], &util.security_headers);
    n += util.security_headers.len;
    return request.respond(body, .{
        .status = status,
        .extra_headers = header_buf[0..n],
        .keep_alive = keep_alive,
    });
}

/// 不经过 JSON 编码 / 分配器的固定响应，避免 OOM 时递归调用自身。
fn respondStatic(request: *http.Server.Request, status: http.Status, body: []const u8) !void {
    var header_buf: [2 + util.security_headers.len]http.Header = undefined;
    return request.respond(body, .{
        .status = status,
        .extra_headers = apiHeaders(&header_buf),
        .keep_alive = keepAliveForRequest(request),
    });
}

fn fail(request: *http.Server.Request, alloc: Allocator, status: http.Status, code: []const u8) anyerror!void {
    const Payload = struct { @"error": []const u8 };
    return respondJson(request, alloc, status, Payload{ .@"error" = code });
}

/// body 没有读完的错误必须关连接，避免残余字节被当成下一个请求。
fn failClose(request: *http.Server.Request, alloc: Allocator, status: http.Status, code: []const u8) anyerror!void {
    const Payload = struct { @"error": []const u8 };
    return respondJsonKeepAlive(request, alloc, status, Payload{ .@"error" = code }, false);
}

fn failMapped(request: *http.Server.Request, alloc: Allocator, err: anyerror) anyerror!void {
    return switch (err) {
        error.InvalidPath => fail(request, alloc, .bad_request, "invalid_path"),
        error.FileNotFound => fail(request, alloc, .not_found, "not_found"),
        error.PathAlreadyExists => fail(request, alloc, .conflict, "already_exists"),
        error.NotDir => fail(request, alloc, .conflict, "not_a_directory"),
        error.IsDir => fail(request, alloc, .conflict, "is_a_directory"),
        error.AccessDenied => fail(request, alloc, .forbidden, "access_denied"),
        error.NameTooLong => fail(request, alloc, .bad_request, "path_too_long"),
        error.OutOfMemory => fail(request, alloc, .internal_server_error, "out_of_memory"),
        else => fail(request, alloc, .internal_server_error, "io_error"),
    };
}

// ---------------------------------------------------------------------------

test "normalized rejects traversal and absolute paths" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try std.testing.expectEqualStrings("a/b", try normalized(a, "a//b/./"));
    try std.testing.expectEqualStrings("", try normalized(a, "."));
    try std.testing.expectError(error.InvalidPath, normalized(a, "../etc"));
    try std.testing.expectError(error.InvalidPath, normalized(a, "a/../../b"));
    try std.testing.expectError(error.InvalidPath, normalized(a, "/etc/passwd"));
    try std.testing.expectError(error.InvalidPath, normalized(a, "bad\xffname"));
}

test "content disposition encoding" {
    var buf: [128]u8 = undefined;
    const plain = contentDisposition(&buf, "a.txt");
    try std.testing.expect(std.mem.indexOf(u8, plain, "filename=\"a.txt\"") != null);

    var buf2: [256]u8 = undefined;
    const cjk = contentDisposition(&buf2, "\u{4e2d}\u{6587}.txt");
    try std.testing.expect(std.mem.indexOf(u8, cjk, "filename*=UTF-8''%E4%B8%AD%E6%96%87.txt") != null);
}

test "basename" {
    try std.testing.expectEqualStrings("b.txt", basename("a/b.txt"));
    try std.testing.expectEqualStrings("a.txt", basename("a.txt"));
}

fn le16(bytes: []const u8) u16 {
    return @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8);
}

fn le32(bytes: []const u8) u32 {
    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) |
        (@as(u32, bytes[3]) << 24);
}

/// 构造 POSIX ACL xattr：owner rw、named user r、group ---、mask r、other ---。
/// 用于测试目录 default ACL 是否会被临时文件继承。
fn testAcl(buf: *[44]u8, named_id: u32) []const u8 {
    const AclEntry = struct { tag: u16, perm: u16, id: u32 };
    const entries = [_]AclEntry{
        .{ .tag = 0x01, .perm = 6, .id = 0xffffffff },
        .{ .tag = 0x02, .perm = 4, .id = named_id },
        .{ .tag = 0x04, .perm = 0, .id = 0xffffffff },
        .{ .tag = 0x10, .perm = 4, .id = 0xffffffff },
        .{ .tag = 0x20, .perm = 0, .id = 0xffffffff },
    };
    std.mem.writeInt(u32, buf[0..4], 2, .little);
    var off: usize = 4;
    for (entries) |entry| {
        std.mem.writeInt(u16, buf[off..][0..2], entry.tag, .little);
        std.mem.writeInt(u16, buf[off + 2 ..][0..2], entry.perm, .little);
        std.mem.writeInt(u32, buf[off + 4 ..][0..4], entry.id, .little);
        off += 8;
    }
    return buf;
}

fn aclMask(value: []const u8) ?u16 {
    if (value.len < 4 or le32(value[0..4]) != 2) return null;
    var i: usize = 4;
    while (i + 8 <= value.len) : (i += 8) {
        if (le16(value[i..][0..2]) == 0x10) return le16(value[i + 2 ..][0..2]);
    }
    return null;
}

test "staged write is 0600 and drops inherited default ACL" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &path_buf);
    var dir_z_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    @memcpy(dir_z_buf[0..dir_len], path_buf[0..dir_len]);
    dir_z_buf[dir_len] = 0;
    const dir_z: [:0]const u8 = dir_z_buf[0..dir_len :0];
    const abs = try std.fmt.allocPrint(alloc, "{s}/target", .{path_buf[0..dir_len]});

    // 原文件必须在设置 default ACL 之前创建，否则它自己就会继承 ACL。
    var target = try tmp.dir.createFile(io, "target", .{ .permissions = .fromMode(0o644) });
    target.close(io);

    var acl_buf: [44]u8 = undefined;
    const acl = testAcl(&acl_buf, 65534);
    const set_rc = linux.setxattr(dir_z.ptr, "system.posix_acl_default", acl.ptr, acl.len, 0);
    switch (posix.errno(set_rc)) {
        .SUCCESS => {},
        .OPNOTSUPP, .NOSYS => return error.SkipZigTest,
        else => return error.TestUnexpectedResult,
    }
    defer _ = linux.removexattr(dir_z.ptr, "system.posix_acl_default");

    const meta = (try existingMeta(io, alloc, abs)).?;
    try std.testing.expectEqual(@as(usize, 0), meta.xattrs.len);

    var staged = try stageWrite(io, abs, meta, true);
    defer staged.atomic.deinit(io);

    // 目录有 default ACL 时，open() 的 mode 会被 ACL 覆盖；stageWrite 必须
    // 再 chmod 0600，把继承来的 ACL mask 清零。
    const staged_stat = try staged.atomic.file.stat(io);
    try std.testing.expectEqual(@as(posix.mode_t, 0o600), staged_stat.permissions.toMode() & 0o7777);
    var xbuf: [256]u8 = undefined;
    const xlen = linux.fgetxattr(staged.atomic.file.handle, "system.posix_acl_access", &xbuf, xbuf.len);
    switch (posix.errno(xlen)) {
        .SUCCESS => try std.testing.expectEqual(@as(u16, 0), aclMask(xbuf[0..xlen]).?),
        .NODATA => {},
        else => return error.TestUnexpectedResult,
    }

    try staged.atomic.file.writeStreamingAll(io, "new content");
    try finishStaged(&staged, io, meta);

    // 原文件没有 ACL，覆盖后也不能留下目录 default ACL 继承来的 access ACL。
    const after_len = linux.fgetxattr(staged.atomic.file.handle, "system.posix_acl_access", &xbuf, xbuf.len);
    switch (posix.errno(after_len)) {
        .NODATA => {},
        .SUCCESS => return error.TestUnexpectedResult,
        else => return error.TestUnexpectedResult,
    }
    const after_stat = try staged.atomic.file.stat(io);
    try std.testing.expectEqual(@as(posix.mode_t, 0o644), after_stat.permissions.toMode() & 0o7777);

    try staged.atomic.replace(io);
    const final_stat = try tmp.dir.statFile(io, "target", .{});
    try std.testing.expectEqual(@as(posix.mode_t, 0o644), final_stat.permissions.toMode() & 0o7777);
}
