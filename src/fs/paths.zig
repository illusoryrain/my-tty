const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;

pub fn basename(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[slash + 1 ..];
}

fn isUrlSafe(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~';
}

/// `attachment` + ASCII 回退名 + RFC 5987 的 UTF-8 文件名。
pub const max_disposition_bytes = 4 * (std.fs.max_name_bytes + 4) + 64;

pub fn contentDisposition(buf: []u8, name: []const u8) []const u8 {
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
pub fn normalized(alloc: Allocator, raw: []const u8) ![]const u8 {
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

pub fn joinAbs(alloc: Allocator, root: []const u8, rel: []const u8) ![]const u8 {
    if (rel.len == 0) return alloc.dupe(u8, root);
    if (std.mem.eql(u8, root, "/")) return std.fmt.allocPrint(alloc, "/{s}", .{rel});
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ root, rel });
}

/// 解析已存在的目标；realpath 用于消除符号链接，便于后续按文件/目录处理。
pub fn resolveExisting(io: Io, alloc: Allocator, rel: []const u8) PathError![:0]u8 {
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
pub fn resolveNew(io: Io, alloc: Allocator, rel: []const u8) PathError![]const u8 {
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
pub fn resolveWriteTarget(io: Io, alloc: Allocator, rel: []const u8) PathError![]const u8 {
    return resolveExisting(io, alloc, rel) catch |err| switch (err) {
        error.FileNotFound => resolveNew(io, alloc, rel),
        else => err,
    };
}
pub fn resolveLeaf(io: Io, alloc: Allocator, rel: []const u8) PathError![]const u8 {
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

test "content disposition keeps the longest legal name" {
    // 255 字节是单个文件名的上限；每个非 ASCII 字节会展开成 3 个字符。
    var name: [255]u8 = undefined;
    @memset(&name, 0xE4);
    var buf: [max_disposition_bytes]u8 = undefined;
    const out = contentDisposition(&buf, &name);
    try std.testing.expect(std.mem.indexOf(u8, out, "filename*=UTF-8''") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "%E4") != null);
}

test "basename" {
    try std.testing.expectEqualStrings("b.txt", basename("a/b.txt"));
    try std.testing.expectEqualStrings("a.txt", basename("a.txt"));
}
