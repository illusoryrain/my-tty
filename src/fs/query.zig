const std = @import("std");
const http = std.http;
const Allocator = std.mem.Allocator;
const util = @import("../util.zig");

/// 取 query 参数并按 urlencoded 解码；编码非法时返回 InvalidEncoding。
pub fn param(arena: Allocator, request: *http.Server.Request, key: []const u8) util.DecodeError![]const u8 {
    return (try util.queryParamDecoded(arena, request.head.target, key)) orelse "";
}
