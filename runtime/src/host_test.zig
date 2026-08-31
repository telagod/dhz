//! QuickjsHost 契约测试（`zig build test-quickjs`）。
//! 覆盖 seam.HostModuleLoader 契约在 quickjs 后端上的行为：
//!   1) import() 解析并链接真实闭包模块（cosmokit）
//!   2) 同一 host 的第二次 import（known-red 场景：atom 断言）
//!   3) 不同模块（cordis）后 dispose 释放 → deinit 无泄漏断言（哨兵）
//! 每个测试独立 host（rt/ctx 生命周期隔离）。

const std = @import("std");
const host_q = @import("host_quickjs.zig");
const seam = @import("seam.zig");

fn withHost(comptime body: anytype) !void {
    var host = try host_q.QuickjsHost.init();
    defer host.deinit();
    try body(&host);
}

test "import cosmokit -> namespace handle -> dispose" {
    try withHost(struct {
        fn run(h: *host_q.QuickjsHost) !void {
            const ns: seam.ModuleNamespace = try h.import("@deepseek-ai/cosmokit", "", .{});
            try std.testing.expect(@intFromPtr(ns) != 0);
            h.dispose(ns);
        }
    }.run);
}

test "timer plugin import (dep on cordis)" {
    try withHost(struct {
        fn run(h: *host_q.QuickjsHost) !void {
            const ns: seam.ModuleNamespace = try h.import("@deepseek-ai/cordis-plugin-timer", "", .{});
            try std.testing.expect(@intFromPtr(ns) != 0);
            h.dispose(ns);
        }
    }.run);
}

test "package exports resolves declared subpath and rejects private path" {
    try withHost(struct {
        fn run(h: *host_q.QuickjsHost) !void {
            const declared: seam.ModuleNamespace = try h.import("@deepseek-ai/dsh-tool-subagent-report/invariant", "", .{});
            try std.testing.expect(@intFromPtr(declared) != 0);
            h.dispose(declared);

            var rejected = false;
            _ = h.import("@deepseek-ai/dsh-tool-subagent-report/private", "", .{}) catch {
                rejected = true;
            };
            try std.testing.expect(rejected);
        }
    }.run);
}

test "second import on same host (known-red regeneration)" {
    try withHost(struct {
        fn run(h: *host_q.QuickjsHost) !void {
            const ns1: seam.ModuleNamespace = try h.import("@deepseek-ai/cosmokit", "", .{});
            h.dispose(ns1);
            // 同一 host 上的第二次 import（此前触发 atom 断言）：
            const ns2: seam.ModuleNamespace = try h.import("@deepseek-ai/cosmokit", "", .{});
            try std.testing.expect(@intFromPtr(ns2) != 0);
            h.dispose(ns2);
            // 第三个不同模块
            const ns3: seam.ModuleNamespace = try h.import("@deepseek-ai/cordis", "", .{});
            try std.testing.expect(@intFromPtr(ns3) != 0);
            h.dispose(ns3);
        }
    }.run);
}
