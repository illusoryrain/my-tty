//! 单元测试入口。
//!
//! 只 import 不依赖内嵌前端的模块，因此可以直接：
//!
//!     zig test src/tests.zig
//!
//! 不需要任何自定义 build step。

const std = @import("std");

test {
    _ = @import("config.zig");
    _ = @import("pty.zig");
    _ = @import("session.zig");
    _ = @import("util.zig");
    _ = @import("auth.zig");
    _ = @import("fs/api.zig");
    _ = @import("fs/paths.zig");
    _ = @import("fs/metadata.zig");
    _ = @import("term/websocket.zig");
    std.testing.refAllDecls(@This());
}
