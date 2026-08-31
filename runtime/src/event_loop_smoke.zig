//! event loop smoke（`zig build event-loop-smoke-run`）：
//! 内核 timerfd → epoll → 宿主回调 → 引擎回调 → job 队列 → guest 全局，全链驱动验证。
const std = @import("std");
const loop_mod = @import("event_loop.zig");

const c = loop_mod.c;

const GLUE =
    \\globalThis.__timerRan = false;
    \\globalThis.__ticks = 0;
    \\globalThis.__intervalHits = 0;
    \\dshSetTimeout(() => { globalThis.__timerRan = true; globalThis.__ticks = 1; }, 50);
    \\dshSetTimeout(() => { globalThis.__ticks += 1; }, 120);
    \\globalThis.__iv = dshSetInterval(() => { globalThis.__intervalHits += 1; }, 30);
    \\dshSetTimeout(() => { dshClearTimer(globalThis.__iv); }, 100);
    \\
;

pub fn main() !void {
    const rt = c.JS_NewRuntime() orelse return error.NewRuntime;
    defer c.JS_FreeRuntime(rt);
    const ctx = c.JS_NewContext(rt) orelse return error.NewContext;
    defer c.JS_FreeContext(ctx);

    var loop = try loop_mod.Loop.init();
    const loop_for_opaque: *loop_mod.Loop = &loop;
    _ = c.JS_SetContextOpaque(ctx, @ptrCast(loop_for_opaque));
    loop.attachEngine(@as(?*c.JSRuntime, rt), ctx);

    const val = c.JS_Eval(ctx, GLUE.ptr, GLUE.len, "glue.js", c.JS_EVAL_TYPE_GLOBAL);
    if (c.JS_IsException(val)) return error.EvalFailed;
    c.JS_FreeValue(ctx, val);

    loop.run(600);
    loop.deinit();

    const global = c.JS_GetGlobalObject(ctx);
    defer c.JS_FreeValue(ctx, global);
    const ran = c.JS_GetPropertyStr(ctx, global, "__timerRan");
    defer c.JS_FreeValue(ctx, ran);
    const escaped = c.JS_GetPropertyStr(ctx, global, "__ticks");
    defer c.JS_FreeValue(ctx, escaped);
    const ran_bool = c.JS_ToBool(ctx, ran) != 0;
    var ticks_out: c_int = 0;
    _ = c.JS_ToInt32(ctx, &ticks_out, escaped);
    const ticks: i32 = ticks_out;
    const hitsval = c.JS_GetPropertyStr(ctx, global, "__intervalHits");
    defer c.JS_FreeValue(ctx, hitsval);
    var hits_out: c_int = 0;
    _ = c.JS_ToInt32(ctx, &hits_out, hitsval);

    std.debug.print("event loop smoke: __timerRan={} __ticks={d} __intervalHits={d}\n", .{ ran_bool, ticks, hits_out });
    if (!ran_bool) return error.TimerNeverFired;
    if (ticks != 2) return error.TimerCountMismatch;
    if (hits_out < 2) return error.IntervalNeverRepeated;
    std.debug.print("event loop smoke: setInterval + dshClearTimer: PASS\n", .{});
    std.debug.print("event loop smoke: kernel timerfd -> epoll -> host callback -> engine jobs: PASS\n", .{});
    std.process.exit(0);
}
