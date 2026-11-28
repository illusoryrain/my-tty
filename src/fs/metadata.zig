const std = @import("std");
const http = std.http;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const linux = std.os.linux;
const posix = std.posix;
const respond = @import("respond.zig");

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
pub fn stageWrite(io: Io, abs: []const u8, meta: ?FileMeta, replace: bool) !StagedFile {
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
pub fn finishStaged(staged: *StagedFile, io: Io, meta: ?FileMeta) !void {
    if (meta) |m| {
        applyMeta(io, staged.atomic.file, m) catch return error.MetadataUnsafe;
    } else if (staged.final_perms) |perms| {
        staged.atomic.file.setPermissions(io, perms) catch |err| return err;
    }
}

/// 写入/上传前确认目标要么不存在，要么是普通文件。FIFO/设备/目录直接拒绝，
/// 避免 open() 阻塞或把设备节点原子替换成普通文件。
pub fn ensureRegularOrMissing(
    io: Io,
    alloc: Allocator,
    request: *http.Server.Request,
    abs: []const u8,
) !void {
    const st = Dir.cwd().statFile(io, abs, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return respond.failMapped(request, alloc, err),
    };
    if (st.kind != .file) return respond.fail(request, alloc, .bad_request, "not_a_file");
}

const FileMeta = struct {
    uid: linux.uid_t,
    gid: linux.gid_t,
    mode: posix.mode_t,
    xattrs: []const Xattr,
};

/// 原子替换会换 inode。能在新 inode 上重建的属性就重建；重建不了的
/// （硬链接、无法 chown 的属主）直接拒绝，避免静默改坏文件。
pub fn existingMeta(io: Io, alloc: Allocator, abs: []const u8) !?FileMeta {
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
