//! crypto 服务桥—— guest 经 dshServices.crypto 使用真实哈希：
//!   sha256(text) -> hex（SHA-256 自实现，FIPS 180-4 参考结构，零依赖）
//! node:crypto 的 createHash stub 对接本服务（真实语义；形变版退役）。
//! 验证：`zig build crypto-smoke-run`。

const std = @import("std");
const hs = @import("host_services.zig");

pub const c = @import("engine_c.zig").c;

const hash_c = @cImport({
    @cInclude("hash_wrap.h");
});

pub const serviceMethods = [_]hs.Method{
    .{ .name = "sha256", .func = jsSha256, .length = 1 },
    .{ .name = "sha1", .func = jsSha1, .length = 1 },
    .{ .name = "randomUUID", .func = jsRandomUUID, .length = 0 },
};

/// SHA-1（WS Accept 基元——RFC 6455；hex 输出）。
fn jsSha1(
    ctx: ?*c.JSContext,
    this_val: c.JSValueConst,
    argc: c_int,
    argv: [*c]const c.JSValueConst,
) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 1) return c.JS_ThrowTypeError(ctx, "crypto.sha1(text)", @as(c_int, 0));
    var slen: usize = 0;
    const s = c.JS_ToCStringLen(ctx, &slen, argv[0]) orelse return c.JS_ThrowTypeError(ctx, "text must be string", @as(c_int, 0));
    defer c.JS_FreeCString(ctx, s);
    var digest: [20]u8 = undefined;
    hash_c.dsh_sha1(s[0..slen].ptr, slen, &digest);
    const hex = "0123456789abcdef";
    var hex_buf: [40]u8 = undefined;
    for (digest, 0..) |b, i| {
        hex_buf[i * 2] = hex[b >> 4];
        hex_buf[i * 2 + 1] = hex[b & 0xf];
    }
    return c.JS_NewStringLen(ctx, &hex_buf, hex_buf.len);
}

/// 真实随机 UUID v4（libc getrandom；hex 格式化 8-4-4-4-12）。
fn jsRandomUUID(
    ctx: ?*c.JSContext,
    this_val: c.JSValueConst,
    argc: c_int,
    argv: [*c]const c.JSValueConst,
) callconv(.c) c.JSValue {
    _ = this_val;
    _ = argc;
    _ = argv;
    var buf: [16]u8 = undefined;
    const rc = std.c.getrandom(&buf, buf.len, 0);
    if (rc != buf.len) return c.JS_ThrowInternalError(ctx, "crypto.randomUUID: getrandom failed", @as(c_int, 0));
    buf[6] = (buf[6] & 0x0f) | 0x40; // version 4
    buf[8] = (buf[8] & 0x3f) | 0x80; // variant 10
    const hex = "0123456789abcdef";
    var out: [36]u8 = undefined;
    var oi: usize = 0;
    for (buf, 0..) |b, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            out[oi] = '-';
            oi += 1;
        }
        out[oi] = hex[b >> 4];
        out[oi + 1] = hex[b & 0xf];
        oi += 2;
    }
    return c.JS_NewStringLen(ctx, &out, out.len);
}

fn jsSha256(
    ctx: ?*c.JSContext,
    this_val: c.JSValueConst,
    argc: c_int,
    argv: [*c]const c.JSValueConst,
) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 1) return c.JS_ThrowTypeError(ctx, "crypto.sha256(text)", @as(c_int, 0));
    var slen: usize = 0;
    const s = c.JS_ToCStringLen(ctx, &slen, argv[0]) orelse return c.JS_ThrowTypeError(ctx, "text must be string", @as(c_int, 0));
    defer c.JS_FreeCString(ctx, s);
    const text = s[0..slen];
    var digest: [32]u8 = undefined;
    hash_c.dsh_sha256(text.ptr, text.len, &digest);
    // hex
    var hex_buf: [64]u8 = undefined;
    const hex = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        hex_buf[i * 2] = hex[b >> 4];
        hex_buf[i * 2 + 1] = hex[b & 0xf];
    }
    return c.JS_NewStringLen(ctx, &hex_buf, hex_buf.len);
}
