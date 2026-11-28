//! 常驻 PTY 会话管理器（不依赖任何终端复用器）。
//!
//! WebSocket 只是会话的一个“前端”：断开后 PTY 继续运行，输出进入每会话
//! 最多 512 KiB（初始 64 KiB，按需增长）的环形缓冲。重连时客户端带上会话 id
//! 和已收到的字节偏移，服务端只回放缺失部分（不会 reset 终端，因此不影响
//! 文本选择/复制）。
//!
//! 线程模型：
//!   - 每个会话一条 pump 线程，只负责读 PTY、写环形缓冲、转发给当前前端。
//!   - 每条 WebSocket 连接线程负责读输入、resize、以及最后的 detach。
//!
//! 协议（文本帧为 JSON，二进制帧为终端数据）：
//!   ready {"t":"ready","session":"<32 hex>","offset":N}
//!         在回放前发送；客户端把 offset 设为 N，之后按二进制帧长度累加。
//!   gap   {"t":"gap","lost":N}   缓冲区已丢弃 N 字节，从当前最旧的数据开始回放。
//!   exit  {"t":"exit"}           shell 已退出。
//!   cwd   {"t":"cwd","path":"<相对文件 root>"}  shell 的工作目录变化；只在
//!         cwd 位于文件 root 内时发送，path 为相对 root 的 POSIX 路径。
//!   error {"t":"error","reason":"..."}
//! 客户端 → 服务端：二进制 = 输入；文本 {t:"resize",cols,rows}、{t:"cwd"}
//! （立即读一次并回报 cwd）或 {t:"close"}。

const std = @import("std");
const http = std.http;
const linux = std.os.linux;
const posix = std.posix;
const net = std.Io.net;
const Io = std.Io;

const pty = @import("pty.zig");
const config = @import("config.zig");
const process = @import("term/process.zig");
const ids = @import("term/ids.zig");
pub const parseSessionId = ids.parseSessionId;
pub const parseOffset = ids.parseOffset;
const auth = @import("auth.zig");

const Allocator = std.mem.Allocator;

/// 会话输出缓冲的上限；创建时只分配 initial_ring_capacity，按需翻倍。
const ring_capacity: usize = 512 * 1024;
const initial_ring_capacity: usize = 64 * 1024;
const closed_grace_ns: i96 = 60 * std.time.ns_per_s;

pub const Attachment = struct {
    io: Io,
    gpa: Allocator,
    ws: *http.Server.WebSocket,
    stream: *const net.Stream,
    session: ?*Session = null,
    /// 建立这条 WebSocket 时绑定的登录会话；登录会话注销/过期后由 Manager 关闭。
    auth_session: [16]u8 = @splat(0),
    /// 直接写 socket 时用（attach 失败的错误帧）；正常输出走队列。
    send_mutex: Io.Mutex = .init,
    /// pump/attach 与连接线程会并发读写，必须是原子量。
    alive: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),

    /// 每个前端一条写线程。pump 只把输出放进队列，绝不在持有 session 锁时
    /// 阻塞在慢客户端上；队列有硬上限，超过就断开，避免无限占内存。
    out_mutex: Io.Mutex = .init,
    out_cond: Io.Condition = .init,
    out_queue: std.ArrayList(Frame) = .empty,
    out_bytes: usize = 0,
    out_closed: bool = false,
    writer: ?std.Thread = null,

    const max_out_bytes: usize = 1024 * 1024;
    /// 字节数管不住空帧：一条 0 字节 ping 只占队列项。限制帧数，避免慢客户端
    /// 用海量 ping 把内存堆到几百 MB。
    const max_out_frames: usize = 1024;
    const Frame = struct {
        data: []u8,
        op: http.Server.WebSocket.Opcode,
    };

    pub fn startWriter(self: *Attachment) !void {
        self.writer = try std.Thread.spawn(.{}, writerLoop, .{self});
    }

    pub fn stopWriter(self: *Attachment) void {
        self.out_mutex.lockUncancelable(self.io);
        self.out_closed = true;
        self.out_cond.broadcast(self.io);
        self.out_mutex.unlock(self.io);
        // 唤醒可能卡在慢客户端写操作里的 writer，否则 join 会一直等。
        self.stream.shutdown(self.io, .both) catch {};
        if (self.writer) |thread| {
            thread.join();
            self.writer = null;
        }
        // 队列本身也要释放：每个连接一条，只 clearRetainingCapacity 会永久
        // 留下这块容量（空 ping 还会不断扩容）。
        self.deinitQueue();
    }

    pub fn dropQueued(self: *Attachment) void {
        self.out_mutex.lockUncancelable(self.io);
        defer self.out_mutex.unlock(self.io);
        for (self.out_queue.items) |frame| self.gpa.free(frame.data);
        self.out_queue.clearRetainingCapacity();
        self.out_bytes = 0;
    }

    fn deinitQueue(self: *Attachment) void {
        self.out_mutex.lockUncancelable(self.io);
        defer self.out_mutex.unlock(self.io);
        for (self.out_queue.items) |frame| self.gpa.free(frame.data);
        self.out_queue.deinit(self.gpa);
        self.out_queue = .empty;
        self.out_bytes = 0;
    }

    pub fn sendRaw(self: *Attachment, data: []const u8, op: http.Server.WebSocket.Opcode) !void {
        if (!self.alive.load(.acquire)) return error.Closed;
        self.out_mutex.lockUncancelable(self.io);
        defer self.out_mutex.unlock(self.io);
        if (self.out_closed) return error.Closed;
        if (self.out_queue.items.len >= max_out_frames) return error.QueueFull;
        if (self.out_bytes + data.len > max_out_bytes) return error.QueueFull;
        const copy = self.gpa.dupe(u8, data) catch return error.OutOfMemory;
        self.out_queue.append(self.gpa, .{ .data = copy, .op = op }) catch {
            self.gpa.free(copy);
            return error.OutOfMemory;
        };
        self.out_bytes += copy.len;
        self.out_cond.signal(self.io);
    }

    pub fn sendText(self: *Attachment, data: []const u8) !void {
        return self.sendRaw(data, .text);
    }

    fn writerLoop(self: *Attachment) void {
        while (true) {
            self.out_mutex.lockUncancelable(self.io);
            while (self.out_queue.items.len == 0 and !self.out_closed) {
                self.out_cond.waitUncancelable(self.io, &self.out_mutex);
            }
            if (self.out_queue.items.len == 0 and self.out_closed) {
                self.out_mutex.unlock(self.io);
                return;
            }
            const frame = self.out_queue.orderedRemove(0);
            self.out_bytes -= frame.data.len;
            self.out_mutex.unlock(self.io);

            self.send_mutex.lockUncancelable(self.io);
            self.ws.writeMessage(frame.data, frame.op) catch {
                self.send_mutex.unlock(self.io);
                self.alive.store(false, .release);
                self.stream.shutdown(self.io, .both) catch {};
                self.gpa.free(frame.data);
                return;
            };
            self.send_mutex.unlock(self.io);
            const closing = frame.op == .connection_close;
            self.gpa.free(frame.data);
            if (closing) {
                self.stream.shutdown(self.io, .both) catch {};
                return;
            }
        }
    }
};

/// 会话被新前端接管时发给旧前端的 WebSocket 关闭码。
///
/// 浏览器拿到这个码就知道“不是我掉线，是别的窗口接管了”，因此不会自动重连；
/// 否则两个页面会互相把对方踢下线，来回争抢同一个 shell。
const taken_over_close = [2]u8{ 0x0F, 0xA1 }; // 4001

fn sendTakenOver(att: *Attachment) bool {
    // 只入队，不在这里写 socket：attach 持有 manager/session 锁，任何阻塞写
    // 都会把整个接管路径卡死。写线程空闲时会发出 4001；如果它正卡在慢客户端
    // 的写操作里，sweep 会在 2 秒后强制关闭连接，旧页面最多按 1006 处理。
    att.dropQueued();
    att.sendRaw(&taken_over_close, .connection_close) catch return false;
    return true;
}

const Retired = struct {
    att: *Attachment,
    deadline_ns: i96,
};

pub const Manager = struct {
    io: Io,
    gpa: Allocator,
    cfg: *const config.Config,
    /// 登录会话校验由 server 在启动时绑定；单元测试里的 Manager 不需要。
    auth_state: ?*auth.Auth = null,
    mutex: Io.Mutex = .init,
    sessions: std.ArrayList(*Session) = .empty,
    /// 被接管、但还没 detach 的旧前端。写线程如果卡住，由 sweep 在 2 秒后
    /// 直接 shutdown，避免旧连接永久占着 socket，也保证 attach 不必等它。
    retire_mutex: Io.Mutex = .init,
    retiring: std.ArrayList(Retired) = .empty,
    /// 当前还挂着的 WebSocket 前端数量；退出时用来判断是否可以安全释放会话。
    live_attachments: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    pub fn init(io: Io, gpa: Allocator, cfg: *const config.Config) Manager {
        return .{ .io = io, .gpa = gpa, .cfg = cfg };
    }

    /// 只释放列表本身；会话应当在 shutdown() 里清理干净。
    pub fn deinit(self: *Manager) void {
        self.retiring.deinit(self.gpa);
        self.sessions.deinit(self.gpa);
    }

    fn retire(self: *Manager, att: *Attachment) void {
        self.retire_mutex.lockUncancelable(self.io);
        defer self.retire_mutex.unlock(self.io);
        self.retiring.append(self.gpa, .{
            .att = att,
            .deadline_ns = self.now() + 2 * std.time.ns_per_s,
        }) catch {
            att.stream.shutdown(self.io, .both) catch {};
        };
    }

    fn unretire(self: *Manager, att: *Attachment) void {
        self.retire_mutex.lockUncancelable(self.io);
        defer self.retire_mutex.unlock(self.io);
        var i: usize = 0;
        while (i < self.retiring.items.len) : (i += 1) {
            if (self.retiring.items[i].att == att) {
                _ = self.retiring.swapRemove(i);
                return;
            }
        }
    }

    fn sweepRetiring(self: *Manager, ts: i96) void {
        self.retire_mutex.lockUncancelable(self.io);
        defer self.retire_mutex.unlock(self.io);
        var i: usize = 0;
        while (i < self.retiring.items.len) {
            const r = self.retiring.items[i];
            if (ts < r.deadline_ns) {
                i += 1;
                continue;
            }
            _ = self.retiring.swapRemove(i);
            r.att.stream.shutdown(self.io, .both) catch {};
        }
    }

    fn shutAttachment(self: *Manager, att: *Attachment) void {
        att.alive.store(false, .release);
        att.stream.shutdown(self.io, .both) catch {};
    }

    /// 注销/过期时结束一个登录会话拥有的全部终端：关闭前端并杀掉 shell。
    /// 不能只关 WebSocket：否则旧 shell 会继续运行，而且新登录只要拿到旧的
    /// session id 就还能接回它（session id 也会出现在代理日志的 URL 里）。
    pub fn revokeAuthSession(self: *Manager, session_id: [16]u8) void {
        self.revokeSessions(session_id, null);
    }

    /// 定期复查登录会话。会话过期/被淘汰后，终端也必须跟着结束。
    pub fn enforceAuth(self: *Manager, auth_state: *auth.Auth) void {
        self.revokeSessions(null, auth_state);
    }

    fn revokeSessions(
        self: *Manager,
        owner: ?[16]u8,
        auth_state: ?*auth.Auth,
    ) void {
        self.mutex.lockUncancelable(self.io);
        var i: usize = 0;
        while (i < self.sessions.items.len) {
            const s = self.sessions.items[i];
            s.mutex.lockUncancelable(self.io);

            const revoke = if (owner) |id|
                std.mem.eql(u8, &s.auth_session, &id)
            else
                !(auth_state orelse unreachable).sessionValid(&s.auth_session);

            // 同一轮里可能已经标记过；不要每秒重复扫 /proc、重复杀进程。
            const first = revoke and !s.closing;
            if (first) {
                if (s.attachment) |att| self.shutAttachment(att);
                s.closing = true;
            }
            const destroy_now = revoke and s.attachment == null and s.attachments == 0;
            s.mutex.unlock(self.io);

            if (destroy_now) {
                self.destroyLocked(s);
            } else {
                if (first) self.stopLocked(s);
                i += 1;
            }
        }
        self.mutex.unlock(self.io);

        // 被接管、正在 retire 的旧前端也要按同一个登录会话关掉。
        self.retire_mutex.lockUncancelable(self.io);
        defer self.retire_mutex.unlock(self.io);
        for (self.retiring.items) |r| {
            const revoke = if (owner) |id|
                std.mem.eql(u8, &r.att.auth_session, &id)
            else
                !(auth_state orelse unreachable).sessionValid(&r.att.auth_session);
            if (revoke) self.shutAttachment(r.att);
        }
    }

    fn now(self: *Manager) i96 {
        return Io.Clock.awake.now(self.io).nanoseconds;
    }

    /// attach 时不能无限等 session 锁：慢客户端可能让 pump 长时间卡在写 socket 上。
    fn lockSessionBounded(self: *Manager, s: *Session, timeout_ms: u32) bool {
        var waited: u32 = 0;
        while (!s.mutex.tryLock()) {
            if (waited >= timeout_ms) return false;
            Io.sleep(self.io, Io.Duration.fromMilliseconds(2), .real) catch return false;
            waited += 2;
        }
        return true;
    }

    /// 找到已有会话就 attach；否则创建新会话。整个过程持有 manager 锁，
    /// 保证 sweep 不会在 attach 期间释放会话。
    pub fn attach(
        self: *Manager,
        att: *Attachment,
        session_id: ?[16]u8,
        offset: u64,
    ) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // 票据/握手可能刚好和注销并发；拿到 manager 锁后再确认一次，避免
        // 注销流程已经清空会话后又新建一个属于已失效登录会话的 shell。
        if (self.auth_state) |a| {
            if (!a.sessionValid(&att.auth_session)) return error.Unauthorized;
        }

        const session = blk: {
            if (session_id) |sid| {
                if (self.findLocked(sid)) |found| {
                    if (!self.lockSessionBounded(found, 250)) return error.SessionBusy;
                    // 只有同一个登录会话才能接回已有 shell；注销后重新登录拿着
                    // 旧 session id 进来时，必须得到一个新会话，不能接管旧 shell。
                    const owned = std.mem.eql(u8, &found.auth_session, &att.auth_session);
                    // closed/closing 的会话不能再接；但旧前端可能还持有指针。
                    const reusable = owned and !found.closed and !found.closing;
                    const busy = found.attachment != null or found.attachments > 0;
                    found.mutex.unlock(self.io);
                    if (reusable) break :blk found;
                    // 只回收自己会话组里已经空闲的旧壳；不能销毁别的登录会话。
                    if (owned and !busy) self.destroyLocked(found);
                }
            }
            break :blk try self.createLocked(att.auth_session);
        };

        if (!self.lockSessionBounded(session, 250)) return error.SessionBusy;
        defer session.mutex.unlock(self.io);

        // 同一个会话被另一个前端接管时，先踢掉旧的。旧 Attachment 仍算一个
        // ref，必须等它自己 detach 后才能释放 Session。
        if (session.attachment) |old| {
            // 先入队 close：sendRaw 会检查 alive，不能先置 false。
            if (sendTakenOver(old)) {
                old.alive.store(false, .release);
                self.retire(old);
            } else {
                old.alive.store(false, .release);
                old.stream.shutdown(self.io, .both) catch {};
            }
            session.attachment = null;
        }

        const total = session.total;
        const start_abs = session.start_abs;
        var from = offset;
        if (from > total) from = total;
        var gap_lost: u64 = 0;
        if (from < start_abs) {
            gap_lost = start_abs - from;
            from = start_abs;
        }

        att.session = session;
        session.attachments += 1;
        session.last_activity_ns = self.now();
        _ = self.live_attachments.fetchAdd(1, .acq_rel);
        errdefer {
            att.session = null;
            if (session.attachments > 0) session.attachments -= 1;
            _ = self.live_attachments.fetchSub(1, .acq_rel);
        }

        var hello_buf: [128]u8 = undefined;
        const hello = std.fmt.bufPrint(
            &hello_buf,
            "{{\"t\":\"ready\",\"session\":\"{s}\",\"offset\":{d}}}",
            .{ std.fmt.bytesToHex(session.id, .lower), from },
        ) catch "{\"t\":\"ready\",\"offset\":0}";
        try att.sendText(hello);

        if (gap_lost > 0) {
            var gap_buf: [80]u8 = undefined;
            const note = std.fmt.bufPrint(&gap_buf, "{{\"t\":\"gap\",\"lost\":{d}}}", .{gap_lost}) catch
                "{\"t\":\"gap\"}";
            att.sendText(note) catch {};
        }

        const count: usize = @intCast(total - from);
        if (count > 0) {
            try session.sendRing(att, @intCast(from - start_abs), count);
        }

        if (session.cwd_valid) {
            sendCwd(att, session.cwd[0..session.cwd_len]) catch {};
        }

        session.attachment = att;
    }

    pub fn detach(self: *Manager, att: *Attachment) void {
        const session = att.session orelse {
            self.unretire(att);
            return;
        };
        // 必须先拿 session 锁再 unretire：attach 在持有同一把锁时把旧前端加入
        // retiring。否则 detach 可能先查不到条目、attach 随后又加入，留下悬空指针。
        session.mutex.lockUncancelable(self.io);
        self.unretire(att);
        att.session = null;
        if (session.attachment == att) session.attachment = null;
        session.last_activity_ns = self.now();
        if (session.attachments > 0) session.attachments -= 1;
        session.mutex.unlock(self.io);

        _ = self.live_attachments.fetchSub(1, .acq_rel);
        // closing 且 refs 变为 0 的会话交给 sweep 回收。不在这里拿着裸 Session*
        // 去抢 manager 锁：sweep 可能已经先把它释放，指针身份比较虽然不 deref，
        // 但多一次跨锁生命周期判断只会更脆弱。
    }

    /// 前端主动 {t:"close"}：立刻结束 shell，而不是留在后台等 TTL。
    pub fn destroyAttached(self: *Manager, att: *Attachment) void {
        const session = att.session orelse {
            att.alive.store(false, .release);
            return;
        };
        att.session = null;
        att.alive.store(false, .release);
        // 先叫醒可能正卡在写终端输出的 pump，再拿 session 锁，避免关闭分屏被慢客户端拖住。
        att.stream.shutdown(self.io, .both) catch {};

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // 释放引用必须和 session 的事件在同一把锁下；释放后不再解引用 session。
        var destroy_now = false;
        var stop_now = false;
        if (self.containsLocked(session)) {
            session.mutex.lockUncancelable(self.io);
            const was_current = session.attachment == att;
            if (was_current) session.attachment = null;
            if (session.attachments > 0) session.attachments -= 1;
            const left = session.attachments;
            if (was_current and left > 0) {
                // 旧前端被顶掉后还没 detach；先把 shell/pump 停掉，等最后一个 ref。
                session.closing = true;
                stop_now = true;
            } else if (left == 0 and session.attachment == null and
                (was_current or session.closing))
            {
                destroy_now = true;
            }
            session.mutex.unlock(self.io);
        }

        _ = self.live_attachments.fetchSub(1, .acq_rel);

        if (stop_now) self.stopLocked(session);
        if (destroy_now) self.destroyLocked(session);
    }

    /// 定期回收：没有前端且空闲超过 pty_idle_minutes 的会话，以及已经退出的会话。
    pub fn sweep(self: *Manager) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const ts = self.now();
        self.sweepRetiring(ts);
        const idle_minutes = self.cfg.pty_idle_minutes;
        const idle_ns: i96 = @as(i96, @intCast(idle_minutes)) * 60 * @as(i96, std.time.ns_per_s);

        var i: usize = 0;
        while (i < self.sessions.items.len) {
            const s = self.sessions.items[i];
            // 不阻塞在可能卡住写 socket 的 session 上；下一轮再试。
            if (!s.mutex.tryLock()) {
                i += 1;
                continue;
            }
            const detached = s.attachment == null and s.attachments == 0;
            const expired = if (s.closing)
                true
            else if (s.closed)
                ts - s.closed_ns > closed_grace_ns
            else if (idle_minutes == 0)
                true
            else
                ts - s.last_activity_ns > idle_ns;
            s.mutex.unlock(self.io);

            if (detached and expired) {
                self.destroyLocked(s);
            } else {
                i += 1;
            }
        }
    }

    /// 退出兜底：只杀 shell（连同后台作业），不释放任何会话结构。
    /// 只应在连接线程可能还引用 manager 时使用。
    pub fn killChildren(self: *Manager) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.sessions.items) |s| {
            s.stopping.store(true, .release);
            process.killSessionProcesses(self.io, s.child);
            _ = linux.kill(-s.child, .KILL);
            _ = linux.kill(s.child, .KILL);
        }
    }

    /// 优雅退出：先叫醒所有前端连接，等它们 detach，再回收会话。
    /// 超时仍有连接没退出时宁可不释放内存，也不冒 use-after-free 的风险。
    pub fn shutdown(self: *Manager) void {
        self.mutex.lockUncancelable(self.io);
        for (self.sessions.items) |s| {
            s.mutex.lockUncancelable(self.io);
            if (s.attachment) |att| {
                att.alive.store(false, .release);
                att.stream.shutdown(self.io, .both) catch {};
            }
            s.mutex.unlock(self.io);
        }
        self.mutex.unlock(self.io);

        var waited: u32 = 0;
        while (self.live_attachments.load(.acquire) > 0 and waited < 200) : (waited += 1) {
            Io.sleep(self.io, Io.Duration.fromMilliseconds(10), .real) catch break;
        }

        if (self.live_attachments.load(.acquire) == 0) {
            self.killAll();
        } else {
            // 连接线程还没退干净：只杀 shell，不释放会话结构。
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            for (self.sessions.items) |s| _ = linux.kill(-s.child, .KILL);
        }
    }

    pub fn killAll(self: *Manager) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (self.sessions.items.len > 0) {
            const s = self.sessions.items[self.sessions.items.len - 1];
            self.destroyLocked(s);
        }
    }

    fn containsLocked(self: *Manager, needle: *Session) bool {
        for (self.sessions.items) |s| if (s == needle) return true;
        return false;
    }

    fn findLocked(self: *Manager, id: [16]u8) ?*Session {
        for (self.sessions.items) |s| {
            if (std.mem.eql(u8, &s.id, &id)) return s;
        }
        return null;
    }

    /// 优先淘汰已退出/最久没活动的空闲会话。
    fn evictOneLocked(self: *Manager) ?*Session {
        var victim: ?*Session = null;
        var victim_score: i96 = std.math.maxInt(i96);
        for (self.sessions.items) |s| {
            if (!s.mutex.tryLock()) continue;
            const free = s.attachment == null and s.attachments == 0;
            const score: i96 = if (s.closed or s.closing) 0 else s.last_activity_ns;
            s.mutex.unlock(self.io);
            if (free and score < victim_score) {
                victim_score = score;
                victim = s;
            }
        }
        return victim;
    }

    fn createLocked(self: *Manager, auth_session: [16]u8) !*Session {
        if (self.sessions.items.len >= self.cfg.max_sessions) {
            if (self.evictOneLocked()) |victim| {
                self.destroyLocked(victim);
            } else {
                return error.TooManySessions;
            }
        }

        const spawned = pty.spawn(self.io, self.gpa, .{
            .shell = self.cfg.shell,
            .environ = self.cfg.environ,
            .cols = 80,
            .rows = 24,
        }) catch return error.PtySpawnFailed;

        const s = self.gpa.create(Session) catch {
            process.killChild(spawned.child);
            _ = linux.close(spawned.master);
            return error.OutOfMemory;
        };
        const buf = self.gpa.alloc(u8, initial_ring_capacity) catch {
            self.gpa.destroy(s);
            process.killChild(spawned.child);
            _ = linux.close(spawned.master);
            return error.OutOfMemory;
        };

        var id: [16]u8 = undefined;
        self.io.random(&id);

        s.* = .{
            .manager = self,
            .id = id,
            .auth_session = auth_session,
            .master = spawned.master,
            .child = spawned.child,
            .buf = buf,
            .buf_max = ring_capacity,
            .last_activity_ns = self.now(),
        };

        self.sessions.append(self.gpa, s) catch |err| {
            self.gpa.free(buf);
            self.gpa.destroy(s);
            process.killChild(spawned.child);
            _ = linux.close(spawned.master);
            return err;
        };

        s.pump_thread = std.Thread.spawn(.{}, pump, .{s}) catch |err| {
            _ = self.sessions.pop();
            self.gpa.free(buf);
            self.gpa.destroy(s);
            process.killChild(spawned.child);
            _ = linux.close(spawned.master);
            return err;
        };

        const sid = std.fmt.bytesToHex(s.id[0..4].*, .lower);
        std.debug.print("会话创建 sid={s} pid={d}\n", .{ sid[0..], s.child });
        return s;
    }

    /// 先停 shell 和 pump，但不回收内存；旧 Attachment 还可能用着 Session/master。
    fn stopLocked(self: *Manager, s: *Session) void {
        // 后台作业会被 job control 拆到新的进程组，单杀 -pid 收不干净；
        // 先按 session id 扫一遍 /proc，再 HUP shell（pump 用 poll + stopping，
        // 不依赖 slave 先关闭，避免 join 永久卡住）。
        s.stopping.store(true, .release);
        process.killSessionProcesses(self.io, s.child);
        _ = linux.kill(-s.child, .HUP);
        _ = linux.kill(s.child, .HUP);
        if (s.pump_thread) |t| {
            t.join();
            s.pump_thread = null;
        }
    }

    fn destroyLocked(self: *Manager, s: *Session) void {
        const sid = std.fmt.bytesToHex(s.id[0..4].*, .lower);
        std.debug.print("会话回收 sid={s} pid={d}\n", .{ sid[0..], s.child });
        for (self.sessions.items, 0..) |item, i| {
            if (item == s) {
                _ = self.sessions.swapRemove(i);
                break;
            }
        }

        self.stopLocked(s);
        pty.reap(s.child);
        _ = linux.close(s.master);
        self.gpa.free(s.buf);
        self.gpa.destroy(s);
    }
};

const Session = struct {
    manager: *Manager,
    id: [16]u8,
    /// 创建这个 shell 的登录会话；注销/过期后整个 shell 一起结束。
    auth_session: [16]u8 = @splat(0),
    master: posix.fd_t,
    child: posix.pid_t,
    pump_thread: ?std.Thread = null,
    mutex: Io.Mutex = .init,
    buf: []u8,
    /// 允许增长到的上限；0 表示固定容量（测试用栈缓冲）。
    buf_max: usize = 0,
    /// buf 中有效数据的起点（环形）。
    start: usize = 0,
    len: usize = 0,
    /// 缓冲区里最旧字节的绝对偏移。
    start_abs: u64 = 0,
    /// 从创建到现在累计输出的字节数。
    total: u64 = 0,
    attachment: ?*Attachment = null,
    /// 仍可能持有本 Session 指针的 Attachment 数量（包括被顶掉的旧前端）。
    /// 只有它为 0 时才可以释放 Session。
    attachments: u32 = 0,
    /// 已决定销毁，但还有旧 Attachment 未 detach；最后一个 ref 负责真正回收。
    closing: bool = false,
    /// destroy 时置位，让 pump 的 poll 循环尽快退出。
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    closed: bool = false,
    closed_ns: i96 = 0,
    last_activity_ns: i96 = 0,
    /// shell 最近一次被观测到的 cwd（绝对路径）。
    cwd: [std.fs.max_path_bytes]u8 = undefined,
    cwd_len: usize = 0,
    cwd_valid: bool = false,

    fn now(self: *Session) i96 {
        return Io.Clock.awake.now(self.manager.io).nanoseconds;
    }

    fn appendLocked(self: *Session, data: []const u8) void {
        self.total += data.len;

        // 空闲会话只占 64 KiB；输出多了再翻倍到 512 KiB，避免一开始就全量常驻。
        const needed = self.len + data.len;
        if (needed > self.buf.len and self.buf.len < self.buf_max) {
            var want = self.buf.len;
            while (want < needed and want < self.buf_max) want *= 2;
            if (want > self.buf_max) want = self.buf_max;
            if (want > self.buf.len) _ = self.growLocked(want);
        }

        if (data.len >= self.buf.len) {
            // 单次输出比整个缓冲还大，只保留最后 buf.len 字节。
            const tail = data[data.len - self.buf.len ..];
            @memcpy(self.buf, tail);
            self.start = 0;
            self.len = self.buf.len;
            self.start_abs = self.total - self.buf.len;
            return;
        }

        const overflow = if (self.len + data.len > self.buf.len)
            self.len + data.len - self.buf.len
        else
            0;
        if (overflow > 0) {
            self.start = (self.start + overflow) % self.buf.len;
            self.len -= overflow;
            self.start_abs += overflow;
        }

        const write_at = (self.start + self.len) % self.buf.len;
        const first = @min(data.len, self.buf.len - write_at);
        @memcpy(self.buf[write_at..][0..first], data[0..first]);
        if (first < data.len) {
            @memcpy(self.buf[0 .. data.len - first], data[first..]);
        }
        self.len += data.len;
    }

    /// 扩容并把环形内容按顺序搬成线性布局（start = 0）。失败时保持原缓冲。
    fn growLocked(self: *Session, want: usize) bool {
        const gpa = self.manager.gpa;
        const new_buf = gpa.alloc(u8, want) catch return false;
        const first = @min(self.len, self.buf.len - self.start);
        @memcpy(new_buf[0..first], self.buf[self.start..][0..first]);
        if (self.len > first) @memcpy(new_buf[first..self.len], self.buf[0 .. self.len - first]);
        gpa.free(self.buf);
        self.buf = new_buf;
        self.start = 0;
        return true;
    }

    /// 发送环形缓冲的一段；数据可能在物理上分成两段。
    fn sendRing(self: *Session, att: *Attachment, index: usize, count: usize) !void {
        if (count == 0) return;
        const begin = (self.start + index) % self.buf.len;
        const first = @min(count, self.buf.len - begin);
        try att.sendRaw(self.buf[begin..][0..first], .binary);
        if (first < count) {
            try att.sendRaw(self.buf[0 .. count - first], .binary);
        }
    }
};

fn readProcCwd(io: Io, child: posix.pid_t, buf: []u8) ?usize {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/cwd", .{child}) catch return null;
    return std.Io.Dir.readLinkAbsolute(io, path, buf) catch null;
}

/// 把 shell 的绝对 cwd 转成相对 `/` 的路径；文件面板固定以 `/` 为根。
fn relativeCwd(abs_raw: []const u8) ?[]const u8 {
    var abs = abs_raw;
    while (abs.len > 1 and abs[abs.len - 1] == '/') abs = abs[0 .. abs.len - 1];

    if (abs.len == 1 and abs[0] == '/') return "";
    if (abs.len > 1 and abs[0] == '/') return abs[1..];
    return null;
}

fn sendCwd(att: *Attachment, abs_raw: []const u8) !void {
    const rel = relativeCwd(abs_raw) orelse return;
    // JSON 会把每个控制字节转义成 6 个字符（`\u00XX`），按 6 倍预留，
    // 否则合法的控制字符目录名会让序列化失败并误关整个终端连接。
    var buf: [std.fs.max_path_bytes * 6 + 64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const Payload = struct {
        t: []const u8 = "cwd",
        path: []const u8,
    };
    std.json.Stringify.value(Payload{ .path = rel }, .{}, &w) catch return error.WriteFailed;
    try att.sendText(w.buffered());
}

/// 读取 shell 的 /proc/<pid>/cwd，变了才发；force 用于客户端主动请求。
pub fn refreshCwd(s: *Session, force: bool) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = readProcCwd(s.manager.io, s.child, &buf) orelse return;
    const abs = buf[0..n];
    if (!std.unicode.utf8ValidateSlice(abs)) return;

    s.mutex.lockUncancelable(s.manager.io);
    defer s.mutex.unlock(s.manager.io);

    const changed = !s.cwd_valid or !std.mem.eql(u8, s.cwd[0..s.cwd_len], abs);
    if (changed) {
        if (abs.len > s.cwd.len) return;
        @memcpy(s.cwd[0..abs.len], abs);
        s.cwd_len = abs.len;
        s.cwd_valid = true;
    }
    if (!changed and !force) return;

    const att = s.attachment orelse return;
    if (!att.alive.load(.acquire)) return;
    sendCwd(att, abs) catch {
        att.alive.store(false, .release);
        att.stream.shutdown(s.manager.io, .both) catch {};
    };
}

fn pump(s: *Session) void {
    var read_buf: [8192]u8 = undefined;
    var fds = [_]posix.pollfd{.{ .fd = s.master, .events = posix.POLL.IN, .revents = 0 }};
    // 500ms 一跳保证 stop 时的响应；cwd 每两跳查一次，空闲 /proc 读取减半。
    var idle_ticks: u8 = 0;
    var last_cwd_ns: i96 = 0;
    while (!s.stopping.load(.acquire)) {
        fds[0].revents = 0;
        const ready = posix.poll(&fds, 500) catch break;
        if (ready == 0) {
            idle_ticks +%= 1;
            if (idle_ticks % 2 == 1) refreshCwd(s, false);
            continue;
        }
        idle_ticks = 0;
        if (fds[0].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR) == 0) continue;
        const n = posix.read(s.master, &read_buf) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => break,
        };
        if (n == 0) break;

        const io = s.manager.io;
        s.mutex.lockUncancelable(io);
        s.appendLocked(read_buf[0..n]);
        // 只有还挂着前端时才用输出刷新活动时间：断线后后台程序继续输出
        // 也不应该让会话永远不过期。
        if (s.attachment != null) s.last_activity_ns = s.now();
        if (s.attachment) |att| {
            if (att.alive.load(.acquire)) {
                att.sendRaw(read_buf[0..n], .binary) catch {
                    att.alive.store(false, .release);
                    att.stream.shutdown(io, .both) catch {};
                };
            }
        }
        s.mutex.unlock(io);

        // `cd` 的提示符就是最后一块输出，没必要等下一次 500ms 空闲心跳才发现 cwd
        // 变了。输出后最多每 100ms 查一次，持续刷屏时每秒也只多读 10 次 /proc。
        const now_ns = Io.Clock.awake.now(io).nanoseconds;
        if (now_ns - last_cwd_ns >= 100 * std.time.ns_per_ms) {
            last_cwd_ns = now_ns;
            refreshCwd(s, false);
        }
    }

    const io = s.manager.io;
    s.mutex.lockUncancelable(io);
    s.closed = true;
    s.closed_ns = s.now();
    if (!s.stopping.load(.acquire)) {
        if (s.attachment) |att| {
            if (att.alive.load(.acquire)) {
                att.sendText("{\"t\":\"exit\"}") catch {};
                att.sendRaw("", .connection_close) catch {};
                att.stream.shutdown(io, .both) catch {};
            }
        }
    }
    s.mutex.unlock(io);
}

test "cwd relative to /" {
    try std.testing.expectEqualStrings("srv/work", relativeCwd("/srv/work").?);
    try std.testing.expectEqualStrings("srv/work", relativeCwd("/srv/work/").?);
    try std.testing.expectEqualStrings("", relativeCwd("/").?);
    try std.testing.expect(relativeCwd("srv/work") == null);
}

test "ring buffer replay offsets" {
    const io = std.testing.io;
    var cfg = config.Config{};
    var m = Manager.init(io, std.testing.allocator, &cfg);
    // 不启动真实 PTY：手工构造一个 Session 测环形逻辑。
    var buf: [16]u8 = undefined;
    var s: Session = .{
        .manager = &m,
        .id = @splat(0),
        .master = -1,
        .child = -1,
        .buf = &buf,
    };
    s.appendLocked("abcdefghij");
    try std.testing.expectEqual(@as(usize, 10), s.len);
    try std.testing.expectEqual(@as(u64, 0), s.start_abs);
    s.appendLocked("klmnopqrst");
    // 16 字节容量，保留最后 16 字节。
    try std.testing.expectEqual(@as(usize, 16), s.len);
    try std.testing.expectEqual(@as(u64, 4), s.start_abs);
    try std.testing.expectEqual(@as(u64, 20), s.total);
}

test "ring buffer keeps the newest bytes for arbitrary appends" {
    const io = std.testing.io;
    var cfg = config.Config{};
    var m = Manager.init(io, std.testing.allocator, &cfg);

    var storage: [37]u8 = undefined;
    var s: Session = .{
        .manager = &m,
        .id = @splat(0),
        .master = -1,
        .child = -1,
        .buf = &storage,
    };

    var reference: std.ArrayList(u8) = .empty;
    defer reference.deinit(std.testing.allocator);

    var seed: u64 = 0x9e3779b97f4a7c15;
    var step: usize = 0;
    while (step < 300) : (step += 1) {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        const len = 1 + @as(usize, @intCast((seed >> 40) % 60));
        var tmp: [64]u8 = undefined;
        for (tmp[0..len]) |*b| {
            seed = seed *% 6364136223846793005 +% 1442695040888963407;
            b.* = @truncate(seed >> 33);
        }

        s.appendLocked(tmp[0..len]);
        try reference.appendSlice(std.testing.allocator, tmp[0..len]);

        const keep = @min(reference.items.len, storage.len);
        try std.testing.expectEqual(keep, s.len);
        try std.testing.expectEqual(reference.items.len, s.total);
        try std.testing.expectEqual(reference.items.len - keep, s.start_abs);

        var got: [storage.len]u8 = undefined;
        for (0..s.len) |i| got[i] = s.buf[(s.start + i) % s.buf.len];
        try std.testing.expectEqualSlices(
            u8,
            reference.items[reference.items.len - keep ..],
            got[0..s.len],
        );
    }
}

test "ring buffer grows on demand up to its cap" {
    const io = std.testing.io;
    var cfg = config.Config{};
    var m = Manager.init(io, std.testing.allocator, &cfg);
    defer m.deinit();

    var s: Session = .{
        .manager = &m,
        .id = @splat(0),
        .master = -1,
        .child = -1,
        .buf = try std.testing.allocator.alloc(u8, 4),
        .buf_max = 16,
    };
    defer std.testing.allocator.free(s.buf);

    s.appendLocked("ab");
    try std.testing.expectEqual(@as(usize, 4), s.buf.len);
    s.appendLocked("cdef");
    try std.testing.expectEqual(@as(usize, 8), s.buf.len);
    s.appendLocked("ghijklmn");
    try std.testing.expectEqual(@as(usize, 16), s.buf.len);
    try std.testing.expectEqual(@as(u64, 14), s.total);
    try std.testing.expectEqual(@as(usize, 14), s.len);
    try std.testing.expectEqual(@as(u64, 0), s.start_abs);

    var got: [16]u8 = undefined;
    for (0..s.len) |i| got[i] = s.buf[(s.start + i) % s.buf.len];
    try std.testing.expectEqualStrings("abcdefghijklmn", got[0..s.len]);

    s.appendLocked("op");
    s.appendLocked("qr");
    try std.testing.expectEqual(@as(usize, 16), s.buf.len);
    try std.testing.expectEqual(@as(u64, 2), s.start_abs);
    for (0..s.len) |i| got[i] = s.buf[(s.start + i) % s.buf.len];
    try std.testing.expectEqualStrings("cdefghijklmnopqr", got[0..s.len]);
}

test "session id parsing rejects junk" {
    try std.testing.expect(parseSessionId("0123456789abcdef0123456789abcdef") != null);
    try std.testing.expect(parseSessionId(null) == null);
    try std.testing.expect(parseSessionId("0123456789abcdef") == null);
    try std.testing.expect(parseSessionId("0123456789abcdef0123456789abcdeg") == null);
    try std.testing.expectEqual(@as(u64, 123), parseOffset("123"));
    try std.testing.expectEqual(@as(u64, 0), parseOffset("nope"));
    try std.testing.expectEqual(@as(u64, 0), parseOffset(null));
}

fn testAttachment() Attachment {
    return .{
        .io = std.testing.io,
        .gpa = std.testing.allocator,
        .ws = undefined,
        .stream = undefined,
    };
}

test "output queue is bounded by frame count as well as bytes" {
    var att = testAttachment();
    defer att.deinitQueue();

    var i: usize = 0;
    while (i < Attachment.max_out_frames) : (i += 1) try att.sendRaw("", .pong);
    try std.testing.expectError(error.QueueFull, att.sendRaw("", .pong));
    try std.testing.expectEqual(@as(usize, 0), att.out_bytes);
    try std.testing.expectEqual(Attachment.max_out_frames, att.out_queue.items.len);
}

test "cwd control bytes fit the escaped json buffer" {
    var att = testAttachment();
    defer att.deinitQueue();

    var path: [2001]u8 = undefined;
    path[0] = '/';
    @memset(path[1..], 1);
    try sendCwd(&att, &path);
    try std.testing.expectEqual(@as(usize, 1), att.out_queue.items.len);
    try std.testing.expect(std.mem.indexOf(u8, att.out_queue.items[0].data, "\\u0001") != null);
}
