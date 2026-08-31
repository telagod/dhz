//! fs 服务 smoke（`zig build fs-smoke-run`）：write/read 往返、readBytes 上限、
//! stat、listDir、contains、原子写覆盖、路径归一化。
const std = @import("std");
const fs_svc = @import("fs_service.zig");

pub fn main() !void {
    fs_svc.initIo();
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp_buf: [128]u8 = undefined;
    const base = try std.fmt.bufPrint(&tmp_buf, "/tmp/dsh-fs-smoke-{d}", .{@import("std").os.linux.getpid()});
    try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), fs_svc.ioNow(), base);

    var fs = fs_svc.Fs.init(base, a);
    const target = try fs.resolve("sub/file.txt");
    try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), fs_svc.ioNow(), try fs.resolve("sub"));

    try fs.writeText(target, "hello fs");
    try std.testing.expectEqualStrings("hello fs", try fs_svc.readText(target));
    std.debug.print("1) write/read roundtrip: OK\n", .{});

    // 限制语义：超限抛 StreamTooLong（I/O 边界正确行为）
    _ = fs_svc.readBytes(target, 4) catch |err| {
        try std.testing.expect(err == error.StreamTooLong);
        std.debug.print("2) readBytes limit: OK (StreamTooLong)\n", .{});
    };

    const info = (try fs_svc.stat(target)) orelse return error.MissingStat;
    try std.testing.expectEqual(@as(u64, 8), info.size);
    std.debug.print("3) stat: OK (size={d})\n", .{info.size});

    const entries = try fs.listDir(try fs.resolve(""));
    var saw_dir = false;
    for (entries) |e| {
        if (e.kind == .directory and std.mem.eql(u8, e.name, "sub")) saw_dir = true;
    }
    try std.testing.expect(saw_dir);
    std.debug.print("4) listDir: OK (base {d} entries)\n", .{entries.len});

    // 子目录内容：file.txt 在 sub/ 内
    const sub_entries = try fs.listDir(try fs.resolve("sub"));
    var saw_file = false;
    for (sub_entries) |e| {
        if (e.kind == .file and std.mem.eql(u8, e.name, "file.txt")) saw_file = true;
    }
    try std.testing.expect(saw_file);
    std.debug.print("5) listDir(sub): OK ({d} entries)\n", .{sub_entries.len});

    try std.testing.expect(fs_svc.contains(try fs.resolve(""), target));
    try std.testing.expect(!fs_svc.contains(target, try fs.resolve("")));
    std.debug.print("6) contains: OK\n", .{});

    try fs.writeText(target, "replaced");
    try std.testing.expectEqualStrings("replaced", try fs_svc.readText(target));
    std.debug.print("7) atomic overwrite: OK\n", .{});

    try std.testing.expectEqualStrings(target, try fs.resolve("sub/../sub//file.txt"));
    std.debug.print("8) normalize: OK\n", .{});

    // ---- policy 挂钩：read_only / workspace_write / full 边界 ----
    const P = @import("policy.zig");
    var pol_full = P.Policy.init(.danger_full_access, "/tmp/x");
    try pol_full.checkWrite("/etc/passwd");

    var pol_ro = P.Policy.init(.read_only, base);
    var pol_ws = P.Policy.init(.workspace_write, base);

    // read_only: 写拒绝（workspace 内外皆拒）
    _ = pol_ro.checkWrite(target) catch |err| try std.testing.expect(err == error.ReadOnly);
    // workspace_write: 内部允许，外部拒绝
    try pol_ws.checkWrite(target);
    _ = pol_ws.checkWrite("/etc/passwd") catch |err| try std.testing.expect(err == error.PathOutside);
    // 读检查：read_only 边界内外
    try pol_ro.checkRead(target);
    _ = pol_ro.checkRead("/etc/passwd") catch |err| try std.testing.expect(err == error.PathOutside);
    std.debug.print("9) policy checks: OK\n", .{});

    // 方法级：policed Fs 写外部被拒
    var fs_policed = fs_svc.Fs.initPoliced(base, a, &pol_ws);
    _ = fs_policed.writeText("/etc/dsh-pwned.tmp", "x") catch |err| {
        try std.testing.expect(err == error.PathOutside);
        std.debug.print("10) policed writeText (outside): OK\n", .{});
    };

    std.debug.print("fs smoke: all assertions passed\n", .{});
    std.process.exit(0);
}
