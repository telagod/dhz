//! CJS require() 重入 spike —— 最终设计：解析期预编译工厂。
//! 关键事实（本轮 gdb 实测）：
//!   - 解析期（loader 回调）内编译模块：安全（cordis spike 证明）
//!   - 运行期（模块顶层执行中）JS_Eval 编译 >=30B 的 ASCII 源：本引擎构建
//!     报 "invalid UTF-8 sequence"（且三个已知报错点均未命中，属更深层问题；
//!     3 字节 "1+1" 正常）→ 运行期绝不做编译
//! 设计：CJS 模块在解析期（loader 回调）编译工厂函数并持有；
//!       require() 运行期仅 JS_Call 已编译的工厂（无编译、无跨上下文、无 JSON）。
//! 断言：main → cjs_a(require cjs_b) → 42。运行: `zig build require-spike-run`

const std = @import("std");

const c = @cImport({
    @cInclude("quickjs.h");
});

fn jsExc() c.JSValue {
    return .{ .u = .{ .int32 = 0 }, .tag = c.JS_TAG_EXCEPTION };
}
fn jsUndefConst() c.JSValue {
    return .{ .u = .{ .int32 = 0 }, .tag = c.JS_TAG_UNDEFINED };
}

const main_mjs =
    \\import cjs from './cjs_a.cjs'
    \\globalThis.__result = JSON.stringify(cjs)
    \\
;
const cjs_a =
    \\const b = require('./cjs_b.cjs')
    \\module.exports = { answer: b.base + 2 }
    \\
;
const cjs_b =
    \\module.exports = { base: 40 }
    \\
;

const ModuleKind = enum { esm, cjs };

/// 解析期预编译的 CJS 工厂表（name -> factory JSValue）。
/// 生命周期：随 context 释放（本 spike 为演示，真实实现挂 fiber/context）。
const Factories = struct { name: []const u8, factory: c.JSValue, used: bool = false };
var g_factories: [16]Factories = undefined;

fn stashedFactory(name: []const u8) ?c.JSValue {
    for (&g_factories) |*e| {
        if (e.used and std.mem.eql(u8, e.name, name)) return e.factory;
    }
    return null;
}

fn stashFactory(name: []const u8, factory: c.JSValue) void {
    for (&g_factories) |*e| {
        if (!e.used) {
            e.* = .{ .name = name, .factory = factory, .used = true };
            return;
        }
    }
    std.debug.print("[loader] factory table full: {s}\n", .{name});
}

fn moduleSource(name: []const u8) ?struct { kind: ModuleKind, src: []const u8 } {
    if (std.mem.eql(u8, name, "cjs_a.cjs") or std.mem.eql(u8, name, "./cjs_a.cjs")) return .{ .kind = .cjs, .src = cjs_a };
    if (std.mem.eql(u8, name, "cjs_b.cjs") or std.mem.eql(u8, name, "./cjs_b.cjs")) return .{ .kind = .cjs, .src = cjs_b };
    return null;
}

fn normalizeModule(
    ctx: ?*c.JSContext,
    module_base_name: [*c]const u8,
    module_name: [*c]const u8,
    attributes: c.JSValueConst,
    userdata: ?*anyopaque,
) callconv(.c) ?[*:0]u8 {
    _ = attributes;
    _ = userdata;
    const base = std.mem.span(module_base_name);
    const name = std.mem.span(module_name);
    if (!std.mem.startsWith(u8, name, "./") and !std.mem.startsWith(u8, name, "../")) {
        const copy = c.js_malloc(ctx, name.len + 1).?;
        const out: [*]u8 = @ptrCast(copy);
        @memcpy(out[0..name.len], name);
        out[name.len] = 0;
        return @ptrCast(out);
    }
    const rel = if (std.mem.startsWith(u8, name, "./")) name[2..] else name;
    const dir = if (std.mem.lastIndexOfScalar(u8, base, '/')) |idx| base[0..idx] else "";
    const prefix_len = if (dir.len == 0) 0 else dir.len + 1;
    const total = prefix_len + rel.len;
    const copy = c.js_malloc(ctx, total + 1).?;
    const out: [*]u8 = @ptrCast(copy);
    if (dir.len > 0) {
        @memcpy(out[0..dir.len], dir);
        out[dir.len] = '/';
    }
    @memcpy(out[prefix_len..][0..rel.len], rel);
    out[total] = 0;
    return @ptrCast(out);
}

/// 运行期 require：只查表 + JS_Call 预编译工厂（无任何运行期编译）。
fn requireFn(
    ctx: ?*c.JSContext,
    this_val: c.JSValueConst,
    argc: c_int,
    argv: [*c]const c.JSValueConst,
) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 1) return c.JS_ThrowTypeError(ctx, "require: specifier is required", @as(c_int, 0));
    const spec = c.JS_ToCStringLen(ctx, null, argv[0]) orelse return jsExc();
    defer c.JS_FreeCString(ctx, spec);
    const name = std.mem.span(spec);
    const entry = moduleSource(name) orelse
        return c.JS_ThrowReferenceError(ctx, "cannot find module '%s'", name.ptr);
    if (entry.kind != .cjs)
        return c.JS_ThrowTypeError(ctx, "require: ESM via require is not supported", @as(c_int, 0));

    const key = if (std.mem.startsWith(u8, name, "./")) name[2..] else name;
    const factory = stashedFactory(key) orelse
        return c.JS_ThrowReferenceError(ctx, "module not pre-compiled: '%s'", name.ptr);

    const module_obj = c.JS_NewObject(ctx);
    if (c.JS_IsException(module_obj)) return jsExc();
    const exports_obj = c.JS_NewObject(ctx);
    if (c.JS_IsException(exports_obj)) {
        c.JS_FreeValue(ctx, module_obj);
        return jsExc();
    }
    _ = c.JS_SetPropertyStr(ctx, module_obj, "exports", c.JS_DupValue(ctx, exports_obj));

    const undefv = jsUndefConst();
    const g = c.JS_GetGlobalObject(ctx);
    const require_val = c.JS_GetPropertyStr(ctx, g, "__dshRequire");
    c.JS_FreeValue(ctx, g);
    const argv2: [5]c.JSValueConst = .{ module_obj, exports_obj, require_val, undefv, undefv };
    const call_result = c.JS_Call(ctx, factory, undefv, 5, @constCast(argv2[0..].ptr));
    if (c.JS_IsException(call_result)) {
        const ex = c.JS_GetException(ctx);
        const msg = c.JS_ToCStringLen(ctx, null, ex);
        if (msg) |m| std.debug.print("[require] call failed: {s}\n", .{std.mem.span(m)});
        c.JS_FreeValue(ctx, require_val);
        c.JS_FreeValue(ctx, module_obj);
        c.JS_FreeValue(ctx, exports_obj);
        return jsExc();
    }
    c.JS_FreeValue(ctx, call_result);
    c.JS_FreeValue(ctx, require_val);
    const exports_final = c.JS_GetPropertyStr(ctx, module_obj, "exports");
    c.JS_FreeValue(ctx, module_obj);
    c.JS_FreeValue(ctx, exports_obj);
    return exports_final;
}

/// 预编译一个 CJS 模块及其 require 依赖（DFS）—— 都是解析期，编译安全。
fn precompileCjs(ctx: ?*c.JSContext, name: []const u8) void {
    if (stashedFactory(name) != null) return;
    const entry = moduleSource(name) orelse return;
    if (entry.kind != .cjs) return;

    // 先依赖后自身（保证链式 require 可用）
    var rest = entry.src;
    while (std.mem.indexOf(u8, rest, "require('")) |at| {
        rest = rest[at + 9..];
        const end = std.mem.indexOfScalar(u8, rest, '\'') orelse break;
        const dep = rest[0..end];
        const dep_key = if (std.mem.startsWith(u8, dep, "./")) dep[2..] else dep;
        precompileCjs(ctx, dep_key);
        rest = rest[end..];
    }

    const fs = std.mem.concat(std.heap.page_allocator, u8, &.{
        "(function (module, exports, require, __dirname, __filename) {",
        entry.src,
        "});",
    }) catch return;
    const fv = c.JS_Eval(ctx, fs.ptr, fs.len, "cjs-factory.js", c.JS_EVAL_TYPE_GLOBAL);
    if (c.JS_IsException(fv)) {
        const ex = c.JS_GetException(ctx);
        const msg = c.JS_ToCStringLen(ctx, null, ex);
        if (msg) |m| std.debug.print("[loader] factory compile failed: {s}\n", .{std.mem.span(m)});
        return;
    }
    stashFactory(name, fv);
}

/// 解析期 loader：CJS 额外预编译工厂（stash），返回 ESM 包装模块（import 路径不变）。
fn moduleLoader(
    ctx: ?*c.JSContext,
    module_name: [*c]const u8,
    userdata: ?*anyopaque,
    attributes: c.JSValueConst,
) callconv(.c) ?*c.JSModuleDef {
    _ = userdata;
    _ = attributes;
    const name = std.mem.span(module_name);
    const entry = moduleSource(name) orelse {
        std.debug.print("[loader] unknown module: {s}\n", .{name});
        return null;
    };

    if (entry.kind == .cjs and stashedFactory(name) == null) {
        // 解析期预编译（含 require 依赖 DFS）——此时编译安全；运行期勿编译。
        precompileCjs(ctx, name);
    }

    // ESM 包装（import 路径保持不变：default = module.exports）
    const wrapped = std.mem.concat(std.heap.page_allocator, u8, &.{
        "const module = { exports: {} };",
        "\n(function (module, exports, require, __dirname, __filename) {",
        entry.src,
        "\n})(module, module.exports, (typeof __dshRequire === 'function' ? __dshRequire : () => { throw new Error('require not wired'); }), '.', 'cjs');",
        "\nexport default module.exports;\n",
    }) catch return null;
    const val = c.JS_Eval(ctx, wrapped.ptr, wrapped.len, name.ptr, c.JS_EVAL_TYPE_MODULE | c.JS_EVAL_FLAG_COMPILE_ONLY);
    if (c.JS_IsException(val)) {
        const ex = c.JS_GetException(ctx);
        const msg = c.JS_ToCStringLen(ctx, null, ex);
        if (msg) |m| std.debug.print("[loader] compile failed: {s} -> {s}\n", .{ name, std.mem.span(m) });
        c.JS_FreeValue(ctx, ex);
        return null;
    }
    const m: *c.JSModuleDef = @ptrCast(val.u.ptr);
    c.JS_FreeValue(ctx, val);
    return m;
}

pub fn main() !void {
    const rt = c.JS_NewRuntime() orelse return error.NewRuntime;
    const ctx = c.JS_NewContext(rt) orelse return error.NewContext;
    defer {
        for (&g_factories) |*e| {
            if (e.used) c.JS_FreeValue(ctx, e.factory);
        }
        c.JS_FreeContext(ctx);
        c.JS_FreeRuntime(rt);
    }

    c.JS_SetModuleLoaderFunc2(rt, null, moduleLoader, null, null);
    c.JS_SetModuleNormalizeFunc2(rt, normalizeModule);

    const global = c.JS_GetGlobalObject(ctx);
    defer c.JS_FreeValue(ctx, global);
    const f = c.JS_NewCFunction(ctx, requireFn, "__dshRequire", 1);
    _ = c.JS_SetPropertyStr(ctx, global, "__dshRequire", f);

    var val = c.JS_Eval(ctx, main_mjs.ptr, main_mjs.len, "main.mjs", c.JS_EVAL_TYPE_MODULE | c.JS_EVAL_FLAG_COMPILE_ONLY);
    if (c.JS_IsException(val)) return error.MainCompile;
    val = c.JS_EvalFunction(ctx, val);
    defer c.JS_FreeValue(ctx, val);
    if (c.JS_IsException(val)) return error.MainRun;

    var job_ctx: ?*c.JSContext = ctx;
    var jobs: c_int = 0;
    while (c.JS_ExecutePendingJob(rt, &job_ctx) > 0) jobs += 1;

    const result = c.JS_GetPropertyStr(ctx, global, "__result");
    defer c.JS_FreeValue(ctx, result);
    const text = c.JS_ToCStringLen(ctx, null, result) orelse return error.ResultMissing;
    defer c.JS_FreeCString(ctx, text);
    const out = std.mem.span(text);
    std.debug.print("require spike: jobs={d}  result = {s}\n", .{ jobs, out });
    if (!std.mem.eql(u8, out, "{\"answer\":42}")) return error.UnexpectedResult;
    std.debug.print("require spike OK: resolution-time precompiled CJS factories + runtime JS_Call\n", .{});
}
