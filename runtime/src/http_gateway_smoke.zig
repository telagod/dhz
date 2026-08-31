//! http 网关形态 smoke（`zig build http-gateway-smoke-run`）：
//! listen fd 入宿主事件循环：宿主在 run 前 connect+写 → epoll 报 listen 可读
//! → onLoopFdEvent（accept → 读 → guest 路由回调 → 写回）→ 客户端读回。
//! 验证「事件循环直接驱动 guest 回调」（无 request() 同步帧）。零泄漏哨兵。
const std = @import("std");
const hs = @import("host_services.zig");
const http_bridge = @import("http_bridge.zig");
const loop_mod = @import("event_loop.zig");
const http_svc = @import("http_server.zig");

const c = hs.c;
const sock_c = http_svc.c;

const GLUE =
    \\globalThis.__gwHits = 0;
    \\globalThis.__gwReady = dshServices.http.start(18085);
    \\globalThis.__gwH = dshServices.http.handle('/gw', (p) => { globalThis.__gwHits += 1; return 'gw:' + p; });
    \\
;

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, pos, needle)) |at| {
        count += 1;
        pos = at + needle.len;
    }
    return count;
}

fn readGlobalInt(ctx: ?*c.JSContext, name: [*c]const u8) !i32 {
    const global = c.JS_GetGlobalObject(ctx);
    defer c.JS_FreeValue(ctx, global);
    const v = c.JS_GetPropertyStr(ctx, global, name);
    defer c.JS_FreeValue(ctx, v);
    var out: c_int = 0;
    _ = c.JS_ToInt32(ctx, &out, v);
    return out;
}

pub fn main() !void {
    const rt = c.JS_NewRuntime() orelse return error.NewRuntime;
    _ = c.JS_SetDumpFlags(rt, c.JS_DUMP_LEAKS | c.JS_DUMP_ATOM_LEAKS);
    defer c.JS_FreeRuntime(rt);
    const ctx = c.JS_NewContext(rt) orelse return error.NewContext;
    defer c.JS_FreeContext(ctx);

    var loop = try loop_mod.Loop.init();
    defer loop.deinit();
    _ = c.JS_SetContextOpaque(ctx, @ptrCast(&loop));
    loop.attachEngine(@as(?*c.JSRuntime, rt), ctx);
    loop.onFdEvent = http_bridge.onLoopFdEvent;

    const services = [_]hs.Service{ .{ .name = "http", .methods = &http_bridge.serviceMethods } };
    hs.register(ctx, &services);

    const val = c.JS_Eval(ctx, GLUE.ptr, GLUE.len, "glue.js", c.JS_EVAL_TYPE_GLOBAL);
    if (c.JS_IsException(val)) {
        const ex = c.JS_GetException(ctx);
        defer c.JS_FreeValue(ctx, ex);
        const msg = c.JS_ToCStringLen(ctx, null, ex) orelse return error.NoMsg;
        defer c.JS_FreeCString(ctx, msg);
        std.debug.print("gateway smoke: eval exception: {s}\n", .{std.mem.span(msg)});
        return error.EvalFailed;
    }
    c.JS_FreeValue(ctx, val);

    // 宿主侧客户端：连接 + 写请求（run 前；backlog 承载），事件循环期间被服务端处理
    const client = sock_c.dsh_sock_connect(18085);
    if (client < 0) return error.ConnectFailed;
    defer _ = sock_c.dsh_sock_close(client);
    const req = "GET /gw HTTP/1.1\r\nHost: localhost\r\n\r\n";
    _ = sock_c.dsh_sock_write(client, req.ptr, req.len);

    loop.run(300);

    var resp_buf: [16 * 1024]u8 = undefined;
    var used: usize = 0;
    while (used < resp_buf.len) {
        const n = sock_c.dsh_sock_read(client, resp_buf[used..].ptr, resp_buf.len - used);
        if (n <= 0) break;
        used += @intCast(n);
        if (std.mem.indexOf(u8, resp_buf[0..used], "\r\n\r\n") != null) break;
    }
    const body_start = std.mem.indexOf(u8, resp_buf[0..used], "\r\n\r\n") orelse return error.BadResponse;
    const body = resp_buf[body_start + 4 .. used];

    const hits = try readGlobalInt(ctx, "__gwHits");
    std.debug.print("gateway smoke: body='{s}' gwHits={d}\n", .{ body, hits });
    if (!std.mem.eql(u8, body, "gw:/gw")) return error.BodyMismatch;
    if (hits != 1) return error.GuestCbNotDriven;

    // 信任栅栏：反弹 host（DNS-rebinding）→ 403
    const evil = sock_c.dsh_sock_connect(18085);
    if (evil < 0) return error.ConnectFailed;
    defer _ = sock_c.dsh_sock_close(evil);
    const evil_req = "GET /gw HTTP/1.1\r\nHost: evil.example:3080\r\nOrigin: http://evil.example:3080\r\nSec-Fetch-Site: same-origin\r\n\r\n";
    _ = sock_c.dsh_sock_write(evil, evil_req.ptr, evil_req.len);
    loop.run(300);
    var ebuf: [1024]u8 = undefined;
    var eused: usize = 0;
    while (eused < ebuf.len) {
        const n = sock_c.dsh_sock_read(evil, ebuf[eused..].ptr, ebuf.len - eused);
        if (n <= 0) break;
        eused += @intCast(n);
        if (std.mem.indexOf(u8, ebuf[0..eused], "\r\n\r\n") != null) break;
    }
    const ebody_start = std.mem.indexOf(u8, ebuf[0..eused], "\r\n\r\n") orelse return error.BadResponse;
    const ebody = ebuf[ebody_start + 4 .. eused];
    std.debug.print("gateway smoke: rebound host -> '{s}'\n", .{ebody});
    if (!std.mem.eql(u8, ebody, "forbidden")) return error.ReboundNotForbidden;

    // ---- 分帧状态机：半帧写入 → 未处理；补全 → 响应 ----
    const split = sock_c.dsh_sock_connect(18085);
    if (split < 0) return error.ConnectFailed;
    defer _ = sock_c.dsh_sock_close(split);
    const part1 = "GET /gw HTTP/1.1\r\nHo";
    const part2 = "st: localhost\r\n\r\n";
    _ = sock_c.dsh_sock_write(split, part1.ptr, part1.len);
    loop.run(60); // 半帧：状态机等待
    _ = sock_c.dsh_sock_write(split, part2.ptr, part2.len);
    loop.run(150); // 完整帧 → 处理 → 写回 → 关闭

    var sbuf: [1024]u8 = undefined;
    var sused: usize = 0;
    while (sused < sbuf.len) {
        const n = sock_c.dsh_sock_read(split, sbuf[sused..].ptr, sbuf.len - sused);
        if (n <= 0) break;
        sused += @intCast(n);
        if (std.mem.indexOf(u8, sbuf[0..sused], "\r\n\r\n") != null) break;
    }
    const sbody_start = std.mem.indexOf(u8, sbuf[0..sused], "\r\n\r\n") orelse return error.BadResponse;
    const sbody = sbuf[sbody_start + 4 .. sused];
    std.debug.print("gateway smoke: split-frame -> '{s}'\n", .{sbody});
    if (!std.mem.eql(u8, sbody, "gw:/gw")) return error.SplitFrameFailed;

    // ---- 并发两连接：事件循环交替驱动 ----
    const hits_before = try readGlobalInt(ctx, "__gwHits");
    const c1 = sock_c.dsh_sock_connect(18085);
    const c2 = sock_c.dsh_sock_connect(18085);
    if (c1 < 0 or c2 < 0) return error.ConnectFailed;
    defer _ = sock_c.dsh_sock_close(c1);
    defer _ = sock_c.dsh_sock_close(c2);
    const req_full = "GET /gw HTTP/1.1\r\nHost: localhost\r\n\r\n";
    _ = sock_c.dsh_sock_write(c1, req_full.ptr, req_full.len);
    _ = sock_c.dsh_sock_write(c2, req_full.ptr, req_full.len);
    loop.run(200);

    const hits_after = try readGlobalInt(ctx, "__gwHits");
    std.debug.print("gateway smoke: concurrent gwHits {d} -> {d}\n", .{ hits_before, hits_after });
    if (hits_after - hits_before != 2) return error.ConcurrentCbCount;

    // ---- keep-alive：同连接两个请求（流水线） ----
    const hb_before = try readGlobalInt(ctx, "__gwHits");
    const ka = sock_c.dsh_sock_connect(18085);
    if (ka < 0) return error.ConnectFailed;
    const ka_req = "GET /gw HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n" ++
        "GET /gw HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n";
    _ = sock_c.dsh_sock_write(ka, ka_req.ptr, ka_req.len);
    loop.run(200); // 事件循环：读全部 → 两帧处理 → keep-alive 保持

    var kbuf: [4096]u8 = undefined;
    var kused: usize = 0;
    while (kused < kbuf.len) {
        const n = sock_c.dsh_sock_read(ka, kbuf[kused..].ptr, kbuf.len - kused);
        if (n <= 0) break;
        kused += @intCast(n);
        if (countOccurrences(kbuf[0..kused], "gw:/gw") >= 2) break;
    }
    const ka_hits = try readGlobalInt(ctx, "__gwHits");
    const keep_hdr = std.mem.indexOf(u8, kbuf[0..kused], "keep-alive") != null;
    const bodies = countOccurrences(kbuf[0..kused], "gw:/gw");
    std.debug.print("gateway smoke: keep-alive bodies={d} hdr={} gwHits {d}->{d}\n", .{ bodies, keep_hdr, hb_before, ka_hits });
    if (bodies != 2) return error.KeepAliveBodyCount;
    if (!keep_hdr) return error.KeepAliveHeaderMissing;
    if (ka_hits - hb_before != 2) return error.KeepAliveCbCount;
    _ = sock_c.dsh_sock_close(ka);
    loop.run(80); // close 事件 → 连接表移除

    std.debug.print("gateway smoke OK: epoll -> async accept -> guest route callback -> response: PASS\n", .{});
    std.process.exit(0);
}
