//! 子进程服务桥—— guest 经 dshServices.proc 执行进程：
//!   run(cmd, args?)  -> { code, stdout }（阻塞同步一次性）
//!   spawn(argv)      -> handle（M-7 异步面：pid + 流读/写 + 非阻塞 done 轮询 + 终止升级）
//!       handle.read('out'|'err')  -> 字符串块（最多 2KB/次；EAGAIN/EOF -> ''）
//!       handle.write(s)           -> bool（全写入；已关/破裂 -> false）
//!       handle.endIn()            -> 关闭 stdin 写端
//!       handle.wait()             -> -1 错误 / 0 运行中 / 1 已退出（非阻塞）
//!       handle.code()             -> 退出码（正常退出）或 -1
//!       handle.termsig()          -> 终止信号（信号退出）或 0
//!       handle.terminate()        -> 进程组 SIGTERM
//!       handle.kill()             -> 进程组 SIGKILL（升级链末级）
//!       handle.close()            -> 释放 fd 与槽位
//! 底层：proc_wrap.c（fork/setsid/3 管道/execvp + waitpid WNOHANG + kill(-pid)）。
//! M-4 挂钩点：policy.confineArgv（landlock 前置直通；spawn 子进程 sandbox 注入=与 run 同轨）。
//! 验证：`zig build proc-smoke-run`；M-7 面经 boot-smoke（guest 泵读双段输出 + exit 7）。

const std = @import("std");
const hs = @import("host_services.zig");
const pol_mod = @import("policy.zig");

pub const c = @import("engine_c.zig").c;

const proc_c = @cImport({
    @cInclude("proc_wrap.h");
});

/// 宿主侧策略注入点（与 fs_bridge 同形态；confineArgv 落地后接管 argv 边界）。
var g_policy: ?*const pol_mod.Policy = null;

pub fn setPolicy(p: *const pol_mod.Policy) void {
    g_policy = p;
}

pub fn clearPolicy() void {
    g_policy = null;
}

pub const serviceMethods = [_]hs.Method{
    .{ .name = "run", .func = jsRun, .length = 1 },
    .{ .name = "spawn", .func = jsSpawn, .length = 1 },
};

const MAX_ARGS = 16;
const MAX_ENV = 64;
const MAX_HANDLES = 16;

const Handle = struct {
    used: bool = false,
    pid: c_int = 0,
    in_fd: c_int = -1,
    out_fd: c_int = -1,
    err_fd: c_int = -1,
    exited: bool = false,
    raw_status: c_int = 0,
    out_eof: bool = false,
    err_eof: bool = false,
    in_closed: bool = false,
};

var handles = [_]Handle{.{}} ** MAX_HANDLES;

fn handleFromThis(ctx: ?*c.JSContext, this_val: c.JSValueConst) ?*Handle {
    const idv = c.JS_GetPropertyStr(ctx, this_val, "id");
    defer c.JS_FreeValue(ctx, idv);
    var id: c_int = -1;
    _ = c.JS_ToInt32(ctx, &id, idv);
    if (id < 0 or id >= MAX_HANDLES) return null;
    const h = &handles[@intCast(id)];
    if (!h.used) return null;
    return h;
}

fn jsRun(
    ctx: ?*c.JSContext,
    this_val: c.JSValueConst,
    argc: c_int,
    argv: [*c]const c.JSValueConst,
) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 1) return c.JS_ThrowTypeError(ctx, "proc.run(cmd, args?)", @as(c_int, 0));
    const cmd = c.JS_ToCStringLen(ctx, null, argv[0]) orelse return c.JS_ThrowTypeError(ctx, "cmd must be string", @as(c_int, 0));
    defer c.JS_FreeCString(ctx, cmd);

    // C 字符串借用表（GC 暂停期间有效；统一在末尾释放）
    var owned: [MAX_ARGS]?[*c]const u8 = undefined;
    for (&owned) |*o| o.* = null;
    defer for (&owned) |o| {
        if (o) |s| c.JS_FreeCString(ctx, s);
    };

    var argv_ptrs: [MAX_ARGS + 1][*c]const u8 = undefined;
    argv_ptrs[0] = @ptrCast(cmd);
    var argc_total: usize = 1;
    if (argc >= 2 and c.JS_IsArray(argv[1])) {
        const arr = c.JS_GetPropertyStr(ctx, argv[1], "length");
        defer c.JS_FreeValue(ctx, arr);
        var n: c_int = 0;
        _ = c.JS_ToInt32(ctx, &n, arr);
        var i: usize = 0;
        while (i < @as(usize, @intCast(n)) and argc_total < MAX_ARGS) : (i += 1) {
            const item = c.JS_GetPropertyUint32(ctx, argv[1], @intCast(i));
            defer c.JS_FreeValue(ctx, item);
            const s = c.JS_ToCStringLen(ctx, null, item) orelse
                return c.JS_ThrowTypeError(ctx, "args must be strings", @as(c_int, 0));
            owned[argc_total] = s;
            argv_ptrs[argc_total] = @ptrCast(s);
            argc_total += 1;
        }
    }
    argv_ptrs[argc_total] = null;

    // 沙箱边界：landlock（fork 后 child 套用；mode 2=danger 跳过）
    var mode: c_int = 2; // danger（无策略时放开）
    var root_cstr: [*c]const u8 = "";
    if (g_policy) |pol| {
        mode = switch (pol.mode) {
            .read_only => 0,
            .workspace_write => 1,
            .danger_full_access => 2,
        };
        // root 传递：policy 生命周期稳定（静态/rodata 切片）
        root_cstr = @ptrCast(pol.workspace_root.ptr);
    }

    var out_buf: [64 * 1024]u8 = undefined;
    var out_len: usize = 0;
    var code: c_int = 0;
    if (proc_c.dsh_proc_run(&argv_ptrs, &out_buf, out_buf.len, &out_len, &code, root_cstr, mode) != 0) {
        return c.JS_ThrowInternalError(ctx, "proc failed", @as(c_int, 0));
    }

    const res = c.JS_NewObject(ctx);
    _ = c.JS_SetPropertyStr(ctx, res, "code", c.JS_NewInt64(ctx, code));
    _ = c.JS_SetPropertyStr(ctx, res, "stdout", c.JS_NewStringLen(ctx, &out_buf, out_len));
    return res;
}

// —— M-7 异步 spawn 面 ——

fn jsSpawn(
    ctx: ?*c.JSContext,
    this_val: c.JSValueConst,
    argc: c_int,
    argv: [*c]const c.JSValueConst,
) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 1 or !c.JS_IsArray(argv[0])) return c.JS_ThrowTypeError(ctx, "proc.spawn(args)", @as(c_int, 0));

    var owned: [MAX_ARGS]?[*c]const u8 = undefined;
    for (&owned) |*o| o.* = null;
    defer for (&owned) |o| {
        if (o) |s| c.JS_FreeCString(ctx, s);
    };
    var argv_ptrs: [MAX_ARGS + 1][*c]const u8 = undefined;
    var argc_total: usize = 0;
    const arr = c.JS_GetPropertyStr(ctx, argv[0], "length");
    defer c.JS_FreeValue(ctx, arr);
    var n: c_int = 0;
    _ = c.JS_ToInt32(ctx, &n, arr);
    var i: usize = 0;
    while (i < @as(usize, @intCast(n)) and argc_total < MAX_ARGS) : (i += 1) {
        const item = c.JS_GetPropertyUint32(ctx, argv[0], @intCast(i));
        defer c.JS_FreeValue(ctx, item);
        const s = c.JS_ToCStringLen(ctx, null, item) orelse
            return c.JS_ThrowTypeError(ctx, "args must be strings", @as(c_int, 0));
        owned[argc_total] = s;
        argv_ptrs[argc_total] = @ptrCast(s);
        argc_total += 1;
    }
    if (argc_total == 0) return c.JS_ThrowTypeError(ctx, "spawn: empty argv", @as(c_int, 0));
    argv_ptrs[argc_total] = null;

    // 环境（可选）：argv[1] = ['K=V', ...] 数组——scrubbed env 面（JS 层准备；NULL=继承宿主）。
    var env_owned: [MAX_ENV]?[*c]const u8 = undefined;
    for (&env_owned) |*o| o.* = null;
    defer for (&env_owned) |o| {
        if (o) |s| c.JS_FreeCString(ctx, s);
    };
    var envp_ptrs: [MAX_ENV + 1][*c]const u8 = undefined;
    for (&envp_ptrs) |*o| o.* = null;
    var env_total: usize = 0;
    if (argc >= 2 and c.JS_IsArray(argv[1])) {
        const earr = c.JS_GetPropertyStr(ctx, argv[1], "length");
        defer c.JS_FreeValue(ctx, earr);
        var en: c_int = 0;
        _ = c.JS_ToInt32(ctx, &en, earr);
        var ei: usize = 0;
        while (ei < @as(usize, @intCast(en)) and env_total < MAX_ENV) : (ei += 1) {
            const item = c.JS_GetPropertyUint32(ctx, argv[1], @intCast(ei));
            defer c.JS_FreeValue(ctx, item);
            const s = c.JS_ToCStringLen(ctx, null, item) orelse
                return c.JS_ThrowTypeError(ctx, "env entries must be strings", @as(c_int, 0));
            env_owned[env_total] = s;
            envp_ptrs[env_total] = @ptrCast(s);
            env_total += 1;
        }
    }
    const env_arg: [*c]const [*c]const u8 = if (env_total > 0)
        @ptrCast(&envp_ptrs)
    else
        null;

    var mode: c_int = 2;
    var root_cstr: [*c]const u8 = "";
    if (g_policy) |pol| {
        mode = switch (pol.mode) {
            .read_only => 0,
            .workspace_write => 1,
            .danger_full_access => 2,
        };
        root_cstr = @ptrCast(pol.workspace_root.ptr);
    }

    var in_fd: c_int = 0;
    var out_fd: c_int = 0;
    var err_fd: c_int = 0;
    var pid: c_int = 0;
    if (proc_c.dsh_proc_spawn(&argv_ptrs, env_arg, &in_fd, &out_fd, &err_fd, &pid, root_cstr, mode) != 0) {
        return c.JS_ThrowInternalError(ctx, "spawn failed", @as(c_int, 0));
    }
    // 读端非阻塞（泵读语义：EAGAIN -> ''；EOF -> '' + flag）
    _ = std.c.fcntl(out_fd, @as(c_int, 4), @as(c_int, 0x800));
    _ = std.c.fcntl(err_fd, @as(c_int, 4), @as(c_int, 0x800));

    var idx: usize = 0;
    var found: bool = false;
    while (idx < MAX_HANDLES) : (idx += 1) {
        if (!handles[idx].used) {
            found = true;
            break;
        }
    }
    if (!found) {
        _ = std.os.linux.close(@intCast(in_fd));
        _ = std.os.linux.close(@intCast(out_fd));
        _ = std.os.linux.close(@intCast(err_fd));
        return c.JS_ThrowRangeError(ctx, "proc handle table full", @as(c_int, 0));
    }
    handles[idx] = .{
        .used = true,
        .pid = pid,
        .in_fd = in_fd,
        .out_fd = out_fd,
        .err_fd = err_fd,
    };

    const h = c.JS_NewObject(ctx);
    _ = c.JS_SetPropertyStr(ctx, h, "id", c.JS_NewInt64(ctx, @intCast(idx)));
    _ = c.JS_SetPropertyStr(ctx, h, "pid", c.JS_NewInt64(ctx, pid));
    _ = c.JS_SetPropertyStr(ctx, h, "read", c.JS_NewCFunction(ctx, jsHRead, "read", 1));
    _ = c.JS_SetPropertyStr(ctx, h, "write", c.JS_NewCFunction(ctx, jsHWrite, "write", 1));
    _ = c.JS_SetPropertyStr(ctx, h, "endIn", c.JS_NewCFunction(ctx, jsHEndIn, "endIn", 0));
    _ = c.JS_SetPropertyStr(ctx, h, "wait", c.JS_NewCFunction(ctx, jsHWait, "wait", 0));
    _ = c.JS_SetPropertyStr(ctx, h, "code", c.JS_NewCFunction(ctx, jsHCode, "code", 0));
    _ = c.JS_SetPropertyStr(ctx, h, "termsig", c.JS_NewCFunction(ctx, jsHTermSig, "termsig", 0));
    _ = c.JS_SetPropertyStr(ctx, h, "terminate", c.JS_NewCFunction(ctx, jsHTerminate, "terminate", 0));
    _ = c.JS_SetPropertyStr(ctx, h, "kill", c.JS_NewCFunction(ctx, jsHKill, "kill", 0));
    _ = c.JS_SetPropertyStr(ctx, h, "close", c.JS_NewCFunction(ctx, jsHClose, "close", 0));
    return h;
}

/// 读一块（非阻塞）：stream：'out'（默认）| 'err'。最多 2KB/次。
fn jsHRead(
    ctx: ?*c.JSContext,
    this_val: c.JSValueConst,
    argc: c_int,
    argv: [*c]const c.JSValueConst,
) callconv(.c) c.JSValue {
    const h = handleFromThis(ctx, this_val) orelse
        return c.JS_ThrowTypeError(ctx, "invalid subprocess handle", @as(c_int, 0));
    var use_err = false;
    if (argc >= 1) {
        const s = c.JS_ToCStringLen(ctx, null, argv[0]) orelse return c.JS_ThrowTypeError(ctx, "stream name", @as(c_int, 0));
        defer c.JS_FreeCString(ctx, s);
        use_err = std.mem.eql(u8, std.mem.span(s), "err");
    }
    const fd: c_int = if (use_err) h.err_fd else h.out_fd;
    const eof = if (use_err) h.err_eof else h.out_eof;
    if (fd < 0 or eof) {
        const empty: []const u8 = "";
        return c.JS_NewStringLen(ctx, empty.ptr, 0);
    }
    var buf: [2048]u8 = undefined;
    var used: usize = 0;
    while (used < buf.len) {
        const n = std.os.linux.read(@intCast(fd), buf[used..].ptr, buf.len - used);
        const err = std.os.linux.errno(n);
        if (err != .SUCCESS) break; // EAGAIN（数据已尽）或其他
        if (n == 0) {
            if (use_err) h.err_eof = true else h.out_eof = true;
            break;
        }
        used += n;
    }
    return c.JS_NewStringLen(ctx, &buf, used);
}

/// 写 stdin 全部字节；写端已关/破裂 -> false。
fn jsHWrite(
    ctx: ?*c.JSContext,
    this_val: c.JSValueConst,
    argc: c_int,
    argv: [*c]const c.JSValueConst,
) callconv(.c) c.JSValue {
    const h = handleFromThis(ctx, this_val) orelse
        return c.JS_ThrowTypeError(ctx, "invalid subprocess handle", @as(c_int, 0));
    if (argc < 1) return c.JS_ThrowTypeError(ctx, "write(data)", @as(c_int, 0));
    if (h.in_closed or h.in_fd < 0) return c.JS_NewBool(ctx, false);
    var len: usize = 0;
    const s = c.JS_ToCStringLen(ctx, &len, argv[0]) orelse return c.JS_ThrowTypeError(ctx, "data must be string", @as(c_int, 0));
    defer c.JS_FreeCString(ctx, s);
    const data = s[0..len];
    var off: usize = 0;
    while (off < data.len) {
        const n = std.os.linux.write(@intCast(h.in_fd), data[off..].ptr, data.len - off);
        if (std.os.linux.errno(n) != .SUCCESS) return c.JS_NewBool(ctx, false);
        if (n == 0) return c.JS_NewBool(ctx, false);
        off += n;
    }
    return c.JS_NewBool(ctx, true);
}

fn jsHEndIn(
    ctx: ?*c.JSContext,
    this_val: c.JSValueConst,
    argc: c_int,
    argv: [*c]const c.JSValueConst,
) callconv(.c) c.JSValue {
    _ = argc;
    _ = argv;
    const h = handleFromThis(ctx, this_val) orelse
        return c.JS_ThrowTypeError(ctx, "invalid subprocess handle", @as(c_int, 0));
    if (!h.in_closed and h.in_fd >= 0) {
        _ = std.os.linux.close(@intCast(h.in_fd));
        h.in_fd = -1;
        h.in_closed = true;
    }
    const undef: c.JSValue = .{ .u = .{ .int32 = 0 }, .tag = c.JS_TAG_UNDEFINED };
    return undef;
}

/// 非阻塞 done 轮询：-1 错误 / 0 运行中 / 1 已退出。
fn jsHWait(
    ctx: ?*c.JSContext,
    this_val: c.JSValueConst,
    argc: c_int,
    argv: [*c]const c.JSValueConst,
) callconv(.c) c.JSValue {
    _ = argc;
    _ = argv;
    const h = handleFromThis(ctx, this_val) orelse
        return c.JS_ThrowTypeError(ctx, "invalid subprocess handle", @as(c_int, 0));
    if (h.exited) return c.JS_NewInt64(ctx, 1);
    var raw: c_int = 0;
    const r = proc_c.dsh_proc_wait(h.pid, &raw);
    if (r < 0) return c.JS_NewInt64(ctx, -1);
    if (r == 1) {
        h.exited = true;
        h.raw_status = raw;
    }
    return c.JS_NewInt64(ctx, r);
}

/// 退出码（WIFEXITED）或 -1（未退出/信号退出）。
fn jsHCode(
    ctx: ?*c.JSContext,
    this_val: c.JSValueConst,
    argc: c_int,
    argv: [*c]const c.JSValueConst,
) callconv(.c) c.JSValue {
    _ = argc;
    _ = argv;
    const h = handleFromThis(ctx, this_val) orelse
        return c.JS_ThrowTypeError(ctx, "invalid subprocess handle", @as(c_int, 0));
    if (!h.exited) return c.JS_NewInt64(ctx, -1);
    const raw: u32 = @bitCast(h.raw_status);
    if ((raw & 0x7f) != 0) return c.JS_NewInt64(ctx, -1);
    return c.JS_NewInt64(ctx, @intCast((raw >> 8) & 0xff));
}

/// 终止信号（WIFSIGNALED）或 0（未退出/正常退出）。
fn jsHTermSig(
    ctx: ?*c.JSContext,
    this_val: c.JSValueConst,
    argc: c_int,
    argv: [*c]const c.JSValueConst,
) callconv(.c) c.JSValue {
    _ = argc;
    _ = argv;
    const h = handleFromThis(ctx, this_val) orelse
        return c.JS_ThrowTypeError(ctx, "invalid subprocess handle", @as(c_int, 0));
    if (!h.exited) return c.JS_NewInt64(ctx, 0);
    const raw: u32 = @bitCast(h.raw_status);
    return c.JS_NewInt64(ctx, @intCast(raw & 0x7f));
}

fn jsHTerminate(
    ctx: ?*c.JSContext,
    this_val: c.JSValueConst,
    argc: c_int,
    argv: [*c]const c.JSValueConst,
) callconv(.c) c.JSValue {
    _ = argc;
    _ = argv;
    const h = handleFromThis(ctx, this_val) orelse
        return c.JS_ThrowTypeError(ctx, "invalid subprocess handle", @as(c_int, 0));
    if (h.pid > 0) proc_c.dsh_proc_terminate(h.pid);
    const undef: c.JSValue = .{ .u = .{ .int32 = 0 }, .tag = c.JS_TAG_UNDEFINED };
    return undef;
}

fn jsHKill(
    ctx: ?*c.JSContext,
    this_val: c.JSValueConst,
    argc: c_int,
    argv: [*c]const c.JSValueConst,
) callconv(.c) c.JSValue {
    _ = argc;
    _ = argv;
    const h = handleFromThis(ctx, this_val) orelse
        return c.JS_ThrowTypeError(ctx, "invalid subprocess handle", @as(c_int, 0));
    if (h.pid > 0) proc_c.dsh_proc_kill(h.pid);
    const undef: c.JSValue = .{ .u = .{ .int32 = 0 }, .tag = c.JS_TAG_UNDEFINED };
    return undef;
}

fn jsHClose(
    ctx: ?*c.JSContext,
    this_val: c.JSValueConst,
    argc: c_int,
    argv: [*c]const c.JSValueConst,
) callconv(.c) c.JSValue {
    _ = argc;
    _ = argv;
    const h = handleFromThis(ctx, this_val) orelse
        return c.JS_ThrowTypeError(ctx, "invalid subprocess handle", @as(c_int, 0));
    if (h.in_fd >= 0) {
        _ = std.os.linux.close(@intCast(h.in_fd));
        h.in_fd = -1;
    }
    if (h.out_fd >= 0) {
        _ = std.os.linux.close(@intCast(h.out_fd));
        h.out_fd = -1;
    }
    if (h.err_fd >= 0) {
        _ = std.os.linux.close(@intCast(h.err_fd));
        h.err_fd = -1;
    }
    h.used = false;
    const undef: c.JSValue = .{ .u = .{ .int32 = 0 }, .tag = c.JS_TAG_UNDEFINED };
    return undef;
}
