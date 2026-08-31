//! event loop 骨架（M-2/M-3 合流点）—— 内核 timerfd → epoll → 宿主回调 →
//! quickjs job 队列 → guest JS，一条被驱动的真实链。
//! v1：一次性定时器（dshSetTimeout(cb, ms)），固定槽表（真实版挂 fiber/context）。
//! 验证：`zig build event-loop-smoke-run`。

const std = @import("std");
const linux = std.os.linux;

fn jsExc() c.JSValue {
    return .{ .u = .{ .int32 = 0 }, .tag = c.JS_TAG_EXCEPTION };
}

fn milliNow() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @as(i64, @intCast(@divTrunc(ts.nsec, 1_000_000)));
}

pub const c = @import("engine_c.zig").c;

// Full profiles legitimately keep watcher, timeout, subprocess, and plugin timers
// alive together; 16 slots made activation order look like a plugin failure.
const MAX_TIMERS = 128;

const TimerEntry = struct {
    fd: i32 = -1,
    id: c_int = 0,
    cb: c.JSValue,
    periodic: bool = false,
    used: bool = false,

    fn empty() TimerEntry {
        return .{ .fd = -1, .id = 0, .cb = undefined, .periodic = false, .used = false };
    }
};

/// 登记到宿主服务注册表（timer 方法经 JS_GetContextOpaque 拿 Loop）。
pub const serviceMethods = [_]@import("host_services.zig").Method{
    .{ .name = "setTimeout", .func = jsSetTimeout, .length = 2 },
    .{ .name = "setInterval", .func = jsSetInterval, .length = 2 },
    .{ .name = "clearTimer", .func = jsClearTimer, .length = 1 },
};

pub const Loop = struct {
    epoll_fd: i32 = -1,
    rt: ?*c.JSRuntime = null,
    ctx: ?*c.JSContext = null,
    timers: [MAX_TIMERS]TimerEntry = blk: {
        var t: [MAX_TIMERS]TimerEntry = undefined;
        for (&t) |*e| e.* = TimerEntry.empty();
        break :blk t;
    },
    /// 通用 fd 事件源回调（网关形态）：非 timer fd 的可读事件分派到这里
    /// （http_bridge.onLoopFdEvent 等）。宿主启动时设置；ctx 由 Loop 自身提供
    /// （事件驱动路径无 JS 调用帧，须从 loop.ctx 取）。
    onFdEvent: ?*const fn (ctx: ?*c.JSContext, fd: i32) void = null,

    pub fn init() !Loop {
        var self = Loop{};
        const efd = linux.epoll_create1(linux.EPOLL.CLOEXEC);
        if (efd < 0) return error.EpollFailed;
        self.epoll_fd = @intCast(efd);
        return self;
    }

    /// 把外部 fd 加入 epoll 观察（listen socket 等；http_bridge.start 经 ctx opaque 调用）。
    pub fn watchFd(self: *Loop, fd: i32) void {
        var ev = linux.epoll_event{
            .events = linux.EPOLL.IN,
            .data = .{ .fd = fd },
        };
        _ = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_ADD, fd, &ev);
    }

    pub fn attachEngine(self: *Loop, rt: ?*c.JSRuntime, ctx: ?*c.JSContext) void {
        self.rt = rt;
        self.ctx = ctx;
        // JS 全局注册：每条属性独立 NewCFunction（ref=1）→ SetPropertyStr 消费 →
        // ref=0。不复用同一函数对象，避免 ref 结算残留（曾泄漏 dshSetInterval/dshClearTimer）。
        const global = c.JS_GetGlobalObject(ctx);
        defer c.JS_FreeValue(ctx, global);
        _ = c.JS_SetPropertyStr(ctx, global, "dshSetTimeout", c.JS_NewCFunction(ctx, jsSetTimeout, "dshSetTimeout", 2));
        _ = c.JS_SetPropertyStr(ctx, global, "dshSetInterval", c.JS_NewCFunction(ctx, jsSetInterval, "dshSetInterval", 2));
        _ = c.JS_SetPropertyStr(ctx, global, "dshClearTimer", c.JS_NewCFunction(ctx, jsClearTimer, "dshClearTimer", 1));
        // 标准名面（cordis-plugin-timer 直接使用全局 setTimeout/setInterval）
        _ = c.JS_SetPropertyStr(ctx, global, "setTimeout", c.JS_NewCFunction(ctx, jsSetTimeout, "setTimeout", 2));
        _ = c.JS_SetPropertyStr(ctx, global, "setInterval", c.JS_NewCFunction(ctx, jsSetInterval, "setInterval", 2));
        _ = c.JS_SetPropertyStr(ctx, global, "clearTimeout", c.JS_NewCFunction(ctx, jsClearTimer, "clearTimeout", 1));
        _ = c.JS_SetPropertyStr(ctx, global, "clearInterval", c.JS_NewCFunction(ctx, jsClearTimer, "clearInterval", 1));
    }

    /// 驱动循环：直到所有定时器清空或超时。
    pub fn run(self: *Loop, timeout_ms: i32) void {
        var events: [8]linux.epoll_event = undefined;
        const deadline = milliNow() + @as(i64, timeout_ms);
        while (true) {
            const now = milliNow();
            if (now >= deadline) break;
            const remaining: i32 = @intCast(@min(@as(i64, 100), deadline - now));
            // epoll_wait 原始返回值：错误编码为 -errno（isize 负值）。
            // EINTR（如 serve 模式 TERM/INT 或其他已安装 handler 的信号）→ 重试；
            // 不查错会把负值当巨大 usize 事件数，越界读 events → 崩溃。
            const rc = linux.epoll_wait(self.epoll_fd, &events, events.len, remaining);
            const signed: isize = @bitCast(rc);
            if (signed < 0) {
                const err: linux.E = @enumFromInt(-signed);
                if (err == .INTR) continue;
                break;
            }
            const n: usize = @intCast(signed);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const fd: i32 = events[i].data.fd;
                if (self.timerIndexFor(fd)) |_| {
                    self.fireTimer(fd);
                } else if (self.onFdEvent) |f| {
                    f(self.ctx, fd);
                }
                self.drainJobs();
            }
            if (n == 0) {
                if (self.activeCount() == 0) break;
                continue;
            }
        }
    }

    pub fn deinit(self: *Loop) void {
        for (&self.timers) |*t| {
            if (t.used) {
                if (self.ctx) |ctx| c.JS_FreeValue(ctx, t.cb);
                if (t.fd >= 0) {
                    _ = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_DEL, t.fd, null);
                    _ = linux.close(t.fd);
                }
                t.* = TimerEntry.empty();
            }
        }
        if (self.epoll_fd >= 0) {
            _ = linux.close(self.epoll_fd);
            self.epoll_fd = -1;
        }
    }

    fn timerIndexFor(self: *Loop, fd: i32) ?usize {
        for (&self.timers, 0..) |t, i| {
            if (t.used and t.fd == fd) return i;
        }
        return null;
    }

    fn activeCount(self: *Loop) usize {
        var count: usize = 0;
        for (&self.timers) |*t| {
            if (t.used) count += 1;
        }
        return count;
    }

    /// 一次性定时器：读写 8 字节到期计数，JS_Call 回调，移除表项。
    fn fireTimer(self: *Loop, fd: i32) void {
        var consumed: u64 = 0;
        _ = linux.read(@intCast(fd), @ptrCast(&consumed), 8);
        var idx: usize = 0;
        var found: bool = false;
        while (idx < MAX_TIMERS) : (idx += 1) {
            if (self.timers[idx].used and self.timers[idx].fd == fd) {
                found = true;
                break;
            }
        }
        if (!found) return;
        const entry = self.timers[idx];
        const cb = entry.cb;
        const undef: c.JSValue = .{ .u = .{ .int32 = 0 }, .tag = c.JS_TAG_UNDEFINED };
        if (!entry.periodic) {
            // 一次性：先清表（防回调内经 clearTimeout 重入），cb 值保持存活至调用后。
            _ = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_DEL, fd, null);
            _ = linux.close(@intCast(fd));
            self.timers[idx] = TimerEntry.empty();
        }
        const result = c.JS_Call(self.ctx, cb, undef, 0, null);
        if (c.JS_IsException(result)) {
            const ex = c.JS_GetException(self.ctx);
            const msg = c.JS_ToCStringLen(self.ctx, null, ex);
            if (msg) |m| std.debug.print("[loop] timer callback failed: {s}\n", .{std.mem.span(m)});
            c.JS_FreeValue(self.ctx, ex);
        } else {
            c.JS_FreeValue(self.ctx, result);
        }
        if (!entry.periodic) {
            c.JS_FreeValue(self.ctx, cb);
        }
        // 周期任务：timerfd 自动重发，表项保留；其 cb 在 clear 时释放
    }

    /// quickjs job 队列排空（promise/microtask）。
    pub fn drainJobs(self: *Loop) void {
        var job_ctx: ?*c.JSContext = self.ctx;
        var guard: usize = 0;
        while (c.JS_ExecutePendingJob(self.rt, &job_ctx) > 0) : (guard += 1) {
            if (guard > 4096) break;
        }
    }
};

fn registerTimer(ctx: ?*c.JSContext, argv: [*c]const c.JSValueConst, periodic: bool) c.JSValue {
    if (!c.JS_IsFunction(ctx, argv[0])) {
        return c.JS_ThrowTypeError(ctx, "dshSetTimer(callback, ms) missing arguments", @as(c_int, 0));
    }
    var ms: c_int = 0;
    _ = c.JS_ToInt32(ctx, &ms, argv[1]);
    const timer_id = c.JS_GetContextOpaque(ctx) orelse return jsExc();
    const loop: *Loop = @ptrCast(@alignCast(timer_id));

    var idx: usize = 0;
    var found: bool = false;
    while (idx < MAX_TIMERS) : (idx += 1) {
        if (!loop.timers[idx].used) {
            found = true;
            break;
        }
    }
    if (!found) return c.JS_ThrowRangeError(ctx, "timer table full", @as(c_int, 0));

    const tfd = linux.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true });
    if (@as(isize, @intCast(tfd)) < 0) return c.JS_ThrowInternalError(ctx, "timerfd_create failed", @as(c_int, 0));
    var spec: linux.itimerspec = .{ .it_interval = .{ .sec = 0, .nsec = 0 }, .it_value = .{ .sec = 0, .nsec = 0 } };
    spec.it_value.sec = @intCast(@divTrunc(ms, 1000));
    spec.it_value.nsec = @intCast((@mod(ms, 1000)) * 1_000_000);
    if (periodic) {
        spec.it_interval = spec.it_value; // 周期重发
    }
    _ = linux.timerfd_settime(@intCast(tfd), .{}, &spec, null);

    loop.timers[idx] = .{
        .fd = @intCast(tfd),
        .id = @intCast(idx + 1),
        .cb = c.JS_DupValue(ctx, argv[0]),
        .periodic = periodic,
        .used = true,
    };
    var ev = linux.epoll_event{
        .events = linux.EPOLL.IN,
        .data = .{ .fd = @intCast(tfd) },
    };
    _ = linux.epoll_ctl(loop.epoll_fd, linux.EPOLL.CTL_ADD, @intCast(tfd), &ev);

    return .{ .u = .{ .int32 = loop.timers[idx].id }, .tag = c.JS_TAG_INT };
}

pub fn jsSetTimeout(
    ctx: ?*c.JSContext,
    this_val: c.JSValueConst,
    argc: c_int,
    argv: [*c]const c.JSValueConst,
) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 2) return c.JS_ThrowTypeError(ctx, "dshSetTimeout(callback, ms)", @as(c_int, 0));
    return registerTimer(ctx, argv, false);
}

pub fn jsSetInterval(
    ctx: ?*c.JSContext,
    this_val: c.JSValueConst,
    argc: c_int,
    argv: [*c]const c.JSValueConst,
) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 2) return c.JS_ThrowTypeError(ctx, "dshSetInterval(callback, ms)", @as(c_int, 0));
    return registerTimer(ctx, argv, true);
}

pub fn jsClearTimer(
    ctx: ?*c.JSContext,
    this_val: c.JSValueConst,
    argc: c_int,
    argv: [*c]const c.JSValueConst,
) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 1) return jsExc();
    const timer_id = c.JS_GetContextOpaque(ctx) orelse return jsExc();
    const loop: *Loop = @ptrCast(@alignCast(timer_id));
    const id = c.JS_VALUE_GET_INT(argv[0]);
    var idx: usize = 0;
    while (idx < MAX_TIMERS) : (idx += 1) {
        const entry = &loop.timers[idx];
        if (entry.used and entry.id == id) {
            c.JS_FreeValue(ctx, entry.cb);
            _ = linux.epoll_ctl(loop.epoll_fd, linux.EPOLL.CTL_DEL, entry.fd, null);
            _ = linux.close(entry.fd);
            entry.* = TimerEntry.empty();
            break;
        }
    }
    const undef: c.JSValue = .{ .u = .{ .int32 = 0 }, .tag = c.JS_TAG_UNDEFINED };
    return undef;
}
