//! cordis timer 插件级 smoke（`zig build cordis-timer-smoke-run`）：
//! 真实 cordis + cordis-plugin-timer 在 quickjs 中运行，ctx.timeout/ctx.interval
//! 经宿主事件循环全链驱动（timerfd → epoll → JS_Call → guest 闭包 → 插件 fiber dispose）。
//! 这是"插件 → context → 宿主 timer"的端到端验证（此前留档的 tag=-1 谜题场景重建）。
const std = @import("std");
const app = @import("app_modules.zig");
const loop_mod = @import("event_loop.zig");

const c = loop_mod.c;

// ---------------------------------------------------------------------------
// builtin 桩（与 spike_cordis 相同的闭包面）
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
        if (msg) |m| std.debug.print("[loader] compile failed: {s} -> {s}\n", .{ canonical, std.mem.span(m) });
        if (msg) |m| c.JS_FreeCString(ctx, m);
        c.JS_FreeValue(ctx, ex);
        return null;
    }
    const m: *c.JSModuleDef = @ptrCast(val.u.ptr);
    const meta = c.JS_GetImportMeta(ctx, m);
    if (!c.JS_IsException(meta) and c.JS_IsObject(meta)) {
        _ = c.JS_SetPropertyStr(ctx, meta, "url", c.JS_NewString(ctx, canonical.ptr));
        c.JS_FreeValue(ctx, meta);
    }
    c.JS_FreeValue(ctx, val);
    return m;
}

const check = @embedFile("cordis-timer-check.mjs");

fn readGlobalInt(ctx: ?*c.JSContext, name: [*c]const u8) i32 {
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
    // 零泄漏哨兵：若有 C 侧值残留，JS_FreeRuntime 会打印 "Object leaks:" 且断言；
    // 每次回归自动执行 §6.2 规则 7 的检查（此前 attachEngine ref 结算 bug 由此暴露）。
    _ = c.JS_SetDumpFlags(rt, c.JS_DUMP_LEAKS | c.JS_DUMP_ATOM_LEAKS);
    defer c.JS_FreeRuntime(rt);
    const ctx = c.JS_NewContext(rt) orelse return error.NewContext;
    defer c.JS_FreeContext(ctx);

    var loop = try loop_mod.Loop.init();
    defer loop.deinit();
    _ = c.JS_SetContextOpaque(ctx, @ptrCast(&loop));
    loop.attachEngine(@as(?*c.JSRuntime, rt), ctx);

    c.JS_SetModuleLoaderFunc2(rt, null, moduleLoader, null, null);
    c.JS_SetModuleNormalizeFunc2(rt, normalizeModule);

    var val = c.JS_Eval(ctx, check.ptr, check.len, "cordis-timer-check.mjs", c.JS_EVAL_TYPE_MODULE | c.JS_EVAL_FLAG_COMPILE_ONLY);
    if (c.JS_IsException(val)) {
        const ex = c.JS_GetException(ctx);
        defer c.JS_FreeValue(ctx, ex);
        const msg = c.JS_ToCStringLen(ctx, null, ex);
        if (msg) |m| {
            std.debug.print("[smoke] compile exception: {s}\n", .{std.mem.span(m)});
            c.JS_FreeCString(ctx, m);
        }
        return error.CheckCompile;
    }
    val = c.JS_EvalFunction(ctx, val);
    defer c.JS_FreeValue(ctx, val);
    if (c.JS_IsException(val)) {
        const ex = c.JS_GetException(ctx);
        defer c.JS_FreeValue(ctx, ex);
        const msg = c.JS_ToCStringLen(ctx, null, ex);
        if (msg) |m| {
            std.debug.print("[smoke] run exception: {s}\n", .{std.mem.span(m)});
            c.JS_FreeCString(ctx, m);
        }
        return error.CheckRun;
    }

    var job_ctx: ?*c.JSContext = ctx;
    var jobs: c_int = 0;
    while (c.JS_ExecutePendingJob(rt, &job_ctx) > 0) : (jobs += 1) {
        if (jobs > 4096) {
            std.debug.print("[smoke] job runaway at {d}\n", .{jobs});
            return error.JobRunaway;
        }
    }
    const armed = readGlobalInt(ctx, "__armed") == 1;
    if (!armed) {
        const global = c.JS_GetGlobalObject(ctx);
        defer c.JS_FreeValue(ctx, global);
        const err_v = c.JS_GetPropertyStr(ctx, global, "__err");
        defer c.JS_FreeValue(ctx, err_v);
        if (!c.JS_IsUndefined(err_v)) {
            const msg = c.JS_ToCStringLen(ctx, null, err_v) orelse return error.NoMsg;
            defer c.JS_FreeCString(ctx, msg);
            std.debug.print("[smoke] guest err: {s}\n", .{std.mem.span(msg)});
        }
        const step_v = c.JS_GetPropertyStr(ctx, global, "__step");
        defer c.JS_FreeValue(ctx, step_v);
        const len = c.JS_GetPropertyStr(ctx, step_v, "length");
        defer c.JS_FreeValue(ctx, len);
        var n: c_int = 0;
        _ = c.JS_ToInt32(ctx, &n, len);
        std.debug.print("[smoke] not armed (jobs={d}, steps={d}):\n", .{ jobs, n });
        var i: c_int = 0;
        while (i < n) : (i += 1) {
            const s = c.JS_GetPropertyUint32(ctx, step_v, @intCast(i));
            defer c.JS_FreeValue(ctx, s);
            const t = c.JS_ToCStringLen(ctx, null, s) orelse continue;
            defer c.JS_FreeCString(ctx, t);
            std.debug.print("[smoke]   step[{d}] = {s}\n", .{ i, std.mem.span(t) });
        }
        return error.NotArmed;
    }

    // 驱动宿主事件循环（timeout 40ms + interval 25ms × ~8 次）
    loop.run(220);
    loop.drainJobs();

    const hits = readGlobalInt(ctx, "__timerHits");
    const ints = readGlobalInt(ctx, "__intHits");
    std.debug.print("cordis timer smoke: armed={} __timerHits={d} __intHits={d}\n", .{ armed, hits, ints });
    if (hits != 1) return error.TimeoutNotFiredOnce;
    if (ints < 3) return error.IntervalNotRepeated;
    std.debug.print("cordis timer smoke OK: plugin -> ctx.timeout/ctx.interval -> host event loop -> guest: PASS\n", .{});
}
