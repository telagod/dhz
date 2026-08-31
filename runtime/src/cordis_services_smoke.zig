//! cordis 服务注入面 smoke（`zig build cordis-services-smoke-run`）：
//! dshServices（宿主服务对象树）→ cordis provide('fs'/'timer') → 插件
//! inject:['fs','timer'] → apply 中 c.fs.* / c.timer.* 直通宿主。
//! =「宿主服务 ↔ cordis 服务」第一条契约验证线。零泄漏哨兵。
const std = @import("std");
const app = @import("app_modules.zig");
const loop_mod = @import("event_loop.zig");
const bridge = @import("fs_bridge.zig");
const http_bridge = @import("http_bridge.zig");
const proc_bridge = @import("proc_bridge.zig");
const sqlite_bridge = @import("sqlite_bridge.zig");
const hs = @import("host_services.zig");

const c = loop_mod.c;

// builtin 面由闭包依赖扫描自动生成（tools/gen-app-esm.py -> builtin_stubs.zig）
const bs = @import("builtin_stubs.zig");

fn resolveSpec(name: []const u8) ?[]const u8 {
    for (app.modules) |m| {
        if (std.mem.eql(u8, m.name, name)) return m.name;
    }
    return null;
}

fn moduleSource(name: []const u8) ?[]const u8 {
    for (bs.builtins) |b| {
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
    if (!std.mem.startsWith(u8, canonical, "node:") and
        !std.mem.endsWith(u8, canonical, "index.js") and
        !std.mem.endsWith(u8, canonical, "index.mjs"))
    {
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
    const m: *c.JSModuleDef = @ptrCast(val.u.ptr);
    const meta = c.JS_GetImportMeta(ctx, m);
    if (!c.JS_IsException(meta) and c.JS_IsObject(meta)) {
        _ = c.JS_SetPropertyStr(ctx, meta, "url", c.JS_NewString(ctx, canonical.ptr));
        c.JS_FreeValue(ctx, meta);
    }
    c.JS_FreeValue(ctx, val);
    return m;
}

const check = @embedFile("cordis-svc-check.mjs");

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
    _ = c.JS_SetDumpFlags(rt, c.JS_DUMP_LEAKS | c.JS_DUMP_ATOM_LEAKS);
    defer c.JS_FreeRuntime(rt);
    const ctx = c.JS_NewContext(rt) orelse return error.NewContext;
    defer c.JS_FreeContext(ctx);

    var loop = try loop_mod.Loop.init();
    defer loop.deinit();
    _ = c.JS_SetContextOpaque(ctx, @ptrCast(&loop));
    loop.attachEngine(@as(?*c.JSRuntime, rt), ctx);

    hs.installProcessShim(ctx, &.{});
    const services = [_]hs.Service{
        .{ .name = "fs", .methods = &bridge.serviceMethods },
        .{ .name = "timer", .methods = &loop_mod.serviceMethods },
        .{ .name = "http", .methods = &http_bridge.serviceMethods },
        .{ .name = "proc", .methods = &proc_bridge.serviceMethods },
        .{ .name = "sqlite", .methods = &sqlite_bridge.serviceMethods },
    };
    hs.register(ctx, &services);

    c.JS_SetModuleLoaderFunc2(rt, null, moduleLoader, null, null);
    c.JS_SetModuleNormalizeFunc2(rt, normalizeModule);

    var val = c.JS_Eval(ctx, check.ptr, check.len, "cordis-svc-check.mjs", c.JS_EVAL_TYPE_MODULE | c.JS_EVAL_FLAG_COMPILE_ONLY);
    if (c.JS_IsException(val)) return error.CheckCompile;
    val = c.JS_EvalFunction(ctx, val);
    defer c.JS_FreeValue(ctx, val);
    if (c.JS_IsException(val)) return error.CheckRun;

    var job_ctx: ?*c.JSContext = ctx;
    var jobs: c_int = 0;
    while (c.JS_ExecutePendingJob(rt, &job_ctx) > 0) : (jobs += 1) {
        if (jobs > 4096) return error.JobRunaway;
    }
    const armed = try readGlobalInt(ctx, "__armed");
    if (armed != 1) {
        const err = try readGlobalStr(ctx, "__err");
        defer std.heap.page_allocator.free(err);
        std.debug.print("[smoke] not armed: {s}\n", .{err});
        return error.NotArmed;
    }

    loop.run(160);
    loop.drainJobs();

    const svc_proc = try readGlobalStr(ctx, "__svcProc");
    defer std.heap.page_allocator.free(svc_proc);
    const agent_type = try readGlobalStr(ctx, "__agentType");
    defer std.heap.page_allocator.free(agent_type);
    const dsh_fs_inst = try readGlobalInt(ctx, "__dshFsInst");
    const node_fs = try readGlobalStr(ctx, "__nodeFs");
    defer std.heap.page_allocator.free(node_fs);
    const svc_sqlite = try readGlobalStr(ctx, "__repRow");
    defer std.heap.page_allocator.free(svc_sqlite);
    const report_read = try readGlobalStr(ctx, "__reportRead");
    defer std.heap.page_allocator.free(report_read);
    const proc_code = try readGlobalInt(ctx, "__procCode");
    const svc_read = try readGlobalStr(ctx, "__svcRead");
    defer std.heap.page_allocator.free(svc_read);
    const svc_http = try readGlobalStr(ctx, "__svcHttp");
    defer std.heap.page_allocator.free(svc_http);
    const tick = try readGlobalInt(ctx, "__svcTick");
    std.debug.print("cordis services smoke: agentType='{s}' dsh-fs-plugin={} nodefs='{s}' readback='{s}' proc.echo='{s}' sqlite.v='{s}' report='{s}' procCode={d} http.echo='{s}' timer.tick={d}\n", .{ agent_type, dsh_fs_inst == 1, node_fs, svc_read, svc_proc, svc_sqlite, report_read, proc_code, svc_http, tick });
    if (dsh_fs_inst != 1) return error.DshFsPluginNotInstalled;
    if (std.mem.eql(u8, agent_type, "undefined")) return error.AgentServiceNotInjected;
    if (!std.mem.eql(u8, node_fs, "node-fs-ok")) return error.NodeFsRealIoMismatch;
    if (!std.mem.eql(u8, svc_read, "via-cordis")) return error.ReadbackMismatch;
    if (!std.mem.eql(u8, svc_proc, "via-cordis\n")) return error.ProcViaCordisMismatch;
    if (!std.mem.eql(u8, svc_sqlite, "cordis")) return error.SqliteViaCordisMismatch;
    if (!std.mem.eql(u8, report_read, "report:{ts:1}")) return error.ReportPersistMismatch;
    if (proc_code != 7) return error.ProcCodeMismatch;
    if (!std.mem.eql(u8, svc_http, "cordis-http:/echo")) return error.HttpViaCordisMismatch;
    if (tick != 3) return error.TimerTickMissing;
    std.debug.print("cordis services smoke OK: provide/inject -> c.fs + c.timer -> host: PASS\n", .{});
}
