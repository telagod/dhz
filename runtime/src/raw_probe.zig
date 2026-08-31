//! 纯 C 探针的 zig 直译：不做 shim bind/readRow，验证 zig 绑定层 vs C 的差异。
const std = @import("std");
const c = @cImport({ @cInclude("sqlite3.h"); @cInclude("sqlite_wrap.h"); });

pub fn probe() !void {
    var db: ?*c.sqlite3 = null;
    const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE;
    try std.testing.expect(c.sqlite3_open_v2(":memory:", &db, flags, null) == c.SQLITE_OK);

    try std.testing.expect(c.sqlite3_exec(db, "CREATE TABLE t (name TEXT)", null, null, null) == c.SQLITE_OK);
    var ins: ?*c.sqlite3_stmt = null;
    try std.testing.expect(c.sqlite3_prepare_v2(db, "INSERT INTO t (name) VALUES (?)", -1, &ins, null) == c.SQLITE_OK);

    var alpha: [5]u8 = .{ 'a', 'l', 'p', 'h', 'a' };
    // 与 shim 相同的 dupeZ+TRANSIENT 模式
    const z = try std.heap.page_allocator.dupeZ(u8, "alpha");
    defer std.heap.page_allocator.free(z);
    const rc0 = c.sqlite3_bind_text(ins, 1, z.ptr, 5, c.SQLITE_TRANSIENT);
    try std.testing.expect(rc0 == c.SQLITE_OK);
    try std.testing.expect(c.sqlite3_step(ins) == c.SQLITE_DONE);

    var sel: ?*c.sqlite3_stmt = null;
    try std.testing.expect(c.sqlite3_prepare_v2(db, "SELECT name FROM t", -1, &sel, null) == c.SQLITE_OK);
    try std.testing.expect(c.sqlite3_step(sel) == c.SQLITE_ROW);
    const p = c.dsh_col_text(sel, 0) orelse return error.NullText;
    const n = @as(usize, @intCast(c.dsh_col_bytes(sel, 0)));
    std.debug.print("[raw] n={d} bytes: ", .{n});
    for (p[0..n]) |b| std.debug.print("{d} ", .{b});
    std.debug.print("\\n", .{});

    _ = &alpha;
}
