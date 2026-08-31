//! fs 桥 smoke（`zig build fs-bridge-smoke-run`）：
//! guest JS -> dshFs* C 函数 -> Zig fs 服务 -> 返回 guest，全链验证。
//! 覆盖 sandbox 策略（M-4 §4.8）：
//!   Phase 1  无策略：写返回 true、读回原文、size 正确、缺失文件抛异常
//!   Phase 2  read_only：写被拒（guest catch 验证）、workspace 内读仍可
//!   Phase 3  workspace_write：工作区内写成功、根外写被拒
const std = @import("std");
const bridge = @import("fs_bridge.zig");
const pol_mod = @import("policy.zig");

const c = bridge.c;

const GLUE_P1 =
    \\globalThis.__w = dshFsWriteText('/tmp/dsh-fs-bridge.txt', 'bridge-ok-42');
    \\if (globalThis.__w !== true) { throw new Error('write must return true'); }
    \\globalThis.__rt = dshFsReadText('/tmp/dsh-fs-bridge.txt');
    \\globalThis.__sz = dshFsSize('/tmp/dsh-fs-bridge.txt');
    \\globalThis.__bad = null;
    \\try { dshFsReadText('/tmp/__dsh-no-such-file__.txt'); } catch (e) { globalThis.__bad = String(e); }
    \\
;

const GLUE_P2 =
    \\globalThis.__roWrite = 'not-denied';
    \\try { dshFsWriteText('/tmp/ro-denied.txt', 'x'); } catch (e) { globalThis.__roWrite = String(e); }
    \\globalThis.__roRead = dshFsReadText('/tmp/dsh-fs-bridge.txt');
    \\globalThis.__roSz = null;
    \\try { dshFsSize('/tmp/__dsh-no-such__.txt'); } catch (e) { globalThis.__roSz = String(e); }
    \\
;

const GLUE_P3 =
    \\globalThis.__wsIn = dshFsWriteText('/tmp/ws-inside.txt', 'inside-ok');
    \\globalThis.__wsOutside = 'not-denied';
    \\try { dshFsWriteText('/etc/__dsh-outside__.txt', 'x'); } catch (e) { globalThis.__wsOutside = String(e); }
    \\globalThis.__wsRead = dshFsReadText('/tmp/ws-inside.txt');
    \\
;

fn evalGlue(ctx: ?*c.JSContext, src: []const u8) !void {
    const val = c.JS_Eval(ctx, src.ptr, src.len, "glue.js", c.JS_EVAL_TYPE_GLOBAL);
    if (c.JS_IsException(val)) {
        const ex = c.JS_GetException(ctx);
        defer c.JS_FreeValue(ctx, ex);
        const msg = c.JS_ToCStringLen(ctx, null, ex) orelse return error.NoMsg;
        defer c.JS_FreeCString(ctx, msg);
        std.debug.print("fs bridge smoke: eval exception: {s}\n", .{std.mem.span(msg)});
        return error.EvalFailed;
    }
    c.JS_FreeValue(ctx, val);
}

fn readGlobalStr(ctx: ?*c.JSContext, name: [*c]const u8) ![]const u8 {
    const global = c.JS_GetGlobalObject(ctx);
    defer c.JS_FreeValue(ctx, global);
    const v = c.JS_GetPropertyStr(ctx, global, name);
    defer c.JS_FreeValue(ctx, v);
    const s = c.JS_ToCStringLen(ctx, null, v) orelse return error.NoText;
    defer c.JS_FreeCString(ctx, s);
    // 复制到 page（借用结束）
    const out = try std.heap.page_allocator.dupe(u8, std.mem.span(s));
    return out;
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
    defer c.JS_FreeRuntime(rt);
    const ctx = c.JS_NewContext(rt) orelse return error.NewContext;
    defer c.JS_FreeContext(ctx);

    bridge.register(ctx);

    // ---- Phase 1：无策略基线 ----
    try evalGlue(ctx, GLUE_P1);
    const roundtrip = try readGlobalStr(ctx, "__rt");
    defer std.heap.page_allocator.free(roundtrip);
    const sz_out = try readGlobalInt(ctx, "__sz");
    const bad = try readGlobalStr(ctx, "__bad");
    defer std.heap.page_allocator.free(bad);
    if (!std.mem.eql(u8, roundtrip, "bridge-ok-42")) return error.RoundtripMismatch;
    if (sz_out != 12) return error.SizeMismatch;
    if (bad.len == 0) return error.NoThrowOnMissing;

    // ---- Phase 2：read_only —— 拒写、限读 ----
    const ro = pol_mod.Policy.init(pol_mod.Mode.read_only, "/tmp");
    bridge.setPolicy(&ro);
    try evalGlue(ctx, GLUE_P2);
    const ro_write = try readGlobalStr(ctx, "__roWrite");
    defer std.heap.page_allocator.free(ro_write);
    const ro_read = try readGlobalStr(ctx, "__roRead");
    defer std.heap.page_allocator.free(ro_read);
    const ro_sz = try readGlobalStr(ctx, "__roSz");
    defer std.heap.page_allocator.free(ro_sz);
    if (std.mem.eql(u8, ro_write, "not-denied")) return error.ReadOnlyDidNotDenyWrite;
    if (!std.mem.eql(u8, ro_read, "bridge-ok-42")) return error.ReadOnlyReadDenied;
    if (ro_sz.len == 0) return error.MissingShouldThrow;

    // ---- Phase 3：workspace_write —— 界内写成功、界外拒 ----
    const ws = pol_mod.Policy.init(pol_mod.Mode.workspace_write, "/tmp");
    bridge.setPolicy(&ws);
    try evalGlue(ctx, GLUE_P3);
    const ws_in = try readGlobalInt(ctx, "__wsIn");
    const ws_out = try readGlobalStr(ctx, "__wsOutside");
    defer std.heap.page_allocator.free(ws_out);
    const ws_read = try readGlobalStr(ctx, "__wsRead");
    defer std.heap.page_allocator.free(ws_read);
    if (ws_in != 1) return error.WorkspaceWriteDidNotApply;
    if (std.mem.eql(u8, ws_out, "not-denied")) return error.OutsideWriteNotDenied;
    if (!std.mem.eql(u8, ws_read, "inside-ok")) return error.WorkspaceReadbackFailed;

    bridge.clearPolicy();
    std.debug.print("fs bridge smoke: roundtrip='{s}' size={d} | ro-write denied | ws-write ok | outside denied: PASS\n", .{ roundtrip, sz_out });
    std.process.exit(0);
}
