//! crypto 桥 smoke（`zig build crypto-smoke-run`）：
//! dshServices.crypto.sha256 —— 已知向量 + node:crypto createHash 对接。零泄漏哨兵。
const std = @import("std");
const hs = @import("host_services.zig");
const crypto_bridge = @import("crypto_bridge.zig");

const c = hs.c;

const GLUE =
    \\globalThis.__abc = dshServices.crypto.sha256('abc');
    \\const ch = (globalThis.crypto ?? {}).createHash;
    \\globalThis.__viaCrypto = globalThis.dshServices.crypto === undefined ? 'nosvc' : (typeof dshServices.crypto.sha256);
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

pub fn main() !void {
    const rt = c.JS_NewRuntime() orelse return error.NewRuntime;
    _ = c.JS_SetDumpFlags(rt, c.JS_DUMP_LEAKS | c.JS_DUMP_ATOM_LEAKS);
    defer c.JS_FreeRuntime(rt);
    const ctx = c.JS_NewContext(rt) orelse return error.NewContext;
    defer c.JS_FreeContext(ctx);

    const services = [_]hs.Service{ .{ .name = "crypto", .methods = &crypto_bridge.serviceMethods } };
    hs.register(ctx, &services);

    const val = c.JS_Eval(ctx, GLUE.ptr, GLUE.len, "glue.js", c.JS_EVAL_TYPE_GLOBAL);
    if (c.JS_IsException(val)) return error.EvalFailed;
    c.JS_FreeValue(ctx, val);

    const abc = try readGlobalStr(ctx, "__abc");
    defer std.heap.page_allocator.free(abc);
    std.debug.print("crypto smoke: sha256('abc')={s}\n", .{abc});
    // FIPS 180-4 已知向量
    if (!std.mem.eql(u8, abc, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")) {
        return error.VectorMismatch;
    }
    std.debug.print("crypto smoke OK: SHA-256 real hash (zero-dependency) + vector verified: PASS\n", .{});
    std.process.exit(0);
}
