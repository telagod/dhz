//! M-2 工具链 spike：Zig ↔ quickjs-ng 最小集成验证。
//! 评估少量表达式，证明：编译链接、JSValue 生命周期、引擎能力（BigInt 等）。
//! 运行: `zig build spike`

const std = @import("std");

const c = @cImport({
    @cInclude("quickjs.h");
});

fn evalToUtf8(ctx: ?*c.JSContext, src: [*]const u8, len: usize) ![]const u8 {
    const v = c.JS_Eval(ctx, src, len, "spike.js", c.JS_EVAL_TYPE_GLOBAL);
    if (c.JS_IsException(v)) return error.JsException;
    defer c.JS_FreeValue(ctx, v);
    const js_string = c.JS_ToCStringLen(ctx, null, v) orelse return error.ToCString;
    defer c.JS_FreeCString(ctx, js_string);
    return std.mem.span(js_string);
}

pub fn main() !void {
    const rt = c.JS_NewRuntime() orelse return error.NewRuntime;
    defer c.JS_FreeRuntime(rt);
    const ctx = c.JS_NewContext(rt) orelse return error.NewContext;
    defer c.JS_FreeContext(ctx);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const probes = [_][]const u8{
        "1 + 1",
        "typeof BigInt(2n ** 64n)",
        "Object.fromEntries([['a', 1]]).a",
        "[1,2,3].map(x => x * x).join(',')",
    };
    var ok: usize = 0;
    for (probes) |expr| {
        const out = try evalToUtf8(ctx, expr.ptr, expr.len);
        const owned = try allocator.dupe(u8, out);
        std.debug.print("  {s:<40} => {s}\n", .{ expr, owned });
        ok += 1;
    }
    std.debug.print("quickjs-ng spike: {d}/{d} probes OK\n", .{ ok, probes.len });
    if (ok != probes.len) return error.ProbeFailed;
}
