//! fs 服务桥（M-4 服务入引擎）—— guest JS 直调 Zig fs：
//!   dshFsReadText(path) -> string | throws
//!   dshFsWriteText(path, content) -> true | throws
//!   dshFsSize(path) -> number | throws
//! 所有函数面过沙箱策略检查（M-4 §4.8 挂钩）：read_only 拒写、
//! workspace_write 写限工作区、全模式读限工作区（danger 除外）。
//! 策略经 setPolicy 注入（宿主启动时）；默认无策略 = 放开。
//! 验证：`zig build fs-bridge-smoke-run`。

const std = @import("std");
const fs_svc = @import("fs_service.zig");
const pol_mod = @import("policy.zig");

pub const c = @import("engine_c.zig").c;

/// 宿主侧策略注入点：guest 无权选择自己的沙箱（宿主权威）。
var g_policy: ?*const pol_mod.Policy = null;

pub fn setPolicy(p: *const pol_mod.Policy) void {
    g_policy = p;
}

pub fn clearPolicy() void {
    g_policy = null;
}

/// 登记到宿主服务注册表（host_services.register(services=...) 消费）。
pub const serviceMethods = [_]@import("host_services.zig").Method{
    .{ .name = "readText", .func = jsReadText, .length = 1 },
    .{ .name = "writeText", .func = jsWriteText, .length = 2 },
    .{ .name = "size", .func = jsSize, .length = 1 },
    .{ .name = "mkdir", .func = jsMkdir, .length = 1 },
    .{ .name = "realpath", .func = jsRealpath, .length = 1 },
    .{ .name = "rename", .func = jsRename, .length = 2 },
    .{ .name = "remove", .func = jsRemove, .length = 1 },
    .{ .name = "list", .func = jsList, .length = 1 },
    .{ .name = "stat", .func = jsStat, .length = 1 },
    .{ .name = "chmod", .func = jsChmod, .length = 2 },
};

/// chmod(path, mode)。
fn jsChmod(
    ctx: ?*c.JSContext,
    this_val: c.JSValueConst,
    argc: c_int,
    argv: [*c]const c.JSValueConst,
) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 2) return c.JS_ThrowTypeError(ctx, "fs.chmod(path, mode)", @as(c_int, 0));
    const p = c.JS_ToCStringLen(ctx, null, argv[0]) orelse return c.JS_ThrowTypeError(ctx, "path must be string", @as(c_int, 0));
    defer c.JS_FreeCString(ctx, p);
    var mode: c_int = 0;
    _ = c.JS_ToInt32(ctx, &mode, argv[1]);
    fs_svc.chmod(std.mem.span(p), @intCast(mode)) catch {
        return c.JS_ThrowInternalError(ctx, "fs.chmod failed", @as(c_int, 0));
    };
    return c.JS_NewBool(ctx, true);
}

/// 丰富 stat（size/inode/kind——沙箱 sameIdentity 面）。
fn jsStat(
    ctx: ?*c.JSContext,
    this_val: c.JSValueConst,
    argc: c_int,
    argv: [*c]const c.JSValueConst,
) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 1) return c.JS_ThrowTypeError(ctx, "fs.stat(path)", @as(c_int, 0));
    const p = c.JS_ToCStringLen(ctx, null, argv[0]) orelse return c.JS_ThrowTypeError(ctx, "path must be string", @as(c_int, 0));
    defer c.JS_FreeCString(ctx, p);
    const info = (fs_svc.stat(std.mem.span(p)) catch {
        return throwErrno(ctx, "ENOENT", "no such file or directory");
    }) orelse return throwErrno(ctx, "ENOENT", "no such file or directory");
    const obj = c.JS_NewObject(ctx);
    _ = c.JS_SetPropertyStr(ctx, obj, "size", c.JS_NewInt64(ctx, @intCast(info.size)));
    _ = c.JS_SetPropertyStr(ctx, obj, "inode", c.JS_NewInt64(ctx, @intCast(info.inode)));
    _ = c.JS_SetPropertyStr(ctx, obj, "mode", c.JS_NewInt64(ctx, @intCast(info.mode)));
    _ = c.JS_SetPropertyStr(ctx, obj, "kind", c.JS_NewString(ctx, switch (info.kind) {
        .directory => "directory",
        .file => "file",
        else => "other",
    }));
    return obj;
}

fn pathArg(ctx: ?*c.JSContext, v: c.JSValueConst) ?[]const u8 {
    const p = c.JS_ToCStringLen(ctx, null, v) orelse return null;
    // 借用：调用方 free（pathArgC 模式）
    return std.mem.span(p);
}

/// Node 语义 errno 错误（快速构造带 code/message 的 Error 并 throw）。
fn throwErrno(ctx: ?*c.JSContext, code: []const u8, msg: []const u8) c.JSValue {
    const err = c.JS_NewError(ctx);
    _ = c.JS_SetPropertyStr(ctx, err, "code", c.JS_NewString(ctx, code.ptr));
    _ = c.JS_SetPropertyStr(ctx, err, "message", c.JS_NewString(ctx, msg.ptr));
    return c.JS_Throw(ctx, err);
}

fn jsRealpath(
    ctx: ?*c.JSContext,
    this_val: c.JSValueConst,
    argc: c_int,
    argv: [*c]const c.JSValueConst,
) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 1) return c.JS_ThrowTypeError(ctx, "fs.realpath(path)", @as(c_int, 0));
    const p = c.JS_ToCStringLen(ctx, null, argv[0]) orelse return c.JS_ThrowTypeError(ctx, "path must be string", @as(c_int, 0));
    defer c.JS_FreeCString(ctx, p);
    const out = fs_svc.realpath(std.mem.span(p)) catch {
        // Node 语义：不存在/非目录 → Error with code='ENOENT'（dsh-fs-local 祖先解析依赖）
        return throwErrno(ctx, "ENOENT", "no such file or directory");
    };
    defer std.heap.page_allocator.free(out);
    return c.JS_NewStringLen(ctx, out.ptr, out.len);
}

fn jsRename(
    ctx: ?*c.JSContext,
    this_val: c.JSValueConst,
    argc: c_int,
    argv: [*c]const c.JSValueConst,
) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 2) return c.JS_ThrowTypeError(ctx, "fs.rename(from, to)", @as(c_int, 0));
    const a = c.JS_ToCStringLen(ctx, null, argv[0]) orelse return c.JS_ThrowTypeError(ctx, "from must be string", @as(c_int, 0));
    defer c.JS_FreeCString(ctx, a);
    const b = c.JS_ToCStringLen(ctx, null, argv[1]) orelse return c.JS_ThrowTypeError(ctx, "to must be string", @as(c_int, 0));
    defer c.JS_FreeCString(ctx, b);
    fs_svc.rename(std.mem.span(a), std.mem.span(b)) catch {
        return c.JS_ThrowInternalError(ctx, "fs.rename failed", @as(c_int, 0));
    };
    return c.JS_NewBool(ctx, true);
}

fn jsRemove(
    ctx: ?*c.JSContext,
    this_val: c.JSValueConst,
    argc: c_int,
    argv: [*c]const c.JSValueConst,
) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 1) return c.JS_ThrowTypeError(ctx, "fs.remove(path)", @as(c_int, 0));
    const p = c.JS_ToCStringLen(ctx, null, argv[0]) orelse return c.JS_ThrowTypeError(ctx, "path must be string", @as(c_int, 0));
    defer c.JS_FreeCString(ctx, p);
    fs_svc.remove(std.mem.span(p)) catch {
        return c.JS_ThrowInternalError(ctx, "fs.remove failed", @as(c_int, 0));
    };
    return c.JS_NewBool(ctx, true);
}

fn jsList(
    ctx: ?*c.JSContext,
    this_val: c.JSValueConst,
    argc: c_int,
    argv: [*c]const c.JSValueConst,
) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 1) return c.JS_ThrowTypeError(ctx, "fs.list(path)", @as(c_int, 0));
    const p = c.JS_ToCStringLen(ctx, null, argv[0]) orelse return c.JS_ThrowTypeError(ctx, "path must be string", @as(c_int, 0));
    defer c.JS_FreeCString(ctx, p);
    const names = fs_svc.listNames(std.mem.span(p)) catch {
        return c.JS_ThrowInternalError(ctx, "fs.list failed", @as(c_int, 0));
    };
    defer {
        for (names) |n| std.heap.page_allocator.free(n);
        std.heap.page_allocator.free(names);
    }
    const arr = c.JS_NewArray(ctx);
    for (names, 0..) |n, i| {
        _ = c.JS_SetPropertyUint32(ctx, arr, @intCast(i), c.JS_NewStringLen(ctx, n.ptr, n.len));
    }
    return arr;
}

fn jsMkdir(
    ctx: ?*c.JSContext,
    this_val: c.JSValueConst,
    argc: c_int,
    argv: [*c]const c.JSValueConst,
) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 1) return c.JS_ThrowTypeError(ctx, "fs.mkdir(path)", @as(c_int, 0));
    const p = c.JS_ToCStringLen(ctx, null, argv[0]) orelse return c.JS_ThrowTypeError(ctx, "path must be string", @as(c_int, 0));
    defer c.JS_FreeCString(ctx, p);
    fs_svc.mkdirp(std.mem.span(p)) catch {
        return c.JS_ThrowInternalError(ctx, "fs.mkdir failed", @as(c_int, 0));
    };
    return c.JS_NewBool(ctx, true);
}

pub fn register(ctx: ?*c.JSContext) void {
    const global = c.JS_GetGlobalObject(ctx);
    defer c.JS_FreeValue(ctx, global);
    _ = c.JS_SetPropertyStr(ctx, global, "dshFsReadText", c.JS_NewCFunction(ctx, jsReadText, "dshFsReadText", 1));
    _ = c.JS_SetPropertyStr(ctx, global, "dshFsWriteText", c.JS_NewCFunction(ctx, jsWriteText, "dshFsWriteText", 2));
    _ = c.JS_SetPropertyStr(ctx, global, "dshFsSize", c.JS_NewCFunction(ctx, jsSize, "dshFsSize", 1));
}

fn fsWithPolicy() fs_svc.Fs {
    fs_svc.initIo();
    return if (g_policy) |p|
        fs_svc.Fs.initPoliced("/", std.heap.page_allocator, p)
    else
        fs_svc.Fs.init("/", std.heap.page_allocator);
}

pub fn jsReadText(
    ctx: ?*c.JSContext,
    this_val: c.JSValueConst,
    argc: c_int,
    argv: [*c]const c.JSValueConst,
) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 1) return c.JS_ThrowTypeError(ctx, "dshFsReadText(path)", @as(c_int, 0));
    const p = c.JS_ToCStringLen(ctx, null, argv[0]) orelse return c.JS_ThrowTypeError(ctx, "path must be string", @as(c_int, 0));
    defer c.JS_FreeCString(ctx, p);
    const path = std.mem.span(p);
    const f = fsWithPolicy();
    const content = f.readTextPoliced(path) catch {
        return throwErrno(ctx, "ENOENT", "no such file or directory");
    };
    defer std.heap.page_allocator.free(content);
    return c.JS_NewStringLen(ctx, content.ptr, content.len);
}

pub fn jsWriteText(
    ctx: ?*c.JSContext,
    this_val: c.JSValueConst,
    argc: c_int,
    argv: [*c]const c.JSValueConst,
) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 2) return c.JS_ThrowTypeError(ctx, "dshFsWriteText(path, content)", @as(c_int, 0));
    const p = c.JS_ToCStringLen(ctx, null, argv[0]) orelse return c.JS_ThrowTypeError(ctx, "path must be string", @as(c_int, 0));
    defer c.JS_FreeCString(ctx, p);
    var clen: usize = 0;
    const content = c.JS_ToCStringLen(ctx, &clen, argv[1]) orelse return c.JS_ThrowTypeError(ctx, "content must be string", @as(c_int, 0));
    defer c.JS_FreeCString(ctx, content);
    const path = std.mem.span(p);
    const f = fsWithPolicy();
    f.writeText(path, content[0..clen]) catch {
        return c.JS_ThrowInternalError(ctx, "dshFsWriteText: policy or write failed", @as(c_int, 0));
    };
    return c.JS_NewBool(ctx, true);
}

pub fn jsSize(
    ctx: ?*c.JSContext,
    this_val: c.JSValueConst,
    argc: c_int,
    argv: [*c]const c.JSValueConst,
) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 1) return c.JS_ThrowTypeError(ctx, "dshFsSize(path)", @as(c_int, 0));
    const p = c.JS_ToCStringLen(ctx, null, argv[0]) orelse return c.JS_ThrowTypeError(ctx, "path must be string", @as(c_int, 0));
    defer c.JS_FreeCString(ctx, p);
    const path = std.mem.span(p);
    const f = fsWithPolicy();
    if (f.policy) |pol| {
        pol.checkRead(path) catch {
            return c.JS_ThrowInternalError(ctx, "dshFsSize: policy denied", @as(c_int, 0));
        };
    }
    const info = (fs_svc.stat(path) catch {
        return throwErrno(ctx, "ENOENT", "no such file or directory");
    }) orelse return throwErrno(ctx, "ENOENT", "no such file or directory");
    return c.JS_NewInt64(ctx, @intCast(info.size));
}
