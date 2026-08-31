//! 适配器契约测试（`zig build test-adapter`）：
//! seam.ModuleHost 聚合（resolve → releaseResolved → evaluate → dispose）三步走，
//! 覆盖 cordis / timer 插件 / builtin 三形态。deinit 后无泄漏断言（哨兵）。
const std = @import("std");
const adapter = @import("loader_adapter.zig");
const seam = @import("seam.zig");

test "ModuleHost.import cordis -> namespace -> dispose" {
    const act = try adapter.Adapter.init();
    defer act.deinit();
    const ns: seam.ModuleNamespace = try act.module_host.import("@deepseek-ai/cordis", "", .{ .type = null });
    try std.testing.expect(@intFromPtr(ns) != 0);
    act.module_host.disposeFn(&act.module_host, ns);
}

test "ModuleHost.import timer plugin + builtin path + dispose" {
    const act = try adapter.Adapter.init();
    defer act.deinit();
    const ns1: seam.ModuleNamespace = try act.module_host.import("@deepseek-ai/cordis-plugin-timer", "", .{ .type = null });
    try std.testing.expect(@intFromPtr(ns1) != 0);
    act.module_host.disposeFn(&act.module_host, ns1);
    const ns2: seam.ModuleNamespace = try act.module_host.import("node:path", "", .{ .type = null });
    try std.testing.expect(@intFromPtr(ns2) != 0);
    act.module_host.disposeFn(&act.module_host, ns2);
}

test "resolve rejects unknown specifier" {
    const act = try adapter.Adapter.init();
    defer act.deinit();
    const r = act.module_host.resolveFn(&act.module_host, "@deepseek-ai/no-such-pkg", "", .{ .type = null });
    try std.testing.expectError(error.Unresolved, r);
}
