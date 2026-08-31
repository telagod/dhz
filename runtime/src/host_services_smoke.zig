//! 宿主服务注册表 smoke（`zig build host-services-smoke-run`）：
//! dshServices 对象树 = fs（readText/writeText/size）+ timer（setTimeout/...），
//! guest 经对象面驱动 Zig fs 与宿主事件循环；零泄漏哨兵（dump flags）。
const std = @import("std");
const hs = @import("host_services.zig");
const bridge = @import("fs_bridge.zig");
const loop_mod = @import("event_loop.zig");

const c = hs.c;

const GLUE =
    \\globalThis.__hsW = dshServices.fs.writeText('/tmp/dsh-hs.txt', 'registry-ok');
    \\globalThis.__hsR = dshServices.fs.readText('/tmp/dsh-hs.txt');
    \\globalThis.__hsSZ = dshServices.fs.size('/tmp/dsh-hs.txt');
    \\globalThis.__hsTick = 0;
    \\dshServices.timer.setTimeout(() => { globalThis.__hsTick = 7; }, 30);
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
    // 零泄漏哨兵（与 cordis-timer-smoke 同法）
    _ = c.JS_SetDumpFlags(rt, c.JS_DUMP_LEAKS | c.JS_DUMP_ATOM_LEAKS);
    defer c.JS_FreeRuntime(rt);
    const ctx = c.JS_NewContext(rt) orelse return error.NewContext;
    defer c.JS_FreeContext(ctx);

    var loop = try loop_mod.Loop.init();
    defer loop.deinit();
    _ = c.JS_SetContextOpaque(ctx, @ptrCast(&loop));
    loop.attachEngine(@as(?*c.JSRuntime, rt), ctx);

    const services = [_]hs.Service{
        .{ .name = "fs", .methods = &bridge.serviceMethods },
        .{ .name = "timer", .methods = &loop_mod.serviceMethods },
    };
    hs.register(ctx, &services);

    const val = c.JS_Eval(ctx, GLUE.ptr, GLUE.len, "glue.js", c.JS_EVAL_TYPE_GLOBAL);
    if (c.JS_IsException(val)) {
        const ex = c.JS_GetException(ctx);
        defer c.JS_FreeValue(ctx, ex);
        const msg = c.JS_ToCStringLen(ctx, null, ex) orelse return error.NoMsg;
        defer c.JS_FreeCString(ctx, msg);
        std.debug.print("host services smoke: eval exception: {s}\n", .{std.mem.span(msg)});
        return error.EvalFailed;
    }
    c.JS_FreeValue(ctx, val);

    loop.run(180);
    loop.drainJobs();

    const wb = c.JS_GetGlobalObject(ctx);
    defer c.JS_FreeValue(ctx, wb);
    const wv = c.JS_GetPropertyStr(ctx, wb, "__hsW");
    defer c.JS_FreeValue(ctx, wv);
    const w_ok = c.JS_ToBool(ctx, wv) != 0;

    const rd = try readGlobalStr(ctx, "__hsR");
    defer std.heap.page_allocator.free(rd);
    const sz = try readGlobalInt(ctx, "__hsSZ");
    const tick = try readGlobalInt(ctx, "__hsTick");

    std.debug.print("host services smoke: fs.writeText={} readback='{s}' size={d} timer.tick={d}\n", .{ w_ok, rd, sz, tick });
    if (!w_ok) return error.WriteNotTrue;
    if (!std.mem.eql(u8, rd, "registry-ok")) return error.ReadbackMismatch;
    if (sz != 11) return error.SizeMismatch;
    if (tick != 7) return error.TimerTickMissing;
    std.debug.print("host services smoke: dshServices object tree (fs + timer) fully driven: PASS\n", .{});
    std.process.exit(0);
}
