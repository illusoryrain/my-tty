const std = @import("std");
const http = std.http;
const net = std.Io.net;
const Io = std.Io;
const session = @import("../session.zig");
const pty = @import("../pty.zig");
const Manager = session.Manager;
const Attachment = session.Attachment;

pub const Control = struct {
    t: []const u8 = "",
    cols: ?u16 = null,
    rows: ?u16 = null,
};

/// 解析一条控制消息。分配只发生在调用方提供的栈缓冲里，消息用完即弃。
pub fn parseControl(scratch: []u8, data: []const u8) !Control {
    var fba: std.heap.FixedBufferAllocator = .init(scratch);
    return std.json.parseFromSliceLeaky(Control, fba.allocator(), data, .{ .ignore_unknown_fields = true });
}

/// 接管一条已升级的 WebSocket：attach 到会话、转发输入与 resize，断开时 detach。
pub fn serve(
    io: Io,
    manager: *Manager,
    ws: *http.Server.WebSocket,
    stream: *const net.Stream,
    auth_session: [16]u8,
    session_id: ?[16]u8,
    offset: u64,
) !void {
    var att: Attachment = .{
        .io = io,
        .gpa = manager.gpa,
        .ws = ws,
        .stream = stream,
        .auth_session = auth_session,
    };
    // 先启动写线程：attach 的 hello/回放也走队列，attach 本身不必等 socket。
    try att.startWriter();
    defer att.stopWriter();

    manager.attach(&att, session_id, offset) catch |err| {
        const body = switch (err) {
            error.TooManySessions => "{\"t\":\"error\",\"reason\":\"too_many_sessions\"}",
            error.SessionBusy => "{\"t\":\"error\",\"reason\":\"session_busy\"}",
            error.PtySpawnFailed => "{\"t\":\"error\",\"reason\":\"pty_failed\"}",
            error.Unauthorized => "{\"t\":\"error\",\"reason\":\"unauthorized\"}",
            else => "{\"t\":\"error\"}",
        };
        att.dropQueued();
        // writerLoop 可能正拿着 send_mutex 写队列里的帧；错误帧必须排队，
        // 否则两个线程会同时写同一个 WebSocket/Wirer。
        att.send_mutex.lockUncancelable(io);
        ws.writeMessage(body, .text) catch {};
        att.send_mutex.unlock(io);
        return err;
    };
    defer manager.detach(&att);

    // 控制消息都很小，用固定栈缓冲解析，避免每条心跳都走 page_allocator。
    var control_scratch: [1024]u8 = undefined;

    while (true) {
        const msg = ws.readSmallMessage() catch return;
        // 注销/接管/认证过期后 socket 可能还有已经读出的消息；不能再让它
        // 写入共享 PTY，否则旧前端仍能向新前端正在使用的 shell 注入输入。
        if (!att.alive.load(.acquire)) return;
        switch (msg.opcode) {
            .ping => att.sendRaw(msg.data, .pong) catch return,
            .binary => {
                const s = att.session orelse return;
                pty.writeAll(s.master, msg.data) catch return;
            },
            .text => {
                const control = parseControl(&control_scratch, msg.data) catch continue;
                if (std.mem.eql(u8, control.t, "close")) {
                    manager.destroyAttached(&att);
                    return;
                }
                if (std.mem.eql(u8, control.t, "ping")) {
                    // 应用层心跳：空终端没有输出，靠它确认连接还活着。
                    att.sendText("{\"t\":\"pong\"}") catch return;
                    continue;
                }
                if (std.mem.eql(u8, control.t, "cwd")) {
                    const s = att.session orelse return;
                    session.refreshCwd(s, true);
                    continue;
                }
                if (std.mem.eql(u8, control.t, "resize")) {
                    const s = att.session orelse return;
                    const cols = control.cols orelse continue;
                    const rows = control.rows orelse continue;
                    if (cols < 2 or rows < 1) continue;
                    pty.resize(s.master, cols, rows);
                }
            },
            else => return,
        }
    }
}

test "control message parsing" {
    var scratch: [1024]u8 = undefined;
    const parsed = try parseControl(&scratch,
        \\{"t":"resize","cols":120,"rows":40}
    );
    try std.testing.expectEqualStrings("resize", parsed.t);
    try std.testing.expectEqual(@as(?u16, 120), parsed.cols);
    try std.testing.expectEqual(@as(?u16, 40), parsed.rows);
}

test "unknown control fields are ignored" {
    var scratch: [1024]u8 = undefined;
    const parsed = try parseControl(&scratch,
        \\{"t":"ping","extra":true}
    );
    try std.testing.expectEqualStrings("ping", parsed.t);
}
