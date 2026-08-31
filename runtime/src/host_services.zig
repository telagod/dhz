//! 宿主服务注册表 —— guest 可见形态：`dshServices.<svc>.<method>(...)`。
//! 形状对齐 cordis 服务对象（`ctx.get('fs')` 返回对象 + 方法），是宿主服务面
//! 从"扁平面"到"对象树"的收拢层；每个宿主服务模块登记自己的方法面。
//! 所有权纪律：每条属性独立 NewObject/NewCFunction（ref=1）→ SetPropertyStr
//! 消费（ref=0）——不跨属性复用（§7 attachEngine ref 结算教训的模板化）。
//! 验证：`zig build host-services-smoke-run`。

const std = @import("std");

pub const c = @import("engine_c.zig").c;

pub const CFunction = *const fn (
    ctx: ?*c.JSContext,
    this_val: c.JSValueConst,
    argc: c_int,
    argv: [*c]const c.JSValueConst,
) callconv(.c) c.JSValue;

pub const Method = struct {
    name: []const u8,
    func: CFunction,
    length: c_int,
};

pub const Service = struct {
    name: []const u8,
    methods: []const Method,
};

fn jsCwd(
    ctx: ?*c.JSContext,
    this_val: c.JSValueConst,
    argc: c_int,
    argv: [*c]const c.JSValueConst,
) callconv(.c) c.JSValue {
    _ = this_val;
    _ = argc;
    _ = argv;
    return c.JS_NewString(ctx, "/");
}

/// process 垫片（node 一等公民；DSH 生态假设 process.env/platform/cwd）。
/// 宿主启动时调用一次；env 为可选注入（"KEY=value" 数组——M-4 配置面）。
pub fn installProcessShim(ctx: ?*c.JSContext, env: []const []const u8) void {
    const global = c.JS_GetGlobalObject(ctx);
    defer c.JS_FreeValue(ctx, global);
    const proc = c.JS_NewObject(ctx);
    const env_obj = c.JS_NewObject(ctx);
    for (env) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const key_z = std.heap.page_allocator.dupeZ(u8, pair[0..eq]) catch continue;
        defer std.heap.page_allocator.free(key_z);
        _ = c.JS_SetPropertyStr(ctx, env_obj, key_z.ptr, c.JS_NewStringLen(ctx, pair[eq + 1 ..].ptr, pair[eq + 1 ..].len));
    }
    _ = c.JS_SetPropertyStr(ctx, proc, "env", env_obj);
    _ = c.JS_SetPropertyStr(ctx, proc, "platform", c.JS_NewString(ctx, "linux"));
    _ = c.JS_SetPropertyStr(ctx, proc, "pid", c.JS_NewInt64(ctx, std.os.linux.getpid()));
    _ = c.JS_SetPropertyStr(ctx, proc, "cwd", c.JS_NewCFunction(ctx, jsCwd, "cwd", 0));
    _ = c.JS_SetPropertyStr(ctx, proc, "argv", c.JS_NewArray(ctx));
    // versions（Node 一等公民——cordis-plugin-loader 的 fromInternal 读 versions.node）
    const ver = c.JS_NewObject(ctx);
    _ = c.JS_SetPropertyStr(ctx, ver, "node", c.JS_NewString(ctx, "0.0.0-embedded"));
    _ = c.JS_SetPropertyStr(ctx, ver, "dsh", c.JS_NewString(ctx, "0.0.0-zig"));
    _ = c.JS_SetPropertyStr(ctx, proc, "versions", ver);
    _ = c.JS_SetPropertyStr(ctx, global, "process", proc);
}

/// 构建 `globalThis.dshServices = { <name>: { <method>: fn, ... }, ... }`。
pub fn register(ctx: ?*c.JSContext, services: []const Service) void {
    const global = c.JS_GetGlobalObject(ctx);
    defer c.JS_FreeValue(ctx, global);
    const root = c.JS_NewObject(ctx);
    for (services) |svc| {
        const obj = c.JS_NewObject(ctx);
        for (svc.methods) |m| {
            _ = c.JS_SetPropertyStr(ctx, obj, m.name.ptr, c.JS_NewCFunction(ctx, m.func, m.name.ptr, m.length));
        }
        _ = c.JS_SetPropertyStr(ctx, root, svc.name.ptr, obj);
    }
    _ = c.JS_SetPropertyStr(ctx, global, "dshServices", root);
}
