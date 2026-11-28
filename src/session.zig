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
    const Frame = struct {
        data: []u8,
        op: http.Server.WebSocket.Opcode,
    };

    fn startWriter(self: *Attachment) !void {
        self.writer = try std.Thread.spawn(.{}, writerLoop, .{self});
    }

    fn stopWriter(self: *Attachment) void {
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
        self.dropQueued();
    }

    fn dropQueued(self: *Attachment) void {
        self.out_mutex.lockUncancelable(self.io);
        defer self.out_mutex.unlock(self.io);
        for (self.out_queue.items) |frame| self.gpa.free(frame.data);
        self.out_queue.clearRetainingCapacity();
        self.out_bytes = 0;
    }

    fn sendRaw(self: *Attachment, data: []const u8, op: http.Server.WebSocket.Opcode) !void {
        if (!self.alive.load(.acquire)) return error.Closed;
        self.out_mutex.lockUncancelable(self.io);
        defer self.out_mutex.unlock(self.io);
        if (self.out_closed) return error.Closed;
        if (self.out_bytes + data.len > max_out_bytes) return error.QueueFull;
        const copy = self.gpa.dupe(u8, data) catch return error.OutOfMemory;
        self.out_queue.append(self.gpa, .{ .data = copy, .op = op }) catch {
            self.gpa.free(copy);
            return error.OutOfMemory;
        };
        self.out_bytes += copy.len;
        self.out_cond.signal(self.io);
    }

    fn sendText(self: *Attachment, data: []const u8) !void {
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

    /// 注销某个登录会话时立即关闭它建立的所有终端 WebSocket。
    pub fn closeAuthSession(self: *Manager, session_id: [16]u8) void {
        self.mutex.lockUncancelable(self.io);
        for (self.sessions.items) |s| {
            s.mutex.lockUncancelable(self.io);
            if (s.attachment) |att| {
                if (std.mem.eql(u8, &att.auth_session, &session_id)) self.shutAttachment(att);
            }
            s.mutex.unlock(self.io);
        }
        self.mutex.unlock(self.io);

        self.retire_mutex.lockUncancelable(self.io);
        defer self.retire_mutex.unlock(self.io);
        for (self.retiring.items) |r| {
            if (std.mem.eql(u8, &r.att.auth_session, &session_id)) self.shutAttachment(r.att);
        }
    }

    /// 定期复查已升级 WebSocket 绑定的登录会话。HTTP 会话过期/被其他窗口
    /// 注销后，终端也必须跟着断开；不能只在升级那一刻验一次 Cookie。
    pub fn enforceAuth(self: *Manager, auth_state: *auth.Auth) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        for (self.sessions.items) |s| {
            if (!s.mutex.tryLock()) continue;
            if (s.attachment) |att| {
                if (!auth_state.sessionValid(&att.auth_session)) self.shutAttachment(att);
            }
            s.mutex.unlock(self.io);
        }

        self.retire_mutex.lockUncancelable(self.io);
        defer self.retire_mutex.unlock(self.io);
        for (self.retiring.items) |r| {
            if (!auth_state.sessionValid(&r.att.auth_session)) self.shutAttachment(r.att);
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

        const session = blk: {
            if (session_id) |sid| {
                if (self.findLocked(sid)) |found| {
                    if (!self.lockSessionBounded(found, 250)) return error.SessionBusy;
                    // closed/closing 的会话不能再接；但旧前端可能还持有指针。
                    const reusable = !found.closed and !found.closing;
                    const busy = found.attachment != null or found.attachments > 0;
                    found.mutex.unlock(self.io);
                    if (reusable) break :blk found;
                    if (!busy) self.destroyLocked(found);
                }
            }
            break :blk try self.createLocked();
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
            killSessionProcesses(self.io, s.child);
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

    fn createLocked(self: *Manager) !*Session {
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
            killChild(spawned.child);
            _ = linux.close(spawned.master);
            return error.OutOfMemory;
        };
        const buf = self.gpa.alloc(u8, initial_ring_capacity) catch {
            self.gpa.destroy(s);
            killChild(spawned.child);
            _ = linux.close(spawned.master);
            return error.OutOfMemory;
        };

        var id: [16]u8 = undefined;
        self.io.random(&id);

        s.* = .{
            .manager = self,
            .id = id,
            .master = spawned.master,
            .child = spawned.child,
            .buf = buf,
            .buf_max = ring_capacity,
            .last_activity_ns = self.now(),
        };

        self.sessions.append(self.gpa, s) catch |err| {
            self.gpa.free(buf);
            self.gpa.destroy(s);
            killChild(spawned.child);
            _ = linux.close(spawned.master);
            return err;
        };

        s.pump_thread = std.Thread.spawn(.{}, pump, .{s}) catch |err| {
            _ = self.sessions.pop();
            self.gpa.free(buf);
            self.gpa.destroy(s);
            killChild(spawned.child);
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
        killSessionProcesses(self.io, s.child);
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

/// 结束 shell 所在的进程组；-pid 失败时再单独杀直接子进程，并回收僵尸。
fn killChild(child: posix.pid_t) void {
    _ = linux.kill(-child, .KILL);
    _ = linux.kill(child, .KILL);
    var status: i32 = 0;
    _ = linux.waitpid(child, &status, 0);
}

/// 杀掉同一 session（sid == shell pid）里的所有进程，包括 job control 拆出去的
/// 后台作业。只读 /proc/<pid>/stat 的第 6 个字段，Linux 专用。
fn killSessionProcesses(io: Io, sid: posix.pid_t) void {
    var proc = std.Io.Dir.openDirAbsolute(io, "/proc", .{ .iterate = true }) catch return;
    defer proc.close(io);

    var it = proc.iterate();
    while (it.next(io) catch return) |entry| {
        const pid = std.fmt.parseInt(posix.pid_t, entry.name, 10) catch continue;
        if (pid <= 1 or pid == sid) continue;

        var path_buf: [64]u8 = undefined;
        const path_raw = std.fmt.bufPrint(&path_buf, "/proc/{s}/stat", .{entry.name}) catch continue;
        path_buf[path_raw.len] = 0;
        const path = path_buf[0..path_raw.len :0];
        const fd = posix.openat(posix.AT.FDCWD, path, .{
            .ACCMODE = .RDONLY,
            .CLOEXEC = true,
        }, 0) catch continue;
        defer _ = linux.close(fd);

        var buf: [512]u8 = undefined;
        // 进程可能在 readdir 和 open/read 之间退出；直接用原始系统调用并把
        // ESRCH 当成“已经没了”，避免 std.Io 把 /proc 的竞态当成 programmer bug。
        const rc = linux.read(fd, &buf, buf.len);
        const n: usize = switch (linux.errno(rc)) {
            .SUCCESS => rc,
            else => continue,
        };
        if (n == 0) continue;
        const data = buf[0..n];

        // "pid (comm) state ppid pgrp session ..."；comm 里可能有空格/括号。
        const rparen = std.mem.lastIndexOfScalar(u8, data, ')') orelse continue;
        var fields = std.mem.tokenizeScalar(u8, data[rparen + 1 ..], ' ');
        _ = fields.next() orelse continue; // state
        _ = fields.next() orelse continue; // ppid
        _ = fields.next() orelse continue; // pgrp
        const session_text = fields.next() orelse continue;
        const session = std.fmt.parseInt(posix.pid_t, session_text, 10) catch continue;
        if (session == sid) _ = linux.kill(pid, .KILL);
    }
}

const Session = struct {
    manager: *Manager,
    id: [16]u8,
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
    var buf: [std.fs.max_path_bytes * 2 + 64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const Payload = struct {
        t: []const u8 = "cwd",
        path: []const u8,
    };
    std.json.Stringify.value(Payload{ .path = rel }, .{}, &w) catch return error.WriteFailed;
    try att.sendText(w.buffered());
}

/// 读取 shell 的 /proc/<pid>/cwd，变了才发；force 用于客户端主动请求。
fn refreshCwd(s: *Session, force: bool) void {
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

// ---------------------------------------------------------------------------
// WebSocket 前端
// ---------------------------------------------------------------------------

const Control = struct {
    t: []const u8 = "",
    cols: ?u16 = null,
    rows: ?u16 = null,
};

/// 解析一条控制消息。分配只发生在调用方提供的栈缓冲里，消息用完即弃。
fn parseControl(scratch: []u8, data: []const u8) !Control {
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
            else => "{\"t\":\"error\"}",
        };
        att.dropQueued();
        ws.writeMessage(body, .text) catch {};
        return err;
    };
    defer manager.detach(&att);

    // 控制消息都很小，用固定栈缓冲解析，避免每条心跳都走 page_allocator。
    var control_scratch: [1024]u8 = undefined;

    while (true) {
        const msg = ws.readSmallMessage() catch return;
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
                    refreshCwd(s, true);
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

test "session id parsing rejects junk" {
    try std.testing.expect(parseSessionId("0123456789abcdef0123456789abcdef") != null);
    try std.testing.expect(parseSessionId(null) == null);
    try std.testing.expect(parseSessionId("0123456789abcdef") == null);
    try std.testing.expect(parseSessionId("0123456789abcdef0123456789abcdeg") == null);
    try std.testing.expectEqual(@as(u64, 123), parseOffset("123"));
    try std.testing.expectEqual(@as(u64, 0), parseOffset("nope"));
    try std.testing.expectEqual(@as(u64, 0), parseOffset(null));
}
