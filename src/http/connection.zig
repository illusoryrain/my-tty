const std = @import("std");
const http = std.http;
const net = std.Io.net;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const posix = std.posix;
const auth = @import("../auth.zig");
const config = @import("../config.zig");
const session = @import("../session.zig");
const websocket = @import("../term/websocket.zig");
const ids = @import("../term/ids.zig");
const util = @import("../util.zig");
const conn = @import("conn.zig");
const peer_mod = @import("peer.zig");
const respond = @import("respond.zig");
const auth_routes = @import("auth_routes.zig");
const route = @import("route.zig");

pub fn main(
    io: Io,
    gpa: Allocator,
    stream: net.Stream,
    cfg: *const config.Config,
    auth_state: *auth.Auth,
    manager: *session.Manager,
) void {
    defer {
        conn.connRemove(io, stream.socket.handle);
        _ = conn.release();
        stream.close(io);
    }
    const peer_addr = stream.socket.address;

    var read_buf: [64 * 1024]u8 = undefined;
    var write_buf: [16 * 1024]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var writer = stream.writer(io, &write_buf);
    var server: http.Server = .init(&reader.interface, &writer.interface);

    while (true) {
        conn.armIdle(io, stream.socket.handle);
        var request = server.receiveHead() catch return;
        conn.disarmIdle(io, stream.socket.handle);

        switch (request.upgradeRequested()) {
            .websocket => |maybe_key| {
                const key = maybe_key orelse {
                    respond.respondClose(&request, "bad websocket request\n", .bad_request) catch {};
                    return;
                };
                if (!peer_mod.originAllowed(&request, peer_mod.peerIsLoopback(peer_addr))) {
                    respond.respondClose(&request, "origin not allowed\n", .forbidden) catch {};
                    return;
                }
                const auth_session = auth_routes.wsAuthorized(auth_state, &request) orelse {
                    if (peer_mod.shouldLogAuthFailure(io, peer_addr)) {
                        var pb: [64]u8 = undefined;
                        std.debug.print("未认证 ws peer={s} cookie={s}\n", .{
                            peer_mod.peerText(&pb, peer_addr),
                            if (auth.cookieFromRequest(&request) == null) "no" else "yes",
                        });
                    }
                    respond.respondClose(&request, "unauthorized\n", .unauthorized) catch {};
                    return;
                };
                // 终端可能空闲很久；上面已经 disarm，不再参与 HTTP 空闲清理。
                const sid = ids.parseSessionId(util.queryParam(request.head.target, "session"));
                const resume_offset = ids.parseOffset(util.queryParam(request.head.target, "offset"));
                var ws = request.respondWebSocket(.{ .key = key }) catch return;
                var peer_buf: [64]u8 = undefined;
                const peer_name = peer_mod.peerText(&peer_buf, peer_addr);
                std.debug.print("ws 连接 peer={s}\n", .{peer_name});
                if (websocket.serve(io, manager, &ws, &stream, auth_session, sid, resume_offset)) |_| {
                    std.debug.print("ws 断开 peer={s}\n", .{peer_name});
                } else |err| {
                    std.debug.print("ws 断开 peer={s}: {t}\n", .{ peer_name, err });
                }
                return;
            },
            .other => {
                respond.respondClose(&request, "unsupported upgrade\n", .bad_request) catch {};
                return;
            },
            .none => {
                route.handle(io, gpa, cfg, auth_state, manager, peer_addr, stream.socket.handle, &request) catch return;
                // 客户端要求关闭，或请求 body 没有干净读完时，绝不能在同一个连接上
                // 继续解析下一段字节：残余 body 会被当成新请求（请求走私/响应错位）。
                if (!request.head.keep_alive) return;
                switch (server.reader.state) {
                    .ready => {},
                    else => return,
                }
            },
        }
    }
}
