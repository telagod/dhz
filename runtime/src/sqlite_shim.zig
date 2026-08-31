//! sqlite DatabaseSync shim（M-3）—— 镜像 @deepseek-ai/dsh 的 node:sqlite 使用面：
//!   open(path/journal/busy_timeout) / exec(sql) / prepare(sql) ->
//!   Statement{ get(params)?, all(params), run(params) } / close
//! 位置参数绑定（DSH 全部使用 '?' 位置参数；无命名参数）。
//! vendor: sqlite-amalgamation-3530400（https://sqlite.org/download.html）。

const std = @import("std");

const c = @cImport({
    @cInclude("sqlite3.h");
    @cInclude("sqlite_wrap.h");
});

pub const Error = error{
    OpenFailed,
    ExecFailed,
    PrepareFailed,
    BindFailed,
    StepFailed,
    NotADatabase,
};

pub const Param = union(enum) {
    int: i64,
    text: []const u8,
    null,

    pub fn none() []const Param {
        return &.{};
    }
};

pub const Value = union(enum) {
    int: i64,
    real: f64,
    text: []const u8,
    null,
};

pub const Column = struct {
    name: []const u8,
    value: Value,
};

pub const Row = struct {
    /// column name -> value；name 指向 sqlite3_column_name 生命周期（valid until finalize）
    cols: []const Column,

    pub fn get(self: *const Row, name: []const u8) ?Value {
        for (self.cols) |col| {
            if (std.mem.eql(u8, col.name, name)) return col.value;
        }
        return null;
    }
};

pub const Database = struct {
    handle: ?*c.sqlite3 = null,

    pub fn open(path: []const u8, journal: []const u8, busy_timeout_ms: i32) Error!Database {
        const z = std.heap.page_allocator.dupeZ(u8, path) catch return error.OpenFailed;
        defer std.heap.page_allocator.free(z);
        var db: ?*c.sqlite3 = null;
        const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX;
        if (c.sqlite3_open_v2(z.ptr, &db, flags, null) != c.SQLITE_OK) {
            if (db) |d| _ = c.sqlite3_close(d);
            return error.OpenFailed;
        }
        _ = c.sqlite3_busy_timeout(db, busy_timeout_ms);
        var self = Database{ .handle = db };
        var pragma_buf: [64]u8 = undefined;
        const pragma = std.fmt.bufPrint(&pragma_buf, "PRAGMA journal_mode={s}", .{journal}) catch return error.ExecFailed;
        try self.exec(pragma);
        return self;
    }

    pub fn exec(self: *Database, sql: []const u8) Error!void {
        const z = std.heap.page_allocator.dupeZ(u8, sql) catch return error.ExecFailed;
        defer std.heap.page_allocator.free(z);
        var errmsg: [*c]u8 = null;
        if (c.sqlite3_exec(self.handle, z.ptr, null, null, &errmsg) != c.SQLITE_OK) {
            if (errmsg != null) c.sqlite3_free(errmsg);
            return error.ExecFailed;
        }
    }

    pub fn prepare(self: *Database, sql: []const u8) Error!Statement {
        const z = std.heap.page_allocator.dupeZ(u8, sql) catch return error.PrepareFailed;
        defer std.heap.page_allocator.free(z);
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, z.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.PrepareFailed;
        return Statement{ .handle = stmt, .db = self };
    }

    pub fn close(self: *Database) void {
        if (self.handle) |db| {
            _ = c.sqlite3_close(db);
            self.handle = null;
        }
    }
};

pub const Statement = struct {
    handle: ?*c.sqlite3_stmt,
    db: *Database,

    pub fn bind(self: *Statement, params: []const Param) Error!void {
        if (self.handle == null) return error.StepFailed;
        var i: usize = 0;
        for (params) |p| {
            i += 1;
            const idx: c_int = @intCast(i);
            const rc = switch (p) {
                .int => |v| c.sqlite3_bind_int64(self.handle, idx, v),
                .text => |t| blk: {
                    const z = std.heap.page_allocator.dupeZ(u8, t) catch break :blk c.SQLITE_NOMEM;
                    defer std.heap.page_allocator.free(z);
                    break :blk c.sqlite3_bind_text(self.handle, idx, z.ptr, @intCast(t.len), c.SQLITE_TRANSIENT);
                },
                .null => c.sqlite3_bind_null(self.handle, idx),
            };
            if (rc != c.SQLITE_OK) return error.BindFailed;
        }
    }

    fn reset(self: *Statement) void {
        _ = c.sqlite3_reset(self.handle);
        _ = c.sqlite3_clear_bindings(self.handle);
    }

    /// 当前行 -> Row（列名借用 statement 生命周期）
    /// 行读取：列名与 TEXT 值均**拷贝**到调用方 allocator —— sqlite 列内存
    /// 在 step/reset 后即失效，直接引用是悬垂（本轮已踩）。
    fn readRow(self: *Statement, allocator: std.mem.Allocator, out: *std.ArrayList(Row)) !void {
        const ncols = c.sqlite3_column_count(self.handle);
        const cols = try allocator.alloc(Column, @intCast(ncols));
        var i: c_int = 0;
        while (i < ncols) : (i += 1) {
            const name_c = c.dsh_col_name(self.handle, i);
            const name: []const u8 = if (name_c == null)
                ""
            else
                try allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(name_c))));
            const value: Value = switch (c.sqlite3_column_type(self.handle, i)) {
                c.SQLITE_INTEGER => .{ .int = c.sqlite3_column_int64(self.handle, i) },
                c.SQLITE_FLOAT => .{ .real = c.sqlite3_column_double(self.handle, i) },
                c.SQLITE_TEXT => blk: {
                    const p = c.dsh_col_text(self.handle, i) orelse break :blk .null;
                    const len: usize = @intCast(c.dsh_col_bytes(self.handle, i));
                    break :blk .{ .text = try allocator.dupe(u8, @as([*]const u8, @ptrCast(p))[0..len]) };
                },
                else => .null,
            };
            cols[@intCast(i)] = .{ .name = name, .value = value };
        }
        try out.append(allocator, .{ .cols = cols });
    }

    /// 返回唯一行（无行 -> null）。行内存由调用方 allocator 分配（arena 最合适）。
    pub fn get(self: *Statement, params: []const Param, allocator: std.mem.Allocator) !?Row {
        try self.bind(params);
        const rc = c.sqlite3_step(self.handle);
        const out = switch (rc) {
            c.SQLITE_ROW => blk: {
                var rows: std.ArrayList(Row) = .{ .items = &.{}, .capacity = 0 };
                try self.readRow(allocator, &rows);
                break :blk rows.items[0];
            },
            c.SQLITE_DONE => null,
            else => return error.StepFailed,
        };
        self.reset();
        return out;
    }

    /// 返回全部行。
    pub fn all(self: *Statement, params: []const Param, allocator: std.mem.Allocator) ![]Row {
        try self.bind(params);
        var rows: std.ArrayList(Row) = .{ .items = &.{}, .capacity = 0 };
        defer rows.deinit(allocator);
        while (true) {
            const rc = c.sqlite3_step(self.handle);
            switch (rc) {
                c.SQLITE_ROW => try self.readRow(allocator, &rows),
                c.SQLITE_DONE => break,
                else => return error.StepFailed,
            }
        }
        self.reset();
        return rows.toOwnedSlice(allocator);
    }

    pub fn run(self: *Statement, params: []const Param) !i64 {
        try self.bind(params);
        if (c.sqlite3_step(self.handle) != c.SQLITE_DONE) return error.StepFailed;
        const changes = c.sqlite3_changes(self.db.handle);
        self.reset();
        return changes;
    }

    pub fn deinit(self: *Statement) void {
        if (self.handle) |s| {
            _ = c.sqlite3_finalize(s);
            self.handle = null;
        }
    }
};
