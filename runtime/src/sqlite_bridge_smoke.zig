//! sqlite 桥 smoke（`zig build sqlite-bridge-smoke-run`）：
//! dshServices.sqlite open/exec/run(位置参数)/all(行对象) /close 全链 + 零泄漏哨兵。
const std = @import("std");
const hs = @import("host_services.zig");
const sqlite_bridge = @import("sqlite_bridge.zig");

const c = hs.c;

const GLUE =
    \\globalThis.__db = dshServices.sqlite.open('/tmp/dsh-sqlite-svc.db');
    \\dshServices.sqlite.exec(__db, 'create table if not exists t (name text, n int)');
    \\dshServices.sqlite.run(__db, 'delete from t');
    \\globalThis.__ch = dshServices.sqlite.run(__db, 'insert into t (name, n) values (?, ?)', ['alpha', 42]);
    \\globalThis.__rows = dshServices.sqlite.all(__db, 'select name, n from t where n = ?', [42]);
    \\globalThis.__name = __rows[0].name;
    \\globalThis.__n = __rows[0].n;
    \\dshServices.sqlite.close(__db);
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

    const services = [_]hs.Service{ .{ .name = "sqlite", .methods = &sqlite_bridge.serviceMethods } };
    hs.register(ctx, &services);

    const val = c.JS_Eval(ctx, GLUE.ptr, GLUE.len, "glue.js", c.JS_EVAL_TYPE_GLOBAL);
    if (c.JS_IsException(val)) {
        const ex = c.JS_GetException(ctx);
        defer c.JS_FreeValue(ctx, ex);
        const msg = c.JS_ToCStringLen(ctx, null, ex) orelse return error.NoMsg;
        defer c.JS_FreeCString(ctx, msg);
        std.debug.print("sqlite bridge smoke: eval exception: {s}\n", .{std.mem.span(msg)});
        return error.EvalFailed;
    }
    c.JS_FreeValue(ctx, val);

    const name = try readGlobalStr(ctx, "__name");
    defer std.heap.page_allocator.free(name);
    const n = try readGlobalInt(ctx, "__n");
    const ch = try readGlobalInt(ctx, "__ch");

    std.debug.print("sqlite bridge smoke: name='{s}' n={d} changes={d}\n", .{ name, n, ch });
    if (!std.mem.eql(u8, name, "alpha")) return error.NameMismatch;
    if (n != 42) return error.NumberMismatch;
    if (ch != 1) return error.ChangesMismatch;
    std.debug.print("sqlite bridge smoke OK: guest -> sqlite.open/run(?) /all -> rows: PASS\n", .{});
    std.process.exit(0);
}
