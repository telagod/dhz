//! 信任栅栏 smoke（`zig build trust-fence-smoke-run`）：
//! api-request-trust.host.spec.ts 官方用例逐一移植断言（纯 Zig，无引擎）。
const std = @import("std");
const tf = @import("trust_fence.zig");

var passed: usize = 0;
var failed: usize = 0;

fn check(name: []const u8, got: bool, want: bool) void {
    if (got == want) {
        passed += 1;
    } else {
        failed += 1;
        std.debug.print("  FAIL: {s}: got={} want={}\n", .{ name, got, want });
    }
}

fn trust(host: ?[]const u8, sec: ?[]const u8, origin: ?[]const u8, hosts: []const []const u8) bool {
    return tf.isTrustedApiRequest(host, sec, origin, hosts);
}

pub fn main() !void {
    // ---- spec: isTrustedApiRequest ----
    // markerless 请求同样过 Host 栅栏
    check("markerless 127.0.0.1:3080", trust("127.0.0.1:3080", null, null, &.{}), true);
    check("markerless 192.168.1.5 + trusted", trust("192.168.1.5:3080", null, null, &.{"192.168.1.5"}), true);
    check("markerless 192.168.1.5 无 trusted", trust("192.168.1.5:3080", null, null, &.{}), false);
    check("harness.example", trust("harness.example", null, null, &.{}), false);
    check("无 host", trust(null, null, null, &.{}), false);

    // loopback 各种拼写 + origin
    for ([_][]const u8{
        "localhost", "localhost:3080", "127.0.0.1", "127.0.0.1:3080", "127.8.9.10:80", "[::1]", "[::1]:3080", "LOCALHOST:3080",
    }) |h| {
        const o = std.fmt.allocPrint(std.heap.page_allocator, "http://{s}", .{h}) catch unreachable;
        defer std.heap.page_allocator.free(o);
        check(std.fmt.allocPrint(std.heap.page_allocator, "loopback {s}", .{h}) catch unreachable, trust(h, null, o, &.{}), true);
    }

    // 反弹 Host 拒绝
    check("rebound evil.example", trust("evil.example:3080", "same-origin", "http://evil.example:3080", &.{}), false);

    // trusted 条目语义：exact 端口 / 任意端口 / 错误端口
    const th = "harness.internal:3080";
    check("trusted exact", trust(th, null, "http://harness.internal:3080", &.{th}), true);
    check("trusted portless", trust(th, null, "http://harness.internal:3080", &.{"harness.internal"}), true);
    check("trusted wrong port", trust(th, null, "http://harness.internal:3080", &.{"harness.internal:9999"}), false);
    check("trusted empty list", trust(th, null, "http://harness.internal:3080", &.{}), false);

    // WHATWG 归一：大小写 / 默认端口
    check("case normalize", trust("Harness.INTERNAL:3080", null, "http://harness.internal:3080", &.{"harness.internal:3080"}), true);
    check("default port 80", trust("harness.internal", null, "http://harness.internal", &.{"HARNESS.internal:80"}), true);
    check("bad entry no poison", trust("harness.internal", null, "http://harness.internal", &.{ "bad entry", "harness.internal" }), true);
    check("bad entry only", trust("harness.internal", null, "http://harness.internal", &.{"bad entry"}), false);

    // 跨界标记在 loopback 上仍拒绝
    check("cross origin", trust("127.0.0.1:3080", null, "http://evil.example", &.{}), false);
    check("cross-site label", trust("127.0.0.1:3080", "cross-site", null, &.{}), false);
    check("opaque null origin", trust("127.0.0.1:3080", null, "null", &.{}), false);

    // 同源浏览器请求（带/不带 Origin）
    check("same origin", trust("localhost:3080", "same-origin", "http://localhost:3080", &.{}), true);
    check("no origin but sec-fetch", trust("localhost:3080", "same-origin", null, &.{}), true);

    // ---- spec: assertTrustedAuthority ----
    for ([_][]const u8{ "harness.internal", "harness.internal:3080", "HARNESS.internal:80", "10.0.0.9", "[::1]:3080" }) |e| {
        check(std.fmt.allocPrint(std.heap.page_allocator, "assert accept {s}", .{e}) catch unreachable, tf.assertTrustedAuthority(e), true);
    }
    for ([_][]const u8{ "harness.internal/path", "harness.internal/", "user@harness.internal", "harness.internal?x", "harness.internal#f", "harness.internal\\path", "bad entry", "" }) |e| {
        check(std.fmt.allocPrint(std.heap.page_allocator, "assert reject {s}", .{e}) catch unreachable, tf.assertTrustedAuthority(e), false);
    }
    for ([_][]const u8{ "harness.internal:3080 ", " harness.internal", "harness.internal:30\t80" }) |e| {
        check(std.fmt.allocPrint(std.heap.page_allocator, "assert reject ws {s}", .{e}) catch unreachable, tf.assertTrustedAuthority(e), false);
    }
    for ([_][]const u8{ "harness.internal:", "[::1]:", "harness.internal:0080", "0x7f.0.0.1", "[0:0:0:0:0:0:0:1]" }) |e| {
        check(std.fmt.allocPrint(std.heap.page_allocator, "assert reject malformed {s}", .{e}) catch unreachable, tf.assertTrustedAuthority(e), false);
    }

    // 尾随空格不拓宽端口授权
    check("trim stays exact 9999", trust("harness.internal:9999", null, "http://harness.internal:9999", &.{"harness.internal:3080 "}), false);
    check("trim stays exact 3080", trust("harness.internal:3080", null, "http://harness.internal:3080", &.{"harness.internal:3080 "}), true);

    // 畸形/非受信 host 拒绝
    check("markers no host", trust(null, "same-origin", null, &.{}), false);
    check("empty host", trust("", "same-origin", null, &.{}), false);
    check("bad host space", trust("bad host", "same-origin", null, &.{}), false);
    check("127.0.0.999", trust("127.0.0.999", "same-origin", null, &.{}), false);
    check("128.0.0.1", trust("128.0.0.1", "same-origin", null, &.{}), false);

    std.debug.print("trust fence smoke: passed={d} failed={d}\n", .{ passed, failed });
    if (failed != 0) return error.SpecMismatch;
    std.debug.print("trust fence smoke OK: api-request-trust.host.spec.ts semantics ported\n", .{});
}
