//! sqlite 服务桥—— guest 经 dshServices.sqlite 驱动 DatabaseSync 镜像：
//!   open(path) -> id / exec(id, sql) / run(id, sql, params?) -> changes
//!   all(id, sql, params?) -> [{ col: value }] / close(id)
//! 句柄表（id=槽+1）；params 位置参数（DSH 全用 '?'）；行对象柱值映射：
//! int->number, real->number, text->string, null->null。
//! 验证：`zig build sqlite-bridge-smoke-run`。

const std = @import("std");
const hs = @import("host_services.zig");
const sqlite_mod = @import("sqlite_shim.zig");

pub const c = @import("engine_c.zig").c;

const MAX_DBS = 8;

const DbEntry = struct {
    db: sqlite_mod.Database = .{},
    used: bool = false,
};

var g_dbs: [MAX_DBS]DbEntry = blk: {
    var t: [MAX_DBS]DbEntry = undefined;
    for (&t) |*e| e.* = .{};
    break :blk t;
};

pub const serviceMethods = [_]hs.Method{
    .{ .name = "open", .func = jsOpen, .length = 1 },
    .{ .name = "exec", .func = jsExec, .length = 2 },
    .{ .name = "run", .func = jsRun, .length = 2 },
    .{ .name = "all", .func = jsAll, .length = 2 },
    .{ .name = "close", .func = jsClose, .length = 1 },
};

fn dbById(ctx: ?*c.JSContext, v: c.JSValueConst) ?*DbEntry {
    var id: c_int = 0;
    _ = c.JS_ToInt32(ctx, &id, v);
    if (id <= 0 or id > MAX_DBS) return null;
    const entry = &g_dbs[@intCast(id - 1)];
    if (!entry.used) return null;
    return entry;
}

fn jsOpen(
    ctx: ?*c.JSContext,
    this_val: c.JSValueConst,
    argc: c_int,
    argv: [*c]const c.JSValueConst,
) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 1) return c.JS_ThrowTypeError(ctx, "sqlite.open(path)", @as(c_int, 0));
    const p = c.JS_ToCStringLen(ctx, null, argv[0]) orelse return c.JS_ThrowTypeError(ctx, "path must be string", @as(c_int, 0));
    defer c.JS_FreeCString(ctx, p);
    var slot: ?*DbEntry = null;
    for (&g_dbs) |*e| {
        if (!e.used) {
            slot = e;
            break;
        }
    }
    if (slot == null) return c.JS_ThrowRangeError(ctx, "sqlite handle table full", @as(c_int, 0));
    const db = sqlite_mod.Database.open(std.mem.span(p), "memory", 5000) catch {
        return c.JS_ThrowInternalError(ctx, "sqlite open failed", @as(c_int, 0));
    };
    const idx: usize = @as(usize, @intCast(@intFromPtr(slot) - @intFromPtr(&g_dbs[0]))) / @sizeOf(DbEntry);
    slot.?.* = .{ .db = db, .used = true };
    return c.JS_NewInt32(ctx, @intCast(idx + 1));
}

fn jsClose(
    ctx: ?*c.JSContext,
    this_val: c.JSValueConst,
    argc: c_int,
    argv: [*c]const c.JSValueConst,
) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 1) return jsUndefWrap();
    const entry = dbById(ctx, argv[0]) orelse return jsUndefWrap();
    entry.db.close();
    entry.* = .{};
    return c.JS_NewBool(ctx, true);
}

fn jsExec(
    ctx: ?*c.JSContext,
    this_val: c.JSValueConst,
    argc: c_int,
    argv: [*c]const c.JSValueConst,
) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 2) return c.JS_ThrowTypeError(ctx, "sqlite.exec(id, sql)", @as(c_int, 0));
    const entry = dbById(ctx, argv[0]) orelse return c.JS_ThrowTypeError(ctx, "bad db id", @as(c_int, 0));
    const sql = c.JS_ToCStringLen(ctx, null, argv[1]) orelse return c.JS_ThrowTypeError(ctx, "sql must be string", @as(c_int, 0));
    defer c.JS_FreeCString(ctx, sql);
    entry.db.exec(std.mem.span(sql)) catch {
        return c.JS_ThrowInternalError(ctx, "sqlite exec failed", @as(c_int, 0));
    };
    return c.JS_NewBool(ctx, true);
}

/// 位置参数收集：params 数组 → Param[]（text 借用 guest 串；SQLITE_TRANSIENT 立即复制）
fn paramsFromJS(
    ctx: ?*c.JSContext,
    v: c.JSValueConst,
    arena: std.mem.Allocator,
) ?[]const sqlite_mod.Param {
    if (!c.JS_IsNull(v) and !c.JS_IsUndefined(v)) {
        if (!c.JS_IsArray(v)) return null;
        const arrlen = c.JS_GetPropertyStr(ctx, v, "length");
        defer c.JS_FreeValue(ctx, arrlen);
        var n: c_int = 0;
        _ = c.JS_ToInt32(ctx, &n, arrlen);
        const params = arena.alloc(sqlite_mod.Param, @intCast(n)) catch return null;
        var i: usize = 0;
        while (i < @as(usize, @intCast(n))) : (i += 1) {
            const item = c.JS_GetPropertyUint32(ctx, v, @intCast(i));
            defer c.JS_FreeValue(ctx, item);
            if (c.JS_IsNull(item) or c.JS_IsUndefined(item)) {
                params[i] = .null;
            } else if (c.JS_IsNumber(item)) {
                var out: i64 = 0;
                _ = c.JS_ToInt64(ctx, &out, item);
                params[i] = .{ .int = out };
            } else {
                const s = c.JS_ToCStringLen(ctx, null, item) orelse return null;
                defer c.JS_FreeCString(ctx, s);
                const dup = arena.dupe(u8, std.mem.span(s)) catch return null;
                params[i] = .{ .text = dup };
            }
        }
        return params;
    }
    return arena.alloc(sqlite_mod.Param, 0) catch null;
}

fn jsRun(
    ctx: ?*c.JSContext,
    this_val: c.JSValueConst,
    argc: c_int,
    argv: [*c]const c.JSValueConst,
) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 2) return c.JS_ThrowTypeError(ctx, "sqlite.run(id, sql, params?)", @as(c_int, 0));
    const entry = dbById(ctx, argv[0]) orelse return c.JS_ThrowTypeError(ctx, "bad db id", @as(c_int, 0));
    const sql = c.JS_ToCStringLen(ctx, null, argv[1]) orelse return c.JS_ThrowTypeError(ctx, "sql must be string", @as(c_int, 0));
    defer c.JS_FreeCString(ctx, sql);
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const params = (paramsFromJS(ctx, if (argc >= 3) argv[2] else jsUndefConst(), arena_state.allocator()) orelse
        return c.JS_ThrowTypeError(ctx, "params must be array", @as(c_int, 0)));
    var stmt = entry.db.prepare(std.mem.span(sql)) catch {
        return c.JS_ThrowInternalError(ctx, "sqlite prepare failed", @as(c_int, 0));
    };
    defer stmt.deinit();
    const changes = stmt.run(params) catch {
        return c.JS_ThrowInternalError(ctx, "sqlite run failed", @as(c_int, 0));
    };
    return c.JS_NewInt64(ctx, changes);
}

fn jsAll(
    ctx: ?*c.JSContext,
    this_val: c.JSValueConst,
    argc: c_int,
    argv: [*c]const c.JSValueConst,
) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 2) return c.JS_ThrowTypeError(ctx, "sqlite.all(id, sql, params?)", @as(c_int, 0));
    const entry = dbById(ctx, argv[0]) orelse return c.JS_ThrowTypeError(ctx, "bad db id", @as(c_int, 0));
    const sql = c.JS_ToCStringLen(ctx, null, argv[1]) orelse return c.JS_ThrowTypeError(ctx, "sql must be string", @as(c_int, 0));
    defer c.JS_FreeCString(ctx, sql);
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const params = (paramsFromJS(ctx, if (argc >= 3) argv[2] else jsUndefConst(), arena) orelse
        return c.JS_ThrowTypeError(ctx, "params must be array", @as(c_int, 0)));
    var stmt = entry.db.prepare(std.mem.span(sql)) catch {
        return c.JS_ThrowInternalError(ctx, "sqlite prepare failed", @as(c_int, 0));
    };
    defer stmt.deinit();
    const rows = stmt.all(params, arena) catch {
        return c.JS_ThrowInternalError(ctx, "sqlite all failed", @as(c_int, 0));
    };
    const out = c.JS_NewArray(ctx);
    for (rows, 0..) |row, ri| {
        const obj = c.JS_NewObject(ctx);
        for (row.cols) |col| {
            const name_z = std.heap.page_allocator.dupeZ(u8, col.name) catch continue;
            defer std.heap.page_allocator.free(name_z);
            _ = c.JS_SetPropertyStr(ctx, obj, name_z.ptr, valueToJs(ctx, col.value));
        }
        _ = c.JS_SetPropertyUint32(ctx, out, @intCast(ri), obj);
    }
    return out;
}

fn valueToJs(ctx: ?*c.JSContext, v: sqlite_mod.Value) c.JSValue {
    return switch (v) {
        .int => |n| c.JS_NewInt64(ctx, n),
        .real => |f| c.JS_NewFloat64(ctx, f),
        .text => |t| c.JS_NewStringLen(ctx, t.ptr, t.len),
        .null => jsNullConst(),
    };
}

fn jsNullConst() c.JSValue {
    return .{ .u = .{ .ptr = null }, .tag = c.JS_TAG_NULL };
}

fn jsUndefConst() c.JSValue {
    return .{ .u = .{ .int32 = 0 }, .tag = c.JS_TAG_UNDEFINED };
}

fn jsUndefWrap() c.JSValue {
    return jsUndefConst();
}
