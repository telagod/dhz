//! sqlite DatabaseSync shim 契约测试（`zig build test-sqlite`）。
//! 覆盖 DSH 使用面：open(journal+busy) / exec(PRAGMA) / prepare /
//! get/all（位置参数）/ run 返回值 / close。

const std = @import("std");
const shim = @import("sqlite_shim.zig");

pub fn runSuite() !void {
    try rawProbe();
    try shimRoundtrip();
}

pub fn runRawProbe() !void {
    try rawProbe();
}

fn rawProbe() !void {
    const raw = @import("raw_probe.zig");
    try raw.probe();
}

fn shimRoundtrip() !void {

    var arena_test = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_test.deinit();
    const a = arena_test.allocator();

    var db = try shim.Database.open(":memory:", "wal", 1000);
    defer db.close();

    try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT NOT NULL, n INTEGER)");
    try db.exec("PRAGMA foreign_keys = ON");
    try db.exec("PRAGMA synchronous = FULL");

    // 插入：位置参数
    var ins = try db.prepare("INSERT INTO t (name, n) VALUES (?, ?)");
    defer ins.deinit();
    const c1 = try ins.run(&.{ .{ .text = "alpha" }, .{ .int = 40 } });
    try std.testing.expectEqual(@as(i64, 1), c1);
    const c2 = try ins.run(&.{ .{ .text = "beta" }, .{ .int = 2 } });
    try std.testing.expectEqual(@as(i64, 1), c2);

    // get：唯一行对象（列名访问，与 node:sqlite 语义一致）
    var sel = try db.prepare("SELECT name, n FROM t WHERE name = ?");
    defer sel.deinit();
    const row = (try sel.get(&.{.{ .text = "alpha" }}, a)).?;

    try std.testing.expectEqualStrings("alpha", row.get("name").?.text);
    try std.testing.expectEqual(@as(i64, 40), row.get("n").?.int);

    // 无参 get：DSH select-store-id 形态
    var sel2 = try db.prepare("SELECT count(*) AS count FROM t");
    defer sel2.deinit();
    const count = (try sel2.get(shim.Param.none(), a)).?;
    try std.testing.expectEqual(@as(i64, 2), count.get("count").?.int);

    // all：多行
    var sel3 = try db.prepare("SELECT name FROM t ORDER BY n");
    defer sel3.deinit();
    const rows = try sel3.all(shim.Param.none(), a);
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualStrings("beta", rows[0].get("name").?.text);

    // NULL 参数
    var ins2 = try db.prepare("INSERT INTO t (name, n) VALUES (?, ?)");
    defer ins2.deinit();
    _ = try ins2.run(&.{ .{ .text = "empty" }, .null });
    var sel4 = try db.prepare("SELECT n FROM t WHERE name = ?");
    defer sel4.deinit();
    const nullrow = (try sel4.get(&.{.{ .text = "empty" }}, a)).?;
    try std.testing.expect(nullrow.get("n").? == .null);
}

test "shim suite" {
    try runSuite();
}
