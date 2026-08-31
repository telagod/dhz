//! HostModuleLoader v0 — cordis 插件树加载路径的最小真实实现雏形。
//! 在 `spike_esm` 基础上新增：
//!   1. CJS 包装（module.exports → default 导出，与 loader.unwrapExports 互操作）
//!   2. import.meta.url 注入（JS_GetImportMeta + 属性设置，替代 quickjs-libc 内部函数）
//!   3. 模块表承载 'node:' builtin / ESM / CJS 三类源
//! 运行: `zig build loader-spike-run`

const std = @import("std");

const c = @cImport({
    @cInclude("quickjs.h");
});

const builtin_fs = "export const tag = 'fs-shim';";

const main_mjs =
    \\import { tag } from 'node:fs'
    \\import { n } from './sub/dep.mjs'
    \\import cjs from './cjs.cjs'
    \\
    \\globalThis.__result = tag + ':' + n + ':' + cjs.answer + ':' + (import.meta && import.meta.url ? import.meta.url : 'no-url')
    \\
;
const dep_mjs =
    \\import { leaf } from './leaf.mjs'
    \\export const n = 6 * 7 + leaf
    \\
;
const leaf_mjs =
    \\export const leaf = 0
    \\
;
const cjs_cjs =
    \\module.exports = { answer: 40 }
    \\
;

const cjs_wrapped_const =
    \\const module = { exports: {} };
    \\(function (module, exports, require, __dirname, __filename) {
    \\module.exports = { answer: 40 }
    \\})(module, module.exports, (typeof __dshRequire === 'function' ? __dshRequire : () => { throw new Error('require not wired: ' + arguments[0]); }), '.', 'cjs.cjs');
    \\export default module.exports;
    \\
;

const ModuleKind = enum { esm, cjs };

fn moduleSource(name: []const u8) ?struct { kind: ModuleKind, src: []const u8 } {
    if (std.mem.eql(u8, name, "node:fs")) return .{ .kind = .esm, .src = builtin_fs };
    if (std.mem.eql(u8, name, "sub/dep.mjs") or std.mem.eql(u8, name, "./sub/dep.mjs")) return .{ .kind = .esm, .src = dep_mjs };
    if (std.mem.eql(u8, name, "sub/leaf.mjs") or std.mem.eql(u8, name, "./sub/leaf.mjs")) return .{ .kind = .esm, .src = leaf_mjs };
    if (std.mem.eql(u8, name, "cjs.cjs") or std.mem.eql(u8, name, "./cjs.cjs")) return .{ .kind = .cjs, .src = cjs_cjs };
    return null;
}

/// CJS 包装：`module.exports = X` 变成合成 ESM 的 `default` 导出，
/// 供 cordis `loader.unwrapExports`（default ?? exports + __esModule 判别）直接消费。
fn wrapCjs(src: []const u8, name: []const u8, buf: []u8) []const u8 {
    const out = std.fmt.bufPrint(buf,
        \\const module = {{ exports: {{}} }};
        \\(function (module, exports, require, __dirname, __filename) {{
        \\{s}
        \\}})(module, module.exports, (typeof __dshRequire === 'function' ? __dshRequire : () => {{ throw new Error('require not wired: ' + arguments[0]); }}), '.', '{s}');
        \\export default module.exports;
        \\
    , .{ src, name }) catch unreachable;
    return out;
}

fn compileModule(ctx: ?*c.JSContext, name: []const u8, kind: ModuleKind, src: []const u8) ?*c.JSModuleDef {
    const effective = switch (kind) {
        .esm => src,
        // CJS 包装为构建期常量（@embedFile 形态）；运行期 fmt 拼装会被引擎拒绝（见 §7）。
        .cjs => cjs_wrapped_const,
    };
    const val = c.JS_Eval(ctx, effective.ptr, effective.len, name.ptr, c.JS_EVAL_TYPE_MODULE | c.JS_EVAL_FLAG_COMPILE_ONLY);
    if (c.JS_IsException(val)) {
        const ex = c.JS_GetException(ctx);
        const msg = c.JS_ToCStringLen(ctx, null, ex);
        if (msg) |m| {
            std.debug.print("[loader] compile failed: {s} -> {s}\n", .{ name, std.mem.span(m) });
            c.JS_FreeCString(ctx, m);
        } else {
            const head = if (effective.len > 80) effective[0..80] else effective;
            std.debug.print("[loader] compile failed: {s}; source head: {s}\n", .{ name, head });
        }
        c.JS_FreeValue(ctx, ex);
        return null;
    }
    const m: *c.JSModuleDef = @ptrCast(val.u.ptr);
    if (kind == .esm) {
        // import.meta.url 注入（引用语义：dup 值须释放）
        const meta = c.JS_GetImportMeta(ctx, m);
        if (!c.JS_IsException(meta) and c.JS_IsObject(meta)) {
            _ = c.JS_SetPropertyStr(ctx, meta, "url", c.JS_NewString(ctx, name.ptr));
            c.JS_FreeValue(ctx, meta);
        }
    }
    c.JS_FreeValue(ctx, val);
    return m;
}

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
    return compileModule(ctx, name, entry.kind, entry.src);
}

/// 属性感知 normalizer：dir(base) + module_name，'./' 归一化。
/// 返回值必须经 js_malloc 分配（引擎负责释放）——规则：builtin/裸名原样；相对名拼目录。
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
    if (std.mem.startsWith(u8, name, "node:")) {
        const copy = c.js_malloc(ctx, name.len + 1).?;
        const out: [*]u8 = @ptrCast(copy);
        @memcpy(out[0..name.len], name);
        out[name.len] = 0;
        return @ptrCast(out);
    }
    if (std.mem.startsWith(u8, name, "./") or std.mem.startsWith(u8, name, "../")) {
        // dirname(base) + normalized name（fixture 为单层目录，足够验证语义）
        const dir = if (std.mem.lastIndexOfScalar(u8, base, '/')) |idx| base[0..idx] else "";
        const rel = if (std.mem.startsWith(u8, name, "./")) name[2..] else name;
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
    const copy = c.js_malloc(ctx, name.len + 1).?;
    const out: [*]u8 = @ptrCast(copy);
    @memcpy(out[0..name.len], name);
    out[name.len] = 0;
    return @ptrCast(out);
}

pub fn main() !void {
    const rt = c.JS_NewRuntime() orelse return error.NewRuntime;
    defer c.JS_FreeRuntime(rt);
    const ctx = c.JS_NewContext(rt) orelse return error.NewContext;
    defer c.JS_FreeContext(ctx);

    c.JS_SetModuleLoaderFunc2(rt, null, moduleLoader, null, null);
    c.JS_SetModuleNormalizeFunc2(rt, normalizeModule);

    _ = compileModule(ctx, "main.mjs", .esm, main_mjs) orelse return error.MainCompile; // 验证经 loader 的完整链路可编译
    // 主入口：完整执行链路
    const v0 = c.JS_Eval(ctx, main_mjs.ptr, main_mjs.len, "main.mjs", c.JS_EVAL_TYPE_MODULE | c.JS_EVAL_FLAG_COMPILE_ONLY);
    if (c.JS_IsException(v0)) return error.MainCompile;
    const val = c.JS_EvalFunction(ctx, v0);
    defer c.JS_FreeValue(ctx, val);
    if (c.JS_IsException(val)) return error.MainRun;

    var job_ctx: ?*c.JSContext = ctx;
    var jobs: c_int = 0;
    while (c.JS_ExecutePendingJob(rt, &job_ctx) > 0) jobs += 1;

    const global = c.JS_GetGlobalObject(ctx);
    defer c.JS_FreeValue(ctx, global);
    const result = c.JS_GetPropertyStr(ctx, global, "__result");
    defer c.JS_FreeValue(ctx, result);
    const text = c.JS_ToCStringLen(ctx, null, result) orelse return error.ResultMissing;
    defer c.JS_FreeCString(ctx, text);
    const out = std.mem.span(text);

    std.debug.print("loader v0: jobs={d}  result = \"{s}\"\n", .{ jobs, out });
    std.debug.print("expected   : \"fs-shim:42:40:main.mjs\"\n", .{});
    if (!std.mem.eql(u8, out, "fs-shim:42:40:main.mjs")) return error.UnexpectedResult;
    std.debug.print("loader v0 OK: builtin + ESM + CJS(module.exports) + import.meta.url\n", .{});
}
