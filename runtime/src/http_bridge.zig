//! http 服务桥（第 36 轮）—— guest 经 dshServices.http 驱动宿主 HTTP/1.1 服务：
//!   start(port)              -> true（启动 listener）
//!   handle(path, fn, exact?) -> true（注册 guest 回调：fn(reqPath) -> body | { body, contentType? }；exact 默认 true）
//!   request(port, path)      -> body 字符串（同进程 connect + 服务侧处理 + 读回）
//!   stop()                   -> true（关闭 listener + 释放回调表）
//! 同步自往返：request() 内 connect（内核 backlog 承载）→ 服务侧 accepts/读/路由/写回
//! → 客户端读。请求处理经模块级 g_req_ctx 拿 JSContext（单线程同步帧安全）。
//! 验证：`zig build http-bridge-smoke-run`。

const std = @import("std");
const http_svc = @import("http_server.zig");
const hs = @import("host_services.zig");
const loop_mod = @import("event_loop.zig");
const trust_fence = @import("trust_fence.zig");

pub const c = @import("engine_c.zig").c;

const MAX_ROUTES = 32; // web-shell 静态面 + 网关协议面 + 面板/调试——16 曾静默溢出挤掉 /ws（404 实锤）

const GuestRoute = struct {
    path: []u8, // 生命周期由本模块持有（page_allocator）
    exact: bool,
    cb: c.JSValue,
    used: bool = false,

    fn empty() GuestRoute {
        return .{ .path = &.{}, .exact = false, .cb = undefined, .used = false };
    }
};

const MAX_CONNS = 8;

const ConnEntry = struct {
    fd: i32 = -1,
    used: bool = false,
    upgraded: bool = false,
    sse: bool = false, // SSE 下行面（events.mux/host——写头后驻留，ssePush 供帧）
    buf: [16 * 1024]u8 = undefined,
    len: usize = 0,
    path: [256]u8 = undefined,
    path_len: usize = 0,
    conn_id: usize = 0,
    cb: c.JSValue = .{ .u = .{ .int32 = 0 }, .tag = c.JS_TAG_UNDEFINED },

    fn empty() ConnEntry {
        return .{ .fd = -1, .used = false };
    }
};

var g_next_conn_id: usize = 1;

// 异步 post 客户端表（postAsync——独立于服务器 conn 表；fd 事件在 onLoopFdEvent 分发）
const PostConn = struct {
    fd: c_int = -1,
    used: bool = false,
    buf: []u8 = &.{}, // 堆（page_allocator）
    rused: usize = 0,
    want_end: usize = 0, // 0=头未齐
    body_start: usize = 0,
    on_data: c.JSValue = .{ .u = .{ .int32 = 0 }, .tag = c.JS_TAG_UNDEFINED },
    on_done: c.JSValue = .{ .u = .{ .int32 = 0 }, .tag = c.JS_TAG_UNDEFINED },
    fn empty() PostConn {
        return .{ .fd = -1, .used = false, .buf = &.{} };
    }
};
const MAX_POST_CONNS = 8;
var g_post_conns: [MAX_POST_CONNS]PostConn = blk: {
    var t: [MAX_POST_CONNS]PostConn = undefined;
    for (&t) |*e| e.* = PostConn.empty();
    break :blk t;
};


var g_conns: [MAX_CONNS]ConnEntry = blk: {
    var t: [MAX_CONNS]ConnEntry = undefined;
    for (&t) |*e| e.* = ConnEntry.empty();
    break :blk t;
};

var g_routes: [MAX_ROUTES]GuestRoute = blk: {
    var t: [MAX_ROUTES]GuestRoute = undefined;
    for (&t) |*e| e.* = GuestRoute.empty();
    break :blk t;
};
var g_listen_fd: c_int = -1;
var g_req_ctx: ?*c.JSContext = null;

/// 大小写不敏感子串查找（HTTP 头——content-length 等）。
fn indexOfIgnoreCase(hay: []const u8, needle: []const u8) ?usize {
    if (needle.len > hay.len) return null;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        var m = true;
        for (needle, 0..) |ch, j| {
            const a = hay[i + j];
            const b = if (a >= 'A' and a <= 'Z') a + 32 else a;
            if (b != ch) { m = false; break; }
        }
        if (m) return i;
    }
    return null;
}

pub const serviceMethods = [_]hs.Method{
    .{ .name = "start", .func = jsStart, .length = 1 },
    .{ .name = "handle", .func = jsHandle, .length = 2 },
    .{ .name = "request", .func = jsRequest, .length = 2 },
    .{ .name = "post", .func = jsPost, .length = 3 },
    .{ .name = "postAsync", .func = jsPostAsync, .length = 4 },
    .{ .name = "stop", .func = jsStop, .length = 0 },
    .{ .name = "push", .func = jsPush, .length = 1 },
.{ .name = "ssePush", .func = jsSsePush, .length = 2 },
};

/// SSE 下行供帧：data: <payload>\n\n（events.mux/host——rc.2 SSE 面）
fn jsSsePush(
    ctx: ?*c.JSContext,
    this_val: c.JSValueConst,
    argc: c_int,
    argv: [*c]const c.JSValueConst,
) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 2) return c.JS_ThrowTypeError(ctx, "http.ssePush(connId, payload)", @as(c_int, 0));
    var target: f64 = 0;
    _ = c.JS_ToFloat64(ctx, &target, argv[0]);
    var plen: usize = 0;
    const p = c.JS_ToCStringLen(ctx, &plen, argv[1]) orelse return c.JS_ThrowTypeError(ctx, "payload must be string", @as(c_int, 0));
    defer c.JS_FreeCString(ctx, p);
    for (&g_conns) |*e| {
        if (e.used and e.sse and e.conn_id == @as(usize, @intFromFloat(target))) {
            var head_buf: [16]u8 = undefined;
            const head = std.fmt.bufPrint(&head_buf, "data: ", .{}) catch return c.JS_NewInt64(ctx, 0);
            _ = http_svc.c.dsh_sock_write(e.fd, head.ptr, head.len);
            _ = http_svc.c.dsh_sock_write(e.fd, p, plen);
            _ = http_svc.c.dsh_sock_write(e.fd, "\n\n", 2);
            return c.JS_NewInt64(ctx, 1);
        }
    }
    return c.JS_NewInt64(ctx, 0);
}

/// 升级连接广播（主动推送——session/event 订阅回调用）。
fn jsPush(
    ctx: ?*c.JSContext,
    this_val: c.JSValueConst,
    argc: c_int,
    argv: [*c]const c.JSValueConst,
) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 1) return c.JS_ThrowTypeError(ctx, "http.push(payload)", @as(c_int, 0));
    var plen: usize = 0;
    const p = c.JS_ToCStringLen(ctx, &plen, argv[0]) orelse return c.JS_ThrowTypeError(ctx, "payload must be string", @as(c_int, 0));
    defer c.JS_FreeCString(ctx, p);
    var target: f64 = 0;
    if (argc >= 2 and !c.JS_IsUndefined(argv[1])) {
        _ = c.JS_ToFloat64(ctx, &target, argv[1]);
    }
    var sent: usize = 0;
    for (&g_conns) |*e| {
        if (e.used and e.upgraded and e.cb.tag != c.JS_TAG_UNDEFINED) {
            if (argc >= 2 and !c.JS_IsUndefined(argv[1]) and e.conn_id != @as(usize, @intFromFloat(target))) continue;
            writeWsFrame(e.fd, p[0..plen]);
            sent += 1;
        }
    }
    return c.JS_NewInt64(ctx, @intCast(sent));
}

fn jsStart(
    ctx: ?*c.JSContext,
    this_val: c.JSValueConst,
    argc: c_int,
    argv: [*c]const c.JSValueConst,
) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 1) return c.JS_ThrowTypeError(ctx, "http.start(port)", @as(c_int, 0));
    var port: c_int = 0;
    _ = c.JS_ToInt32(ctx, &port, argv[0]);
    if (g_listen_fd >= 0) return c.JS_ThrowInternalError(ctx, "http already started", @as(c_int, 0));
    const server = http_svc.Server.listen(@intCast(port), &.{}) catch {
        return c.JS_ThrowInternalError(ctx, "http listen failed", @as(c_int, 0));
    };
    g_listen_fd = server.listen_fd;
    if (std.c.getenv("DSH_HTTP_TRACE") != null) std.debug.print("[http] listen fd={d} port={d}\n", .{ g_listen_fd, port });
    _ = http_svc.c.dsh_sock_set_nonblock(g_listen_fd); // LT 模式：无连接时 accept 不得阻塞事件循环
    // 网关形态：listen fd 挂入宿主事件循环（异步 accept；timer 同链）
    if (c.JS_GetContextOpaque(ctx)) |o| {
        const loop: *loop_mod.Loop = @ptrCast(@alignCast(o));
        loop.watchFd(g_listen_fd);
    }
    return c.JS_NewBool(ctx, true);
}

fn jsHandle(
    ctx: ?*c.JSContext,
    this_val: c.JSValueConst,
    argc: c_int,
    argv: [*c]const c.JSValueConst,
) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 2) return c.JS_ThrowTypeError(ctx, "http.handle(path, fn, exact?)", @as(c_int, 0));
    if (!c.JS_IsFunction(ctx, argv[1])) return c.JS_ThrowTypeError(ctx, "http.handle: fn must be a function", @as(c_int, 0));
    const p = c.JS_ToCStringLen(ctx, null, argv[0]) orelse return c.JS_ThrowTypeError(ctx, "path must be string", @as(c_int, 0));
    defer c.JS_FreeCString(ctx, p);
    var exact = true;
    if (argc >= 3) exact = c.JS_ToBool(ctx, argv[2]) != 0;
    var slot: ?usize = null;
    for (&g_routes, 0..) |*r, i| {
        if (!r.used) {
            slot = i;
            break;
        }
    }
    if (slot == null) return c.JS_ThrowRangeError(ctx, "http route table full", @as(c_int, 0));
    const copy = std.heap.page_allocator.dupe(u8, std.mem.span(p)) catch return c.JS_ThrowInternalError(ctx, "oom", @as(c_int, 0));
    g_routes[slot.?] = .{
        .path = copy,
        .exact = exact,
        .cb = c.JS_DupValue(ctx, argv[1]),
        .used = true,
    };
    return c.JS_NewBool(ctx, true);
}

fn jsRequest(
    ctx: ?*c.JSContext,
    this_val: c.JSValueConst,
    argc: c_int,
    argv: [*c]const c.JSValueConst,
) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 2) return c.JS_ThrowTypeError(ctx, "http.request(port, path)", @as(c_int, 0));
    var port: c_int = 0;
    _ = c.JS_ToInt32(ctx, &port, argv[0]);
    const p = c.JS_ToCStringLen(ctx, null, argv[1]) orelse return c.JS_ThrowTypeError(ctx, "path must be string", @as(c_int, 0));
    defer c.JS_FreeCString(ctx, p);
    const path = std.mem.span(p);

    if (g_listen_fd < 0) return c.JS_ThrowInternalError(ctx, "http not started", @as(c_int, 0));

    const conn = http_svc.c.dsh_sock_connect(@intCast(port));
    if (conn < 0) return c.JS_ThrowInternalError(ctx, "http connect failed", @as(c_int, 0));
    defer _ = http_svc.c.dsh_sock_close(conn);

    var req_buf: [512]u8 = undefined;
    const req = std.fmt.bufPrint(&req_buf, "GET {s} HTTP/1.1\r\nHost: localhost\r\n\r\n", .{path}) catch return c.JS_ThrowInternalError(ctx, "req too long", @as(c_int, 0));
    _ = http_svc.c.dsh_sock_write(conn, req.ptr, req.len);

    // 服务侧帧：accept（backlog 已连接）→ 读请求 → 路由 → guest 回调 → 写回
    g_req_ctx = ctx;
    defer g_req_ctx = null;
    const svr_conn = http_svc.c.dsh_sock_accept(g_listen_fd);
    if (svr_conn < 0) return c.JS_ThrowInternalError(ctx, "http accept failed", @as(c_int, 0));
    _ = handleConnection(svr_conn);



    var resp_buf: [16 * 1024]u8 = undefined;
    var used: usize = 0;
    while (used < resp_buf.len) {
        const n = http_svc.c.dsh_sock_read(conn, resp_buf[used..].ptr, resp_buf.len - used);
        if (n <= 0) break;
        used += @intCast(n);
        if (std.mem.indexOf(u8, resp_buf[0..used], "\r\n\r\n") != null) break;
    }
    const resp = resp_buf[0..used];
    const body_start = std.mem.indexOf(u8, resp, "\r\n\r\n") orelse
        return c.JS_ThrowInternalError(ctx, "bad response", @as(c_int, 0));
    const body = resp[body_start + 4 ..];
    return c.JS_NewStringLen(ctx, body.ptr, body.len);
}

pub fn jsStop(
    ctx: ?*c.JSContext,
    this_val: c.JSValueConst,
    argc: c_int,
    argv: [*c]const c.JSValueConst,
) callconv(.c) c.JSValue {
    _ = this_val;
    _ = argc;
    _ = argv;
    if (g_listen_fd >= 0) {
        if (std.c.getenv("DSH_HTTP_TRACE") != null) std.debug.print("[http] jsStop closing listen fd={d}\n", .{g_listen_fd});
        _ = http_svc.c.dsh_sock_close(g_listen_fd);
        g_listen_fd = -1;
    }
    for (&g_routes) |*r| {
        if (r.used) {
            c.JS_FreeValue(ctx, r.cb);
            std.heap.page_allocator.free(r.path);
            r.* = GuestRoute.empty();
        }
    }
    // 升级态连接清理（cb dup + fd）
    g_req_ctx = ctx;
    for (&g_conns) |*e| {
        if (e.used) {
            if (e.upgraded and e.cb.tag != c.JS_TAG_UNDEFINED) c.JS_FreeValue(ctx, e.cb);
            _ = http_svc.c.dsh_sock_close(e.fd);
            e.* = ConnEntry.empty();
        }
    }
    g_req_ctx = null;
    return c.JS_NewBool(ctx, true);
}

/// 事件循环入口（Loop.onFdEvent）：listen 可读 → accept 新连接入表并挂 epoll；
/// 连接可读 → 帧状态机（分帧累积，\r\n\r\n 完整后处理 + 写回 + 关闭；
/// close() 自动从 epoll 摘除——Linux 语义，无需显式 unwatch）。
/// ctx 由 Loop 提供（事件驱动无 JS 帧）。
pub fn onLoopFdEvent(ctx: ?*c.JSContext, fd: i32) void {
    g_req_ctx = ctx;
    defer g_req_ctx = null;
    // 异步 post 客户端 fd（独立表——先于服务器 conn 分发）
    for (&g_post_conns) |*entry| {
        if (entry.used and entry.fd == fd) {
            postRead(ctx, entry);
            return;
        }
    }
    if (fd == g_listen_fd) {
        while (true) {
            const conn = http_svc.c.dsh_sock_accept(g_listen_fd);
            if (conn < 0) break; // EAGAIN（非阻塞）或错误
            _ = http_svc.c.dsh_sock_set_nonblock(conn); // accept 不继承 O_NONBLOCK（Linux 语义）
            if (addConn(conn)) {
                if (c.JS_GetContextOpaque(ctx)) |o| {
                    const loop: *loop_mod.Loop = @ptrCast(@alignCast(o));
                    loop.watchFd(conn);
                }
            } else {
                _ = http_svc.c.dsh_sock_close(conn);
            }
        }
        return;
    }
    serveConn(fd);
}

fn addConn(fd: i32) bool {
    for (&g_conns) |*e| {
        if (!e.used) {
            e.* = ConnEntry.empty();
            e.fd = fd;
            e.used = true;
            e.conn_id = g_next_conn_id; // accept 即分配（GET 回调第三参/SSE 面要用）
            g_next_conn_id += 1;
            return true;
        }
    }
    return false;
}

fn removeConnLocked(fd: i32) void {
    if (std.c.getenv("DSH_HTTP_TRACE") != null and fd != g_listen_fd) {
        for (&g_conns) |*e2| {
            if (e2.used and e2.fd == fd) {
                std.debug.print("[http] conn closed fd={d} id={d} ws={} sse={}\n", .{ fd, e2.conn_id, e2.upgraded, e2.sse });
                break;
            }
        }
    }
    if (fd == g_listen_fd and std.c.getenv("DSH_HTTP_TRACE") != null) std.debug.print("[http] BUG: conn-remove hit listen fd={d}\n", .{fd});
    for (&g_conns) |*e| {
        if (e.used and e.fd == fd) {
            if (e.upgraded and g_req_ctx != null and e.cb.tag != c.JS_TAG_UNDEFINED) {
                c.JS_FreeValue(g_req_ctx, e.cb);
            }
            _ = http_svc.c.dsh_sock_close(fd);
            e.* = ConnEntry.empty();
            return;
        }
    }
}

/// Content-Length 帧边界：完整头 + body 齐 → 返回帧总长；未齐 → null。
/// （v1 body 上限 = conn.buf 16KB；大帧经 413/断连——留档 M-4 细化）
fn frameEndOf(raw: []const u8) ?usize {
    const hdr_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return null;
    const cl = headerValue(raw[0..hdr_end], "content-length") orelse "0";
    const body_len = std.fmt.parseInt(usize, std.mem.trim(u8, cl, " \t"), 10) catch return null;
    const total = hdr_end + 4 + body_len;
    if (raw.len < total) return null;
    return total;
}

/// keep-alive 判定：Connection 头（close/keep-alive）优先；否则 HTTP/1.1 默认 keep。
fn wantsKeepAlive(req: http_svc.Request) bool {
    if (headerValue(req.headers, "connection")) |conn| {
        const cv = std.mem.trim(u8, conn, " \t");
        if (eqIgnoreCase(cv, "close")) return false;
        if (eqIgnoreCase(cv, "keep-alive")) return true;
    }
    return std.mem.eql(u8, req.version, "HTTP/1.1");
}

/// 连接帧状态机：非阻塞读累积 → 帧完整（含 Content-Length 体）→ 信任栅栏 +
/// 路由 + guest 回调 + 写回 → keep-alive 则复用（buf 残留帧流水线续处理），
/// 否则关闭。客户端先关 → 移除。close() 自动从 epoll 摘除。
fn serveConn(fd: i32) void {
    const entry = for (&g_conns) |*e| {
        if (e.used and e.fd == fd) break e;
    } else return;
    if (entry.upgraded) {
        serveUpgraded(entry);
        return;
    }
    // 一次事件：先读完当前可用数据
    while (true) {
        if (entry.len >= entry.buf.len) {
            removeConnLocked(fd);
            return;
        }
        const n = http_svc.c.dsh_sock_read(fd, entry.buf[entry.len..].ptr, entry.buf.len - entry.len);
        if (n > 0) {
            entry.len += @intCast(n);
            continue;
        }
        if (n == 0) {
            removeConnLocked(fd);
            return;
        }
        break; // EAGAIN
    }
    // 帧循环（流水线：buf 残留多帧时一次处理完）
    while (true) {
        const frame_end = frameEndOf(entry.buf[0..entry.len]) orelse return; // 半帧：等下次事件
        const raw = entry.buf[0..frame_end];
        const req = http_svc.parseRequest(raw);
        var out = http_svc.Response{};
        const host_h = headerValue(req.headers, "host");
        const sfs = headerValue(req.headers, "sec-fetch-site");
        const origin = headerValue(req.headers, "origin");
        const upgrade_h = headerValue(req.headers, "upgrade");
        const is_upgrade = std.mem.eql(u8, req.method, "GET") and upgrade_h != null and std.mem.indexOf(u8, upgrade_h.?, "websocket") != null;
        if (std.c.getenv("DSH_HTTP_TRACE") != null) std.debug.print("[http-req] {s} {s} sfs={s} origin={s} upg={s}\n", .{ req.method, req.path, sfs orelse "-", origin orelse "-", if (is_upgrade) "ws" else "-" });
        if (is_upgrade and trust_fence.isTrustedApiRequest(host_h, sfs, origin, &.{})) {
            if (callbackForPath(req.path)) |cb| {
                // 消费升级请求帧（帧通道从字节 0 起）
                const remain0 = entry.len - frame_end;
                std.mem.copyForwards(u8, entry.buf[0..remain0], entry.buf[frame_end..entry.len]);
                entry.len = remain0;
                beginUpgrade(entry, req, cb);
                return;
            }
        }
        if (!trust_fence.isTrustedApiRequest(host_h, sfs, origin, &.{})) {
            out = .{ .status = 403, .body = "forbidden" };
        } else if (callbackForPath(req.path)) |cb| {
            var ct: []const u8 = "text/plain; charset=utf-8";
            var st: u16 = 200;
            var sse = false;
            const body = callGuest(req, cb, &ct, &st, &sse, entry.conn_id);
            if (sse) {
                if (std.c.getenv("DSH_HTTP_TRACE") != null) std.debug.print("[http-req] {s} {s} -> SSE conn={d}\n", .{ req.method, req.path, entry.conn_id });
                beginSse(entry);
                return;
            }
            out = .{ .status = st, .body = body, .content_type = ct };
            if (std.c.getenv("DSH_HTTP_TRACE") != null) std.debug.print("[http] {s} {s} -> {d} ({d}B)\n", .{ req.method, req.path, st, body.len });
        } else {
            out = .{ .status = 404, .body = "not found" };
        }
        const keep = wantsKeepAlive(req);
        out.keep_alive = keep;
        _ = http_svc.writeResponse(fd, &out) catch {
            removeConnLocked(fd);
            return;
        };
        // 消费掉本帧（前移剩余）
        const remain = entry.len - frame_end;
        std.mem.copyForwards(u8, entry.buf[0..remain], entry.buf[frame_end..entry.len]);
        entry.len = remain;
        if (!keep) {
            removeConnLocked(fd);
            return;
        }
        if (remain == 0) return; // 等下一请求事件
    }
}

/// 头部值提取（小写字名比较；raw 为 parseRequest 的 headers 段）。
fn headerValue(raw: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, raw, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const hname = line[0..colon];
        if (!eqIgnoreCase(hname, name)) continue;
        // 值 = 冒号后剥离可选空格与尾部 CR（头行拆分已去 \r\n）
        var v = line[colon + 1 ..];
        var start: usize = 0;
        while (start < v.len and (v[start] == ' ' or v[start] == '\t')) start += 1;
        var end = v.len;
        while (end > start and (v[end - 1] == ' ' or v[end - 1] == '\t' or v[end - 1] == '\r')) end -= 1;
        return v[start..end];
    }
    return null;
}

fn eqIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const lx = if (x >= 'A' and x <= 'Z') x + 32 else x;
        const ly = if (y >= 'A' and y <= 'Z') y + 32 else y;
        if (lx != ly) return false;
    }
    return true;
}

/// HTTP 客户端 POST（宿主 fetch 基元）：post(port, path, body, headers?) -> body 字符串。
/// 同步全响应（LLM 非流式基元；SSE 流式后续轮——慢读事件化）。
/// 逐块回调（wire 级流式面）：CS 字符串分片到 guest 回调；返回后原样（值为字符串——JS_Call 前构建）
/// 异步 POST（wire 级流）：写请求后立即返回；读事件循环驱动（loop fd 事件 → postRead）。
/// onData(chunk) 每块回调；onDone(totalLen|err) 终态回调后连接清理。
fn jsPostAsync(
    ctx: ?*c.JSContext,
    this_val: c.JSValueConst,
    argc: c_int,
    argv: [*c]const c.JSValueConst,
) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 3) return c.JS_ThrowTypeError(ctx, "http.postAsync(port, path, body, onData?, onDone?)", @as(c_int, 0));
    var port: c_int = 0;
    _ = c.JS_ToInt32(ctx, &port, argv[0]);
    const p = c.JS_ToCStringLen(ctx, null, argv[1]) orelse return c.JS_ThrowTypeError(ctx, "path must be string", @as(c_int, 0));
    defer c.JS_FreeCString(ctx, p);
    var body_len: usize = 0;
    const body = c.JS_ToCStringLen(ctx, &body_len, argv[2]) orelse return c.JS_ThrowTypeError(ctx, "body must be string", @as(c_int, 0));
    defer c.JS_FreeCString(ctx, body);
    const slot = for (&g_post_conns) |*e| {
        if (!e.used) break e;
    } else return c.JS_ThrowInternalError(ctx, "post slots exhausted", @as(c_int, 0));

    const conn = http_svc.c.dsh_sock_connect(@intCast(port));
    if (conn < 0) return c.JS_ThrowInternalError(ctx, "http connect failed", @as(c_int, 0));
    _ = http_svc.c.dsh_sock_set_nonblock(conn);
    const hdr = "POST {s} HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n";
    var req_buf: [1024]u8 = undefined;
    const req = std.fmt.bufPrint(&req_buf, hdr, .{ std.mem.span(p), body_len }) catch {
        _ = http_svc.c.dsh_sock_close(conn);
        return c.JS_ThrowInternalError(ctx, "req too long", @as(c_int, 0));
    };
    _ = http_svc.c.dsh_sock_write(conn, req.ptr, req.len);
    _ = http_svc.c.dsh_sock_write(conn, body, body_len);
    const buf = std.heap.page_allocator.alloc(u8, 64 * 1024) catch {
        _ = http_svc.c.dsh_sock_close(conn);
        return c.JS_ThrowInternalError(ctx, "post oom", @as(c_int, 0));
    };
    slot.* = PostConn.empty();
    slot.fd = conn;
    slot.used = true;
    slot.buf = buf;
    slot.on_data = if (argc > 3 and c.JS_IsFunction(ctx, argv[3])) c.JS_DupValue(ctx, argv[3]) else .{ .u = .{ .int32 = 0 }, .tag = c.JS_TAG_UNDEFINED };
    slot.on_done = if (argc > 4 and c.JS_IsFunction(ctx, argv[4])) c.JS_DupValue(ctx, argv[4]) else .{ .u = .{ .int32 = 0 }, .tag = c.JS_TAG_UNDEFINED };
    if (c.JS_GetContextOpaque(ctx)) |o| {
        const loop: *loop_mod.Loop = @ptrCast(@alignCast(o));
        loop.watchFd(conn);
    }
    return c.JS_NewInt64(ctx, @intCast(conn));
}

fn postDone(ctx: ?*c.JSContext, entry: *PostConn, result: c_int) void {
    if (entry.on_done.tag != c.JS_TAG_UNDEFINED) {
        const undefv: c.JSValue = .{ .u = .{ .int32 = 0 }, .tag = c.JS_TAG_UNDEFINED };
        const args = [_]c.JSValue{c.JS_NewInt64(ctx, result)};
        const r = c.JS_Call(ctx, entry.on_done, undefv, 1, @constCast(&args));
        if (c.JS_IsException(r)) _ = c.JS_GetException(ctx);
        c.JS_FreeValue(ctx, args[0]);
    }
    if (entry.on_data.tag != c.JS_TAG_UNDEFINED) c.JS_FreeValue(ctx, entry.on_data);
    if (entry.on_done.tag != c.JS_TAG_UNDEFINED) c.JS_FreeValue(ctx, entry.on_done);
    if (entry.fd >= 0) _ = http_svc.c.dsh_sock_close(entry.fd);
    if (entry.buf.len > 0) std.heap.page_allocator.free(entry.buf);
    const fd = entry.fd;
    entry.* = PostConn.empty();
    entry.fd = fd; // 表槽保留 fd 值便于调试（语义不计）
    entry.used = false;
    entry.buf = &.{};
}

fn postRead(ctx: ?*c.JSContext, entry: *PostConn) void {
    while (true) {
        // 容量面：增长（初始 64KB——按需 ×2——大响应/长流）
        if (entry.rused >= entry.buf.len) {
            const grow = entry.buf.len * 2;
            const nb = std.heap.page_allocator.alloc(u8, grow) catch {
                postDone(ctx, entry, -2);
                return;
            };
            @memmove(nb[0..entry.rused], entry.buf[0..entry.rused]);
            std.heap.page_allocator.free(entry.buf);
            entry.buf = nb;
        }
        const n = http_svc.c.dsh_sock_read(entry.fd, entry.buf[entry.rused..].ptr, entry.buf.len - entry.rused);
        if (n == 0) {
            // EOF：头未齐或无 CL——按已收结束
            if (entry.want_end == 0) {
                postDone(ctx, entry, @intCast(entry.rused));
                return;
            }
            if (entry.rused < entry.want_end) {
                postDone(ctx, entry, @intCast(entry.rused));
                return;
            }
            postDone(ctx, entry, @intCast(entry.want_end - entry.body_start));
            return;
        }
        if (n < 0) {
            // 非阻塞读 EAGAIN/EWOULDBLOCK：等待下一 fd 事件（不可当错误终结）
            const en = std.c._errno().*;
            if (en == 11 or en == 35) break; // EAGAIN / EWOULDBLOCK
            postDone(ctx, entry, -1);
            return;
        }
        const got = @as(usize, @intCast(n));
        var prev = entry.rused;
        entry.rused += got;
        // 头未齐：等 


        if (entry.want_end == 0) {
            if (std.mem.indexOf(u8, entry.buf[0..entry.rused], "\r\n\r\n") == null) continue;
            const hsx = std.mem.indexOf(u8, entry.buf[0..entry.rused], "\r\n\r\n").?;
            entry.body_start = hsx + 4;
            const cl_marker = "content-length: ";
            var cl: usize = 0;
            if (indexOfIgnoreCase(entry.buf[0..hsx], cl_marker)) |ci| {
                const cl_seg = entry.buf[ci + cl_marker.len .. hsx];
                const cl_end = std.mem.indexOfScalar(u8, cl_seg, 0x0d) orelse cl_seg.len;
                cl = std.fmt.parseInt(usize, std.mem.trim(u8, cl_seg[0..cl_end], " \t"), 10) catch 0;
            }
            entry.want_end = entry.body_start + cl;
            // want_end 容量确保（一次扩到位）
            if (entry.want_end > entry.buf.len) {
                const nb = std.heap.page_allocator.alloc(u8, entry.want_end) catch {
                    postDone(ctx, entry, -2);
                    return;
                };
                @memmove(nb[0..entry.rused], entry.buf[0..entry.rused]);
                std.heap.page_allocator.free(entry.buf);
                entry.buf = nb;
            }
            prev = entry.body_start;
            if (entry.rused > entry.want_end) {
                postDone(ctx, entry, @intCast(entry.want_end - entry.body_start));
                return;
            }
        }
        // body 增量回调
        if (entry.on_data.tag != c.JS_TAG_UNDEFINED and entry.rused > prev) {
            emitChunk(ctx, entry.on_data, entry.buf[prev..entry.rused]);
        }
        if (entry.want_end > 0 and entry.rused >= entry.want_end) {
            postDone(ctx, entry, @intCast(entry.want_end - entry.body_start));
            return;
        }
    }
}

fn emitChunk(ctx: ?*c.JSContext, cb: c.JSValue, chunk: []const u8) void {
    const cv = c.JS_NewStringLen(ctx, chunk.ptr, chunk.len);
    if (c.JS_IsException(cv)) {
        _ = c.JS_GetException(ctx);
        return;
    }
    const undefv: c.JSValue = .{ .u = .{ .int32 = 0 }, .tag = c.JS_TAG_UNDEFINED };
    const args = [_]c.JSValue{cv};
    const result = c.JS_Call(ctx, cb, undefv, 1, @constCast(&args));
    if (c.JS_IsException(result)) _ = c.JS_GetException(ctx); // 回调异常不阻流式（补救面）
    c.JS_FreeValue(ctx, cv);
}

fn jsPost(
    ctx: ?*c.JSContext,
    this_val: c.JSValueConst,
    argc: c_int,
    argv: [*c]const c.JSValueConst,
) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 3) return c.JS_ThrowTypeError(ctx, "http.post(port, path, body, onData?)", @as(c_int, 0));
    const on_data: ?c.JSValue = if (argc > 3 and c.JS_IsFunction(ctx, argv[3])) argv[3] else null;
    var port: c_int = 0;
    _ = c.JS_ToInt32(ctx, &port, argv[0]);
    const p = c.JS_ToCStringLen(ctx, null, argv[1]) orelse return c.JS_ThrowTypeError(ctx, "path must be string", @as(c_int, 0));
    defer c.JS_FreeCString(ctx, p);
    var body_len: usize = 0;
    const body = c.JS_ToCStringLen(ctx, &body_len, argv[2]) orelse return c.JS_ThrowTypeError(ctx, "body must be string", @as(c_int, 0));
    defer c.JS_FreeCString(ctx, body);

    const conn = http_svc.c.dsh_sock_connect(@intCast(port));
    if (conn < 0) return c.JS_ThrowInternalError(ctx, "http connect failed", @as(c_int, 0));
    defer _ = http_svc.c.dsh_sock_close(conn);
    const hdr = "POST {s} HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n";
    var req_buf: [1024]u8 = undefined;
    const req = std.fmt.bufPrint(&req_buf, hdr, .{ std.mem.span(p), body_len }) catch return c.JS_ThrowInternalError(ctx, "req too long", @as(c_int, 0));
    _ = http_svc.c.dsh_sock_write(conn, req.ptr, req.len);
    _ = http_svc.c.dsh_sock_write(conn, body, body_len);
    var rbuf: [16 * 1024]u8 = undefined;
    var rused: usize = 0;
    while (rused < rbuf.len) {
        const n = http_svc.c.dsh_sock_read(conn, rbuf[rused..].ptr, rbuf.len - rused);
        if (n <= 0) break;
        rused += @intCast(n);
        if (std.mem.indexOf(u8, rbuf[0..rused], "\r\n\r\n") != null) break;
    }
    const hs2 = std.mem.indexOf(u8, rbuf[0..rused], "\r\n\r\n") orelse return c.JS_ThrowInternalError(ctx, "no response body", @as(c_int, 0));
    const body_start = hs2 + 4;
    // Content-Length 续读（响应体——头后按声明读全；超 16KB 头缓存的动态扩读——长流现实面）
    const cl_marker = "content-length: ";
    var body_total = rused - body_start;
    if (indexOfIgnoreCase(rbuf[0..hs2], cl_marker)) |ci| {
        const cl_seg = rbuf[ci + cl_marker.len .. hs2];
        const cl_end = std.mem.indexOfScalar(u8, cl_seg, 0x0d) orelse cl_seg.len;
        const cl = std.fmt.parseInt(usize, std.mem.trim(u8, cl_seg[0..cl_end], " \t"), 10) catch 0;
        if (cl > body_total) {
            const want_end = body_start + cl;
            if (want_end <= rbuf.len) {
                if (on_data) |cb| {
                    // 小路径逐块：头区已含的 body 先回调，再循环逐块
                    const first = rused - body_start;
                    if (first > 0) emitChunk(ctx, cb, rbuf[body_start .. body_start + first]);
                    var got = rused;
                    while (got < want_end) {
                        const n = http_svc.c.dsh_sock_read(conn, rbuf[got..].ptr, want_end - got);
                        if (n <= 0) break;
                        got += @as(usize, @intCast(n));
                        emitChunk(ctx, cb, rbuf[got - @as(usize, @intCast(n)) .. got]);
                    }
                    body_total = got - body_start;
                } else {
                    // 分块写下的 CL 续读必须循环（mock 9B 分块——单次 read 部分到达——截断暴露）
                    var got = rused;
                    while (got < want_end) {
                        const n = http_svc.c.dsh_sock_read(conn, rbuf[got..].ptr, want_end - got);
                        if (n <= 0) break;
                        got += @as(usize, @intCast(n));
                    }
                    rused = got;
                    body_total = rused - body_start;
                }
            } else {
                // 动态缓冲：头后在堆上继续（单次 realloc 至声明长度）
                const dyn_buf = std.heap.page_allocator.alloc(u8, want_end) catch return c.JS_ThrowInternalError(ctx, "http post oom", @as(c_int, 0));
                defer std.heap.page_allocator.free(dyn_buf);
                @memmove(dyn_buf[0..rused], rbuf[0..rused]);
                if (on_data) |cb| {
                    // wire 级逐块：先回调已读头区（body 段），再逐块
                    const first = rused - body_start;
                    if (first > 0) emitChunk(ctx, cb, dyn_buf[body_start .. body_start + first]);
                    var dused = rused;
                    while (dused < want_end) {
                        const n = http_svc.c.dsh_sock_read(conn, dyn_buf[dused..].ptr, want_end - dused);
                        if (n <= 0) break;
                        dused += @as(usize, @intCast(n));
                        emitChunk(ctx, cb, dyn_buf[dused - @as(usize, @intCast(n)) .. dused]);
                    }
                    const dbody_total = dused - body_start;
                    return c.JS_NewStringLen(ctx, dyn_buf.ptr + body_start, dbody_total);
                }
                var dused = rused;
                while (dused < want_end) {
                    const n = http_svc.c.dsh_sock_read(conn, dyn_buf[dused..].ptr, want_end - dused);
                    if (n <= 0) break;
                    dused += @as(usize, @intCast(n));
                }
                const dbody_total = dused - body_start;
                return c.JS_NewStringLen(ctx, dyn_buf.ptr + body_start, dbody_total);
            }
        }
    }
    return c.JS_NewStringLen(ctx, &rbuf[body_start], body_total);
}
fn handleConnection(conn: i32) bool {
    defer _ = http_svc.c.dsh_sock_close(conn);
    var read_buf: [16 * 1024]u8 = undefined;
    const raw = http_svc.readRequest(conn, &read_buf) catch return false;
    const req = http_svc.parseRequest(raw);
    // POST 专用 body 读（仅 POST——通用路径不动；WS/GET 不受影响）
    const req_body = blk: {
        if (!std.mem.eql(u8, req.method, "POST")) break :blk req.body;
        const cl_marker = "Content-Length: ";
        const cl_idx = std.mem.indexOf(u8, req.headers, cl_marker) orelse break :blk req.body;
        const cl_val = req.headers[cl_idx + cl_marker.len ..];
        const cl_end = std.mem.indexOfScalar(u8, cl_val, 0x0d) orelse cl_val.len;
        const cl = std.fmt.parseInt(usize, cl_val[0..cl_end], 10) catch break :blk req.body;
        const body_start = raw.len - req.headers.len;
        if (req.body.len >= cl) break :blk req.body;
        const need = cl - req.body.len;
        if (body_start + req.body.len + need > read_buf.len) break :blk req.body;
        var got: usize = 0;
        while (got < need) {
            const n = http_svc.c.dsh_sock_read(conn, read_buf[body_start + req.body.len + got ..].ptr, need - got);
            if (n <= 0) break;
            got += @intCast(n);
        }
        const body_total = req.body.len + got;
        if (body_total == 0) break :blk "";
        break :blk read_buf[body_start .. body_start + body_total];
    };
    const req2 = http_svc.Request{ .method = req.method, .path = req.path, .version = req.version, .headers = req.headers, .body = req_body };
    var out = http_svc.Response{};
    // 信任栅栏（§2.5）：/api 级接口的 DNS-rebinding 防线。
    // v1 部署默认 trustedHosts=[]（loopback-only；deployment 经 config 注入）。
    const host_h = headerValue(req.headers, "host");
    const sfs = headerValue(req.headers, "sec-fetch-site");
    const origin = headerValue(req.headers, "origin");
    if (!trust_fence.isTrustedApiRequest(host_h, sfs, origin, &.{})) {
        out = .{ .status = 403, .body = "forbidden" };
        http_svc.writeResponse(conn, &out) catch return false;
        return true;
    }
    if (callbackForPath(req2.path)) |cb| {
        var ct: []const u8 = "text/plain; charset=utf-8";
        var st: u16 = 200;
        var sse = false;
        const body = callGuest(req2, cb, &ct, &st, &sse, 0);
        out = .{ .status = st, .body = body, .content_type = ct };
    } else {
        out = .{ .status = 404, .body = "not found" };
    }
    http_svc.writeResponse(conn, &out) catch return false;
    return true;
}

// ---- WS 升级通道（101 + 帧循环）----

const WsFrame = struct { payload: []u8, total: usize };

/// masked 客户端帧解析（FIN+text；126/127 扩展长；原地解掩码——buf 须可变）。
fn parseWsFrame(raw: []u8) ?WsFrame {
    if (raw.len < 2) return null;
    const op = raw[0] & 0x0f;
    if (op != 1) return null; // 本通道仅 text 帧（其余忽略——协议面留档）
    var len: usize = raw[1] & 0x7f;
    var off: usize = 2;
    if (len == 126) {
        if (raw.len < 4) return null;
        len = (@as(usize, raw[2]) << 8) | raw[3];
        off = 4;
    } else if (len == 127) {
        if (raw.len < 10) return null;
        len = 0;
        for (raw[2..10]) |b| len = (len << 8) | b;
        off = 10;
    }
    const masked = (raw[1] & 0x80) != 0;
    if (!masked) return null; // 客户端帧必须掩码（RFC 6455 §5.3）
    if (raw.len < off + 4 + len) return null;
    const mask = raw[off .. off + 4];
    const payload = raw[off + 4 .. off + 4 + len];
    for (payload, 0..) |ch, i| payload[i] = ch ^ mask[i % 4];
    return .{ .payload = payload, .total = off + 4 + len };
}

/// 服务端帧（FIN+text，unmasked）。
fn writeWsFrame(fd: i32, payload: []const u8) void {
    var hdr: [2]u8 = .{ 0x81, 0 };
    var extra: [8]u8 = undefined;
    var hlen: usize = 0;
    if (payload.len < 126) {
        hdr[1] = @intCast(payload.len);
    } else if (payload.len < 65536) {
        hdr[1] = 126;
        extra[0] = @intCast(payload.len >> 8);
        extra[1] = @intCast(payload.len & 0xff);
        hlen = 2;
    } else {
        hdr[1] = 127;
        var v: u64 = payload.len;
        var i: usize = 7;
        while (true) : (i -= 1) {
            extra[i] = @intCast(v & 0xff);
            if (i == 0) break;
            v >>= 8;
        }
        hlen = 8;
    }
    _ = http_svc.c.dsh_sock_write(fd, &hdr, 2);
    if (hlen > 0) _ = http_svc.c.dsh_sock_write(fd, &extra, hlen);
    _ = http_svc.c.dsh_sock_write(fd, payload.ptr, payload.len);
}

/// 升级分支：101（accept 来自 guest /ws 回调）→ 帧循环（回调第三参=payload）。
fn beginUpgrade(entry: *ConnEntry, req: http_svc.Request, cb: c.JSValue) void {
    entry.upgraded = true;
    var ct_ws: []const u8 = "text/plain; charset=utf-8";
    var st_ws: u16 = 200;
    var sse_ws = false;
    const accept = callGuest(req, cb, &ct_ws, &st_ws, &sse_ws, entry.conn_id);
    const accept_val = if (std.mem.startsWith(u8, accept, "ws-accept:")) accept[10..] else accept;
    var hdr_buf: [256]u8 = undefined;
    const hdr = std.fmt.bufPrint(&hdr_buf, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n", .{accept_val}) catch {
        removeConnLocked(entry.fd);
        return;
    };
    _ = http_svc.c.dsh_sock_write(entry.fd, hdr.ptr, hdr.len);
    // 路由/回调驻留（帧循环使用；removeConn 释放）
    if (req.path.len <= entry.path.len) {
        @memcpy(entry.path[0..req.path.len], req.path);
        entry.path_len = req.path.len;
    } else {
        removeConnLocked(entry.fd);
        return;
    }
    entry.cb = c.JS_DupValue(g_req_ctx, cb);
    // conn_id 已在 accept 时分配（GET 回调第四参即此 id）——此处不得重分，
    // 否则 guest 存的旧 id 与 entry 新 id 永不匹配（push 静默丢帧——mux WS 实锤）
    serveUpgraded(entry);
}

/// SSE 驻留化：写头（含 `: connected` 注释行——rc.2 sseResponse 同款）→ 标记升级，
/// 之后由 ssePush 供 `data:` 帧；客户端不再上行（读即丢弃，EOF 清理——serveUpgraded sse 分支）。
fn beginSse(entry: *ConnEntry) void {
    entry.sse = true;
    entry.upgraded = true;
    entry.len = 0;
    const head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n: connected\n\n";
    _ = http_svc.c.dsh_sock_write(entry.fd, head, head.len);
}

fn serveUpgraded(entry: *ConnEntry) void {
    const fd = entry.fd;
    // 一次事件读一次（非阻塞 EAGAIN 即返回——事件驱动语义；客户端半帧等下次）
    if (entry.len >= entry.buf.len) {
        removeConnLocked(fd);
        return;
    }
    const n = http_svc.c.dsh_sock_read(fd, entry.buf[entry.len..].ptr, entry.buf.len - entry.len);
    if (entry.sse) {
        // SSE 驻留面：无上行语义——入站字节丢弃，EOF 清连接
        if (n <= 0) removeConnLocked(fd);
        entry.len = 0;
        return;
    }
    if (n > 0) {
        entry.len += @intCast(n);
    } else if (n == 0) {
        removeConnLocked(fd);
        return;
    }
    const ctx = g_req_ctx orelse return;
    while (parseWsFrame(entry.buf[0..entry.len])) |fr| {
        const payload = fr.payload;
        const path_val = c.JS_NewStringLen(ctx, entry.path[0..entry.path_len].ptr, entry.path_len);
        const payload_val = c.JS_NewStringLen(ctx, payload.ptr, payload.len);
        const conn_val = c.JS_NewInt64(ctx, @intCast(entry.conn_id));
        const undefv: c.JSValue = .{ .u = .{ .int32 = 0 }, .tag = c.JS_TAG_UNDEFINED };
        const args = [_]c.JSValue{ path_val, undefv, payload_val, conn_val };
        const result = c.JS_Call(ctx, entry.cb, undefv, 4, @constCast(&args));
        c.JS_FreeValue(ctx, path_val);
        c.JS_FreeValue(ctx, payload_val);
        c.JS_FreeValue(ctx, conn_val);
        // 响应走模块级 g_body_buf（2M——chat history/web-shell 大资产面；原 16KB 栈缓冲静默丢帧已踩）
        var resp_len: usize = 0;
        if (c.JS_IsUndefined(result) or c.JS_IsNull(result)) {
            // guest 静默（RPC 面：无回复帧）
            c.JS_FreeValue(ctx, result);
            const remain0 = entry.len - fr.total;
            std.mem.copyForwards(u8, entry.buf[0..remain0], entry.buf[fr.total..entry.len]);
            entry.len = remain0;
            continue;
        }
        if (!c.JS_IsException(result)) {
            const s = c.JS_ToCStringLen(ctx, null, result);
            if (s) |sp| {
                const text = std.mem.span(sp);
                if (text.len <= g_body_buf.len) {
                    @memcpy(g_body_buf[0..text.len], text);
                    resp_len = text.len;
                }
                c.JS_FreeCString(ctx, sp);
            }
            c.JS_FreeValue(ctx, result);
        } else {
            const ex = c.JS_GetException(ctx);
            c.JS_FreeValue(ctx, ex);
        }
        writeWsFrame(fd, g_body_buf[0..resp_len]);
        const remain = entry.len - fr.total;
        std.mem.copyForwards(u8, entry.buf[0..remain], entry.buf[fr.total..entry.len]);
        entry.len = remain;
    }
}

fn callbackForPath(path: []const u8) ?c.JSValue {    for (&g_routes) |*r| {
        if (!r.used) continue;
        const hit = if (r.exact)
            std.mem.eql(u8, r.path, path)
        else
            std.mem.startsWith(u8, path, r.path);
        if (hit) return r.cb;
    }
    return null;
}

fn buildHeaders(ctx: ?*c.JSContext, raw: []const u8) c.JSValue {
    const obj = c.JS_NewObject(ctx);
    var it = std.mem.splitSequence(u8, raw, "\r\n");
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t\r\n");
        const val = std.mem.trim(u8, line[colon + 1 ..], " \t\r\n");
        var key_lower: [64]u8 = undefined;
        if (key.len > key_lower.len) continue;
        for (key, 0..) |ch, i| {
            key_lower[i] = if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
        }
        const key_z = std.heap.page_allocator.dupeZ(u8, key_lower[0..key.len]) catch continue;
        defer std.heap.page_allocator.free(key_z);
        const val_z = std.heap.page_allocator.dupeZ(u8, val) catch continue;
        defer std.heap.page_allocator.free(val_z);
        _ = c.JS_SetPropertyStr(ctx, obj, key_z.ptr, c.JS_NewString(ctx, val_z.ptr));
    }
    return obj;
}

fn callGuest(req: http_svc.Request, cb: c.JSValue, ct_out: *[]const u8, st_out: *u16, sse_out: *bool, conn_id: usize) []const u8 {
    const ctx = g_req_ctx orelse return "no ctx";
    const path_val = c.JS_NewStringLen(ctx, req.path.ptr, req.path.len);
    if (c.JS_IsException(path_val)) return "bad path";
    const hdr_val = buildHeaders(ctx, req.headers);
    const undefv: c.JSValue = .{ .u = .{ .int32 = 0 }, .tag = c.JS_TAG_UNDEFINED };
    // body 第3参：仅 POST 传递（WS/GET 的帧语义无 body——undefined 保持）
    if (std.mem.eql(u8, req.method, "POST")) {
        const body_val = c.JS_NewStringLen(ctx, req.body.ptr, req.body.len);
        const args = [_]c.JSValue{ path_val, hdr_val, body_val };
        const result = c.JS_Call(ctx, cb, undefv, 3, @constCast(&args));
        c.JS_FreeValue(ctx, path_val);
        c.JS_FreeValue(ctx, hdr_val);
        c.JS_FreeValue(ctx, body_val);
        if (c.JS_IsException(result)) {
            const ex = c.JS_GetException(ctx);
            c.JS_FreeValue(ctx, ex);
            return "handler error";
        }
        return extractResponse(ctx, result, ct_out, st_out, sse_out);
    }
    const conn_val = c.JS_NewInt64(ctx, @intCast(conn_id));
    // 4 参形（path, headers, frame=undefined, connId）——与 WS 升级回调同构（第三参必须保持
    // undefined，否则 WS handler 把 connId 当 frame；SSE/GET handler 从第四参取 connId）
    const args = [_]c.JSValue{ path_val, hdr_val, undefv, conn_val };
    const result = c.JS_Call(ctx, cb, undefv, 4, @constCast(&args));
    c.JS_FreeValue(ctx, path_val);
    c.JS_FreeValue(ctx, hdr_val);
    c.JS_FreeValue(ctx, conn_val);
    if (c.JS_IsException(result)) {
        const ex = c.JS_GetException(ctx);
        c.JS_FreeValue(ctx, ex);
        return "handler error";
    }
    return extractResponse(ctx, result, ct_out, st_out, sse_out);
}

// 响应契约：handler 返回 string → text/plain/200（默认）；
// 返回 { body, contentType?, encoding?: "base64", status? } → 自定义类型/二进制体/状态码。
// 响应体/类型生命周期：写入模块级缓冲（单线程同步帧，writeResponse 立即消费）。
fn extractResponse(ctx: ?*c.JSContext, result: c.JSValue, ct_out: *[]const u8, st_out: *u16, sse_out: *bool) []const u8 {
    ct_out.* = "text/plain; charset=utf-8";
    st_out.* = 200;
    sse_out.* = false;
    defer c.JS_FreeValue(ctx, result);
    var body_val = result;
    var is_b64 = false;
    if (c.JS_IsObject(result)) {
        const b = c.JS_GetPropertyStr(ctx, result, "body");
        const ctv = c.JS_GetPropertyStr(ctx, result, "contentType");
        const enc = c.JS_GetPropertyStr(ctx, result, "encoding");
        const stv = c.JS_GetPropertyStr(ctx, result, "status");
        const ssev = c.JS_GetPropertyStr(ctx, result, "sse");
        defer c.JS_FreeValue(ctx, b);
        defer c.JS_FreeValue(ctx, ctv);
        defer c.JS_FreeValue(ctx, enc);
        defer c.JS_FreeValue(ctx, stv);
        defer c.JS_FreeValue(ctx, ssev);
        if (c.JS_IsBool(ssev)) {
            var bv: c_int = 0;
            _ = c.JS_ToInt32(ctx, &bv, ssev);
            if (bv != 0) sse_out.* = true;
        }
        body_val = b;
        if (c.JS_IsString(ctv)) {
            const cts = c.JS_ToCStringLen(ctx, null, ctv);
            if (cts != null) {
                defer c.JS_FreeCString(ctx, cts);
                const ct = std.mem.span(cts);
                if (ct.len > 0 and ct.len <= g_ctype_buf.len) {
                    @memcpy(g_ctype_buf[0..ct.len], ct);
                    ct_out.* = g_ctype_buf[0..ct.len];
                }
            }
        }
        if (c.JS_IsString(enc)) {
            const es = c.JS_ToCStringLen(ctx, null, enc);
            if (es != null) {
                defer c.JS_FreeCString(ctx, es);
                if (std.mem.eql(u8, std.mem.span(es), "base64")) is_b64 = true;
            }
        }
        if (c.JS_IsNumber(stv)) {
            var sv: i32 = 0;
            _ = c.JS_ToInt32(ctx, &sv, stv);
            if (sv >= 100 and sv <= 599) st_out.* = @intCast(sv);
        }
    }
    const s = c.JS_ToCStringLen(ctx, null, body_val) orelse return "handler non-string";
    defer c.JS_FreeCString(ctx, s);
    const text = std.mem.span(s);
    if (is_b64) {
        const n = b64Decode(text, &g_body_buf) orelse return "handler b64 too long";
        g_body_len = n;
        return g_body_buf[0..g_body_len];
    }
    if (text.len > g_body_buf.len) return "handler too long";
    @memcpy(g_body_buf[0..text.len], text);
    g_body_len = text.len;
    return g_body_buf[0..g_body_len];
}

// base64 解码（web-shell 二进制资产面——侧车 .b64 → 原始字节；'='/杂项宽松跳过）
fn b64Decode(src: []const u8, dst: []u8) ?usize {
    const tbl = comptime blk: {
        var t: [256]u8 = [_]u8{255} ** 256;
        for ("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/", 0..) |ch, i| t[ch] = @intCast(i);
        break :blk t;
    };
    var out: usize = 0;
    var acc: u32 = 0;
    var nbits: u32 = 0;
    for (src) |ch| {
        const v = tbl[ch];
        if (v == 255) continue;
        acc = (acc << 6) | v;
        nbits += 6;
        if (nbits >= 8) {
            nbits -= 8;
            if (out >= dst.len) return null;
            dst[out] = @intCast((acc >> @as(u5, @intCast(nbits))) & 0xff);
            out += 1;
        }
    }
    return out;
}

var g_body_buf: [2 * 1024 * 1024]u8 = undefined; // chat history + web-shell 大资产面（shell vendor js 745KB；原 16KB/128KB 会静默截空）
var g_body_len: usize = 0;
var g_ctype_buf: [128]u8 = undefined;
