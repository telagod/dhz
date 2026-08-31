//! 子进程桥 smoke（`zig build proc-smoke-run`）：
//! dshServices.proc.run(cmd, args) -> { code, stdout }；断言 echo 回环 + 退出码。零泄漏哨兵。
const std = @import("std");
const hs = @import("host_services.zig");
const proc_bridge = @import("proc_bridge.zig");
const pol_mod = @import("policy.zig");

const c = hs.c;

const GLUE =
    \\globalThis.__r = dshServices.proc.run('echo', ['proc-bridge-ok']).stdout;
    \\globalThis.__code = dshServices.proc.run('false').code;
    \\globalThis.__r2 = dshServices.proc.run('sh', ['-c', 'printf x41']).stdout;
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
    _ = c.JS_SetDumpFlags(rt, c.JS_DUMP_LEAKS | c.JS_DUMP_ATOM_LEAKS);
    defer c.JS_FreeRuntime(rt);
    const ctx = c.JS_NewContext(rt) orelse return error.NewContext;
    defer c.JS_FreeContext(ctx);

    const services = [_]hs.Service{ .{ .name = "proc", .methods = &proc_bridge.serviceMethods } };
    hs.register(ctx, &services);

    const val = c.JS_Eval(ctx, GLUE.ptr, GLUE.len, "glue.js", c.JS_EVAL_TYPE_GLOBAL);
    if (c.JS_IsException(val)) {
        const ex = c.JS_GetException(ctx);
        defer c.JS_FreeValue(ctx, ex);
        const msg = c.JS_ToCStringLen(ctx, null, ex) orelse return error.NoMsg;
        defer c.JS_FreeCString(ctx, msg);
        std.debug.print("proc smoke: eval exception: {s}\n", .{std.mem.span(msg)});
        return error.EvalFailed;
    }
    c.JS_FreeValue(ctx, val);

    const out = try readGlobalStr(ctx, "__r");
    defer std.heap.page_allocator.free(out);
    const out2 = try readGlobalStr(ctx, "__r2");
    defer std.heap.page_allocator.free(out2);
    const code = try readGlobalInt(ctx, "__code");

    std.debug.print("proc smoke: echo='{s}' code={d} sh='{s}'\n", .{ out, code, out2 });
    if (!std.mem.eql(u8, out, "proc-bridge-ok\n")) return error.EchoMismatch;
    if (code != 1) return error.ExitCodeMismatch;
    if (!std.mem.eql(u8, out2, "x41")) return error.ShArgsMismatch;

    // ---- landlock 沙箱：workspace_write（写限 /tmp） ----
    const ws = pol_mod.Policy.init(pol_mod.Mode.workspace_write, "/tmp");
    proc_bridge.setPolicy(&ws);
    const GLUE2 =
        \\globalThis.__deny = dshServices.proc.run('sh', ['-c', 'echo nope > /etc/ll-denied.txt']).code;
        \\globalThis.__ok = dshServices.proc.run('sh', ['-c', 'echo ok > /tmp/ll-ok.txt']).code;
        \\globalThis.__exec = dshServices.proc.run('echo', ['still-works']).stdout;
        \\
    ;
    const v2 = c.JS_Eval(ctx, GLUE2.ptr, GLUE2.len, "glue2.js", c.JS_EVAL_TYPE_GLOBAL);
    if (c.JS_IsException(v2)) return error.EvalFailed;
    c.JS_FreeValue(ctx, v2);
    const deny = try readGlobalInt(ctx, "__deny");
    const ok = try readGlobalInt(ctx, "__ok");
    const still = try readGlobalStr(ctx, "__exec");
    defer std.heap.page_allocator.free(still);
    std.debug.print("proc smoke: landlock ws: denyCode={d} okCode={d} exec='{s}'\n", .{ deny, ok, still });
    if (deny == 0) return error.WsDenyNotEnforced;
    if (ok != 0) return error.WsWriteDenied;
    if (!std.mem.eql(u8, still, "still-works\n")) return error.WsExecBroken;

    // ---- read_only：/tmp 写也拒绝 ----
    const ro = pol_mod.Policy.init(pol_mod.Mode.read_only, "/tmp");
    proc_bridge.setPolicy(&ro);
    const GLUE3 =
        \\globalThis.__roDeny = dshServices.proc.run('sh', ['-c', 'echo x > /tmp/ll-ro.txt']).code;
        \\
    ;
    const v3 = c.JS_Eval(ctx, GLUE3.ptr, GLUE3.len, "glue3.js", c.JS_EVAL_TYPE_GLOBAL);
    if (c.JS_IsException(v3)) return error.EvalFailed;
    c.JS_FreeValue(ctx, v3);
    const ro_deny = try readGlobalInt(ctx, "__roDeny");
    std.debug.print("proc smoke: landlock ro: tmpWriteCode={d}\n", .{ro_deny});
    if (ro_deny == 0) return error.RoWriteNotDenied;

    proc_bridge.clearPolicy();
    std.debug.print("proc smoke OK: guest -> proc.run -> fork/exec -> stdout + code: PASS\n", .{});
    std.process.exit(0);
}
