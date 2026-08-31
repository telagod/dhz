//! M-2 模块链接器 spike：ESM 图 + 内置表 + 内嵌模块表。
//! 验证：JS_SetModuleLoaderFunc2 回调、JS_Eval(COMPILE_ONLY)→EvalFunction→pending job 循环、
//!       'node:' builtin 与 './' 相对模块两条解析路径。
//! 内嵌模块表即最终架构形态（@embedFile 打包 app JS —— 零运行时文件 IO）。
//! 运行: `zig build esm-spike-run`

const std = @import("std");

const c = @cImport({
    @cInclude("quickjs.h");
});

const builtin_fs = "export const tag = 'fs-shim';";
const main_mjs =
    \\import { tag } from 'node:fs'
    \\import { n } from './dep.mjs'
    \\
    \\globalThis.__result = tag + ':' + n
    \\
;
const dep_mjs =
    \\export const n = 6 * 7
    \\
;

/// In-memory module table: specifier -> source. Stand-in for the future
/// embedded app bundle; the resolver chain (npm walk, exports conditions)
/// replaces the `./` arm in M-2's real linker.
/// NOTE: the DEFAULT module normalizer resolves relative specifiers against
/// the importing module's name before calling us ("./dep.mjs" -> "dep.mjs").
/// The real linker implements JS_SetModuleNormalizeFunc2 to own that step.
fn moduleSource(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "node:fs")) return builtin_fs;
    if (std.mem.eql(u8, name, "./dep.mjs") or std.mem.eql(u8, name, "dep.mjs")) return dep_mjs;
    return null;
}

/// Module loader callback: builtin/embedded table lookup, then compile-only
/// eval; returns the module def (runtime-owned, host never caches it).
fn moduleLoader(
    ctx: ?*c.JSContext,
    module_name: [*c]const u8,
    userdata: ?*anyopaque,
    attributes: c.JSValueConst,
) callconv(.c) ?*c.JSModuleDef {
    _ = userdata;
    _ = attributes;
    const name = std.mem.span(module_name);
    const src = moduleSource(name) orelse {
        std.debug.print("[loader] unknown module: {s}\n", .{name});
        return null;
    };
    const val = c.JS_Eval(ctx, src.ptr, src.len, name.ptr, c.JS_EVAL_TYPE_MODULE | c.JS_EVAL_FLAG_COMPILE_ONLY);
    if (c.JS_IsException(val)) {
        std.debug.print("[loader] compile failed: {s}\n", .{name});
        return null;
    }
    // Module def is referenced by the runtime; free the JSValue wrapper only.
    const m: *c.JSModuleDef = @ptrCast(val.u.ptr);
    c.JS_FreeValue(ctx, val);
    return m;
}

pub fn main() !void {
    const rt = c.JS_NewRuntime() orelse return error.NewRuntime;
    defer c.JS_FreeRuntime(rt);
    const ctx = c.JS_NewContext(rt) orelse return error.NewContext;
    defer c.JS_FreeContext(ctx);

    c.JS_SetModuleLoaderFunc2(rt, null, moduleLoader, null, null);

    var val = c.JS_Eval(ctx, main_mjs.ptr, main_mjs.len, "main.mjs", c.JS_EVAL_TYPE_MODULE | c.JS_EVAL_FLAG_COMPILE_ONLY);
    if (c.JS_IsException(val)) return error.MainCompile;
    val = c.JS_EvalFunction(ctx, val);
    defer c.JS_FreeValue(ctx, val);
    if (c.JS_IsException(val)) return error.MainRun;

    // Static imports resolve during EvalFunction; the job loop also serves
    // dynamic import and promise microtasks.
    var job_ctx: ?*c.JSContext = ctx;
    var jobs: c_int = 0;
    while (c.JS_ExecutePendingJob(rt, &job_ctx) > 0) jobs += 1;

    const global = c.JS_GetGlobalObject(ctx);
    defer c.JS_FreeValue(ctx, global);
    const result = c.JS_GetPropertyStr(ctx, global, "__result");
    defer c.JS_FreeValue(ctx, result);
    if (c.JS_IsException(result)) return error.ResultMissing;
    const text = c.JS_ToCStringLen(ctx, null, result) orelse return error.ResultMissing;
    defer c.JS_FreeCString(ctx, text);
    const out = std.mem.span(text);

    std.debug.print("esm spike: jobs={d}  main result = \"{s}\"\n", .{ jobs, out });
    if (!std.mem.eql(u8, out, "fs-shim:42")) return error.UnexpectedResult;
    std.debug.print("esm spike OK: builtin + relative module + ESM graph\n", .{});
}
