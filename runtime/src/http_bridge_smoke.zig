//! http 桥 smoke（`zig build http-bridge-smoke-run`）：
//! dshServices.http：start(port) → handle(path,fn,exact) 注册 guest 回调 →
//! request(port,path) 同步自往返（connect+服务侧+读回）→ stop 清理。
//! 断言：exact 路由命中/404 fallback/prefix 路由。零泄漏哨兵。
const std = @import("std");
const hs = @import("host_services.zig");
const http_bridge = @import("http_bridge.zig");

const c = hs.c;

const GLUE =
    \\globalThis.__hsS = dshServices.http.start(18081);
    \\globalThis.__hsH = dshServices.http.handle('/echo', (p) => 'echo:' + p);
    \\globalThis.__hsHP = dshServices.http.handle('/api/', (p) => 'api:' + p, false);
    \\globalThis.__r1 = dshServices.http.request(18081, '/echo');
    \\globalThis.__r2 = dshServices.http.request(18081, '/api/foo');
    \\globalThis.__r3 = dshServices.http.request(18081, '/nope');
    \\dshServices.http.stop();
    \\
;

fn readGlobalStr(ctx: ?*c.JSContext, name: [*c]const u8) ![]const u8 {
    const global = c.JS_GetGlobalObject(ctx);
    defer c.JS_FreeValue(ctx, global);
    const v = c.JS_GetPropertyStr(ctx, global, name);
    defer c.JS_FreeValue(ctx, v);
    const s = c.JS_ToCStringLen(ctx, null, v) orelse return error.NoText;
    defer c.JS_FreeCString(ctx, s);
    return std.heap.page_allocator.dupe(u8, std.mem.span(s));
}

pub fn main() !void {
    const rt = c.JS_NewRuntime() orelse return error.NewRuntime;
    _ = c.JS_SetDumpFlags(rt, c.JS_DUMP_LEAKS | c.JS_DUMP_ATOM_LEAKS);
    defer c.JS_FreeRuntime(rt);
    const ctx = c.JS_NewContext(rt) orelse return error.NewContext;
    defer c.JS_FreeContext(ctx);

    const services = [_]hs.Service{ .{ .name = "http", .methods = &http_bridge.serviceMethods } };
    hs.register(ctx, &services);

    const val = c.JS_Eval(ctx, GLUE.ptr, GLUE.len, "glue.js", c.JS_EVAL_TYPE_GLOBAL);
    if (c.JS_IsException(val)) {
        const ex = c.JS_GetException(ctx);
        defer c.JS_FreeValue(ctx, ex);
        const msg = c.JS_ToCStringLen(ctx, null, ex) orelse return error.NoMsg;
        defer c.JS_FreeCString(ctx, msg);
        std.debug.print("http bridge smoke: eval exception: {s}\n", .{std.mem.span(msg)});
        return error.EvalFailed;
    }
    c.JS_FreeValue(ctx, val);

    const r1 = try readGlobalStr(ctx, "__r1");
    defer std.heap.page_allocator.free(r1);
    const r2 = try readGlobalStr(ctx, "__r2");
    defer std.heap.page_allocator.free(r2);
    const r3 = try readGlobalStr(ctx, "__r3");
    defer std.heap.page_allocator.free(r3);

    std.debug.print("http bridge smoke: /echo -> '{s}' | /api/foo -> '{s}' | /nope -> '{s}'\n", .{ r1, r2, r3 });
    if (!std.mem.eql(u8, r1, "echo:/echo")) return error.EchoMismatch;
    if (!std.mem.eql(u8, r2, "api:/api/foo")) return error.PrefixMismatch;
    if (!std.mem.eql(u8, r3, "not found")) return error.NotFoundMismatch;
    std.debug.print("http bridge smoke: guest route callbacks via dshServices.http: PASS\n", .{});
    std.process.exit(0);
}
