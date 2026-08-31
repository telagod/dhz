//! sqlite shim smoke runner（绕过 zig 0.16 test-runner listen 协议问题，
//! 直接模式运行：`zig build sqlite-smoke-run`）。
const std = @import("std");
const suite = @import("sqlite_test.zig");

pub fn main() !void {
    try suite.runSuite();
    std.debug.print("sqlite smoke: all assertions passed\\n", .{});
    std.process.exit(0);
}
