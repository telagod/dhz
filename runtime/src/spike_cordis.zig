//! cordis 真实插件互操作 spike：真实 bundled 插件闭包经 Zig 模块链接器加载。
//! 闭包：dsh-anonymous-user-id → dsh-home-paths / cordis → cosmokit / builtin 桩。
//! 端到端验证：规格化（裸包名）→ 嵌入表查找 → ESM 编译链接 → 动态 import →
//!             命名导出形态（Context/hyphenate/getOrCreateAnonymousUserId 均为 function）。
//! 运行: `zig build cordis-spike-run`

const std = @import("std");
const app = @import("app_modules.zig");

const c = @import("event_loop.zig").c;

// ---------------------------------------------------------------------------
// builtin 桩：真实绑定在 M-3 fs/crypto/os 服务；此处仅满足 import 链接形状。
// ---------------------------------------------------------------------------
const stub_crypto = "export function randomUUID() { return '00000000-0000-4000-8000-000000000000'; }";
const stub_fs = "export function mkdirSync() {} export function readFileSync() { return null; } export function writeFileSync() {}";
const stub_fs_promises = "export async function opendir() {} export async function realpath() { return ''; }";
const stub_os = "export function homedir() { return '.'; }";
const stub_path = "export function dirname(p) { const i = p.lastIndexOf('/'); return i < 0 ? '.' : (i === 0 ? '/' : p.slice(0, i)); } export function join() { return Array.from(arguments).filter(Boolean).join('/'); } export function resolve(p) { return p; } export function basename(p) { const i = p.lastIndexOf('/'); return i < 0 ? p : p.slice(i + 1); }";

const builtins = [_]struct { name: []const u8, src: []const u8 }{
    .{ .name = "node:crypto", .src = stub_crypto },
    .{ .name = "node:fs", .src = stub_fs },
    .{ .name = "node:fs/promises", .src = stub_fs_promises },
    .{ .name = "node:os", .src = stub_os },
    .{ .name = "node:path", .src = stub_path },
};

fn resolveSpec(name: []const u8) ?[]const u8 {
    // 解析：裸包名 -> canonical file path（app_modules 表键）。
    // 后续 M-2 真实解析器在此插入 node_modules/exports 条件逻辑。
    for (app.modules) |m| {
        if (std.mem.eql(u8, m.name, name)) return m.name;
    }
    return null;
}

fn moduleSource(name: []const u8) ?[]const u8 {
    for (builtins) |b| {
        if (std.mem.eql(u8, b.name, name)) return b.src;
    }
    for (app.modules) |m| {
        if (std.mem.eql(u8, m.name, name)) return m.src;
    }
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

    // 规格化规则（与真实语义一致）：
    //   - 裸名/builtin 原样返回（不拼目录！）
    //   - 相对名 dir(base) + name（'./' 剥离）
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

fn moduleLoader(
    ctx: ?*c.JSContext,
    module_name: [*c]const u8,
    userdata: ?*anyopaque,
    attributes: c.JSValueConst,
) callconv(.c) ?*c.JSModuleDef {
    _ = userdata;
    _ = attributes;
    const name = std.mem.span(module_name);
    // 解析链：表直查 -> 包 main 约定（<pkg>/index.js）——真实解析器的 package.json main 第一步。
    var cand_buf: [256]u8 = undefined;
    const cand = if (std.mem.endsWith(u8, name, "/index.js"))
        name
    else
        std.fmt.bufPrint(&cand_buf, "{s}/index.js", .{name}) catch name;
    var cand2_buf: [256]u8 = undefined;
    const cand2 = std.fmt.bufPrint(&cand2_buf, "{s}/lib/index.js", .{name}) catch cand;
    var cand3_buf: [256]u8 = undefined;
    const cand3 = std.fmt.bufPrint(&cand3_buf, "{s}/lib/index.mjs", .{name}) catch cand;
    const canonical = if (std.mem.startsWith(u8, name, "node:"))
        name
    else
        resolveSpec(name) orelse resolveSpec(cand) orelse resolveSpec(cand2) orelse resolveSpec(cand3) orelse name;
    if (!std.mem.startsWith(u8, canonical, "node:") and !std.mem.endsWith(u8, canonical, "index.js")) {
        std.debug.print("[loader] unresolved: {s}\n", .{name});
        return null;
    }
    const src = moduleSource(canonical) orelse {
        std.debug.print("[loader] unknown source: {s}\n", .{canonical});
        return null;
    };
    const val = c.JS_Eval(ctx, src.ptr, src.len, canonical.ptr, c.JS_EVAL_TYPE_MODULE | c.JS_EVAL_FLAG_COMPILE_ONLY);
    if (c.JS_IsException(val)) {
        const ex = c.JS_GetException(ctx);
        const msg = c.JS_ToCStringLen(ctx, null, ex);
        if (msg) |m| {
            std.debug.print("[loader] compile failed: {s} -> {s}\n", .{ canonical, std.mem.span(m) });
            c.JS_FreeCString(ctx, m);
        }
        c.JS_FreeValue(ctx, ex);
        return null;
    }
    // import.meta.url 注入
    const m: *c.JSModuleDef = @ptrCast(val.u.ptr);
    const meta = c.JS_GetImportMeta(ctx, m);
    if (!c.JS_IsException(meta) and c.JS_IsObject(meta)) {
        _ = c.JS_SetPropertyStr(ctx, meta, "url", c.JS_NewString(ctx, canonical.ptr));
        c.JS_FreeValue(ctx, meta);
    }
    c.JS_FreeValue(ctx, val);
    return m;
}

const check = @embedFile("cordis-check.mjs");

pub fn main() !void {
    const rt = c.JS_NewRuntime() orelse return error.NewRuntime;
    defer c.JS_FreeRuntime(rt);
    const ctx = c.JS_NewContext(rt) orelse return error.NewContext;
    defer c.JS_FreeContext(ctx);

    c.JS_SetModuleLoaderFunc2(rt, null, moduleLoader, null, null);
    c.JS_SetModuleNormalizeFunc2(rt, normalizeModule);

    var val = c.JS_Eval(ctx, check.ptr, check.len, "cordis-check.mjs", c.JS_EVAL_TYPE_MODULE | c.JS_EVAL_FLAG_COMPILE_ONLY);
    if (c.JS_IsException(val)) return error.CheckCompile;
    val = c.JS_EvalFunction(ctx, val);
    defer c.JS_FreeValue(ctx, val);
    if (c.JS_IsException(val)) return error.CheckRun;

    var job_ctx: ?*c.JSContext = ctx;
    var jobs: c_int = 0;
    while (c.JS_ExecutePendingJob(rt, &job_ctx) > 0) jobs += 1;

    job_ctx = ctx;
    jobs = 0;
    while (c.JS_ExecutePendingJob(rt, &job_ctx) > 0) jobs += 1;

    const global = c.JS_GetGlobalObject(ctx);
    defer c.JS_FreeValue(ctx, global);
    const result = c.JS_GetPropertyStr(ctx, global, "__cordisShape");
    defer c.JS_FreeValue(ctx, result);
    const text = c.JS_ToCStringLen(ctx, null, result) orelse return error.ResultMissing;
    defer c.JS_FreeCString(ctx, text);
    const out = std.mem.span(text);

    std.debug.print("cordis spike: jobs={d}  shape = {s}\n", .{ jobs, out });
    const expected = "cordis=function cosmokit=function anonymous=function | ctx-run: plugin=true provided=42 event=true";
    if (!std.mem.eql(u8, out, expected)) return error.UnexpectedShape;
    std.debug.print("cordis spike OK: real cordis machinery executed in quickjs\n", .{});
}
