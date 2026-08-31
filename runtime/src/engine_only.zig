//! 纯引擎复现：连续两次动态 import 同一模块（无宿主 import helper/capture/dispose）。
const std = @import("std");
const c = @cImport({ @cInclude("quickjs.h"); });
const app = @import("app_modules.zig");

fn resolveSpec(name: []const u8) ?[]const u8 {
    for (app.modules) |m| if (std.mem.eql(u8, m.name, name)) return m.name;
    return null;
}
fn moduleSource(name: []const u8) ?[]const u8 {
    for (app.modules) |m| if (std.mem.eql(u8, m.name, name)) return m.src;
    return null;
}
fn normalizer(ctx: ?*c.JSContext, b: [*c]const u8, n: [*c]const u8, at: c.JSValueConst, _: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    _ = at;
    const name = std.mem.span(n);
    const p = c.js_malloc(ctx, name.len + 1) orelse return null;
    @memcpy(@as([*]u8, @ptrCast(p))[0..name.len], name);
    @as([*]u8, @ptrCast(p))[name.len] = 0;
    _ = b;
    return @ptrCast(p);
}
fn loader(ctx: ?*c.JSContext, n: [*c]const u8, u: ?*anyopaque, at: c.JSValueConst) callconv(.c) ?*c.JSModuleDef {
    _ = u;
    _ = at;
    const name = std.mem.span(n);
    var buf: [256]u8 = undefined;
    const cand = if (std.mem.endsWith(u8, name, "/index.js")) name else (std.fmt.bufPrint(&buf, "{s}/index.js", .{name}) catch name);
    const key = resolveSpec(name) orelse resolveSpec(cand) orelse return null;
    const src = moduleSource(key) orelse return null;
    const v = c.JS_Eval(ctx, src.ptr, src.len, key.ptr, c.JS_EVAL_TYPE_MODULE | c.JS_EVAL_FLAG_COMPILE_ONLY);
    if (c.JS_IsException(v)) return null;
    const m: *c.JSModuleDef = @ptrCast(v.u.ptr);
    c.JS_FreeValue(ctx, v);
    return m;
}

pub fn repro() bool {
    const rt = c.JS_NewRuntime() orelse return false;
    defer c.JS_FreeRuntime(rt);
    const ctx = c.JS_NewContext(rt) orelse return false;
    defer c.JS_FreeContext(ctx);
    c.JS_SetModuleLoaderFunc2(rt, null, loader, null, null);
    c.JS_SetModuleNormalizeFunc2(rt, normalizer);
    // 两次独立 JS_Eval（模拟两次 JS_Call 时序）
    var buf: [512]u8 align(64) = undefined;
    const s1 = std.fmt.bufPrint(&buf, "import('{s}').then(a => {{ globalThis.__dsh_capture__ = a; }});", .{"@deepseek-ai/cosmokit"}) catch unreachable;
    const s1_lit = "import('@deepseek-ai/cosmokit').then(a => { globalThis.__dsh_capture__ = a; });";
    std.debug.print("[repro] buf len={d} lit len={d}\n", .{ s1.len, s1_lit.len });
    var i: usize = 0;
    while (i < s1.len) : (i += 1) {
        if (s1[i] != s1_lit[i]) {
            std.debug.print("[repro] first diff at {d}: buf={d} lit={d}\n", .{ i, s1[i], s1_lit[i] });
            break;
        }
    }
    if (i == s1.len) std.debug.print("[repro] bytes identical\n", .{});
    const v1 = c.JS_Eval(ctx, s1.ptr, s1.len, "repro1.js", c.JS_EVAL_TYPE_GLOBAL);
    if (c.JS_IsException(v1)) {
        std.debug.print("eval1 failed\n", .{});
        return false;
    }
    c.JS_FreeValue(ctx, v1);
    var jc: ?*c.JSContext = ctx;
    var guard: usize = 0;
    while (c.JS_ExecutePendingJob(rt, &jc) > 0) : (guard += 1) if (guard > 1024) return false;
    var buf2: [512]u8 align(64) = undefined;
    const s2 = std.fmt.bufPrint(&buf2, "import('{s}').then(a => {{ globalThis.y = typeof a.hyphenate; }});", .{"@deepseek-ai/cosmokit"}) catch unreachable;
    const v2 = c.JS_Eval(ctx, s2.ptr, s2.len, "repro2.js", c.JS_EVAL_TYPE_GLOBAL);
    if (c.JS_IsException(v2)) {
        std.debug.print("eval2 failed\n", .{});
        return false;
    }
    c.JS_FreeValue(ctx, v2);
    guard = 0;
    while (c.JS_ExecutePendingJob(rt, &jc) > 0) : (guard += 1) if (guard > 1024) return false;
    const g = c.JS_GetGlobalObject(ctx);
    defer c.JS_FreeValue(ctx, g);
    const y = c.JS_GetPropertyStr(ctx, g, "y");
    defer c.JS_FreeValue(ctx, y);
    const s = c.JS_ToCStringLen(ctx, null, y) orelse return false;
    defer c.JS_FreeCString(ctx, s);
    std.debug.print("[engine-only] y = {s}\n", .{std.mem.span(s)});
    return std.mem.eql(u8, std.mem.span(s), "function");
}
