//! invalid UTF-8 根因对照 probe：模块系统活动（loader 安装 / module eval / 装载）
//! 对 JS_Eval 解析含非 ASCII 源码的影响（runtime 拼接源场景复现）。
//! 运行: `zig build utf8-probe-run`

const std = @import("std");

const c = @cImport({
    @cInclude("quickjs.h");
});

fn moduleLoader(
    ctx: ?*c.JSContext,
    module_name: [*c]const u8,
    userdata: ?*anyopaque,
    attributes: c.JSValueConst,
) callconv(.c) ?*c.JSModuleDef {
    _ = ctx;
    _ = module_name;
    _ = userdata;
    _ = attributes;
    return null; // 未装载任何真实导入
}

/// eval 含中文的源；true=成功。
fn evalUtf8(ctx: ?*c.JSContext, tag: []const u8, src: []const u8) bool {
    const v = c.JS_Eval(ctx, src.ptr, src.len, "utf8.js", c.JS_EVAL_TYPE_GLOBAL);
    if (c.JS_IsException(v)) {
        std.debug.print("  [{s}] FAIL\n", .{tag});
        c.JS_FreeValue(ctx, v);
        return false;
    }
    c.JS_FreeValue(ctx, v);
    std.debug.print("  [{s}] OK\n", .{tag});
    return true;
}

pub fn main() !void {
    const utf8_src = "var 你好 = 'world'; globalThis.__utf8Ok = 你好;";
    var ok: usize = 0;

    // A: 裸 runtime（无 loader）
    {
        const rt = c.JS_NewRuntime() orelse return error.NewRuntime;
        defer c.JS_FreeRuntime(rt);
        const ctx = c.JS_NewContext(rt) orelse return error.NewContext;
        defer c.JS_FreeContext(ctx);
        if (evalUtf8(ctx, "A bare-no-loader", utf8_src)) ok += 1;
    }

    // B: 设 loader（不 eval 任何模块）
    {
        const rt = c.JS_NewRuntime() orelse return error.NewRuntime;
        defer c.JS_FreeRuntime(rt);
        c.JS_SetModuleLoaderFunc2(rt, null, moduleLoader, null, null);
        const ctx = c.JS_NewContext(rt) orelse return error.NewContext;
        defer c.JS_FreeContext(ctx);
        if (evalUtf8(ctx, "B loader-installed", utf8_src)) ok += 1;
    }

    // C: 设 loader + eval 一个 ES module（模块系统活动）→ 再 eval UTF-8
    {
        const rt = c.JS_NewRuntime() orelse return error.NewRuntime;
        defer c.JS_FreeRuntime(rt);
        c.JS_SetModuleLoaderFunc2(rt, null, moduleLoader, null, null);
        const ctx = c.JS_NewContext(rt) orelse return error.NewContext;
        defer c.JS_FreeContext(ctx);
        const mod_src = "export const m = 42;";
        const mv = c.JS_Eval(ctx, mod_src.ptr, mod_src.len, "m0.mjs", c.JS_EVAL_TYPE_MODULE);
        if (!c.JS_IsException(mv)) {
            // 驱动 module 初始化 job（模块系统真正"活动"）
            var jctx: ?*c.JSContext = ctx;
            var guard: usize = 0;
            while (c.JS_ExecutePendingJob(rt, &jctx) > 0) : (guard += 1) {
                if (guard > 64) break;
            }
            c.JS_FreeValue(ctx, mv);
        }
        if (evalUtf8(ctx, "C after-module-eval", utf8_src)) ok += 1;
    }

    // D: 设 loader + **解析含非 ASCII 的模块源** → 再 eval UTF-8
    {
        const rt = c.JS_NewRuntime() orelse return error.NewRuntime;
        defer c.JS_FreeRuntime(rt);
        c.JS_SetModuleLoaderFunc2(rt, null, moduleLoader, null, null);
        const ctx = c.JS_NewContext(rt) orelse return error.NewContext;
        defer c.JS_FreeContext(ctx);
        const mod_src = "export const 你好 = 'world';";
        const mv = c.JS_Eval(ctx, mod_src.ptr, mod_src.len, "m1.mjs", c.JS_EVAL_TYPE_MODULE);
        if (!c.JS_IsException(mv)) {
            var jctx: ?*c.JSContext = ctx;
            var guard: usize = 0;
            while (c.JS_ExecutePendingJob(rt, &jctx) > 0) : (guard += 1) {
                if (guard > 64) break;
            }
            c.JS_FreeValue(ctx, mv);
        } else {
            std.debug.print("  [D module-with-cjk] FAIL\n", .{});
            c.JS_FreeValue(ctx, mv);
        }
        if (evalUtf8(ctx, "D after-cjk-module", utf8_src)) ok += 1;
    }

    std.debug.print("utf8 probe: {d}/4 UTF-8 eval OK\n", .{ok});
    if (ok != 4) return error.Utf8EvalBlocked;
}
