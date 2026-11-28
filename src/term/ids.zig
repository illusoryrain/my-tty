const std = @import("std");

/// 从 query 里解析 128-bit 会话 id（32 位十六进制）。
pub fn parseSessionId(value: ?[]const u8) ?[16]u8 {
    const v = value orelse return null;
    if (v.len != 32) return null;
    var out: [16]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, v) catch return null;
    return out;
}

pub fn parseOffset(value: ?[]const u8) u64 {
    const v = value orelse return 0;
    return std.fmt.parseInt(u64, v, 10) catch 0;
}
