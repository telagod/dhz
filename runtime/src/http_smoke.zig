//! HTTP 服务 smoke（`zig build http-smoke-run`）：客户端经同一 C 包装运输层
//! 自往返——/echo（200）、/api 前缀（JSON stub）、/secret 403、/nope 404。
const std = @import("std");
const http = @import("http_server.zig");

const c = @cImport({
    @cInclude("socket_wrap.h");
});

fn echoHandler(_: *http.Server, _: http.Request, out: *http.Response) void {
    out.* = .{ .body = "echo v1" };
}

fn apiHandler(_: *http.Server, _: http.Request, out: *http.Response) void {
    out.* = .{ .content_type = "application/json; charset=utf-8", .body = "{\"ok\":true,\"service\":\"api-gateway-stub\"}" };
}

fn guardedHandler(_: *http.Server, _: http.Request, out: *http.Response) void {
    out.* = .{ .status = 403, .body = "forbidden" };
}

pub fn main() !void {
    const port: u16 = 32600 + @as(u16, @intCast(@mod(@import("std").os.linux.getpid(), 512)));
    const routes = [_]http.Route{
        .{ .exact = true, .path = "/echo", .handler = echoHandler },
        .{ .exact = false, .path = "/api", .handler = apiHandler },
        .{ .exact = false, .path = "/secret", .handler = guardedHandler },
    };
    var server = try http.Server.listen(port, &routes);
    defer server.close();

    const r1 = try roundTrip(port, "GET /echo HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", &server);
    try std.testing.expect(std.mem.indexOf(u8, r1, "200 OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, r1, "echo v1") != null);
    std.debug.print("http smoke: /echo OK\n", .{});

    const r2 = try roundTrip(port, "GET /api/health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", &server);
    try std.testing.expect(std.mem.indexOf(u8, r2, "api-gateway-stub") != null);
    std.debug.print("http smoke: /api prefix OK\n", .{});

    const r3 = try roundTrip(port, "GET /secret/x HTTP/1.1\r\nHost: evil.example\r\n\r\n", &server);
    try std.testing.expect(std.mem.indexOf(u8, r3, "403") != null);
    std.debug.print("http smoke: /secret 403 OK\n", .{});

    const r4 = try roundTrip(port, "GET /nope HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", &server);
    try std.testing.expect(std.mem.indexOf(u8, r4, "404") != null);
    std.debug.print("http smoke: 404 fallback OK\n", .{});

    std.debug.print("http smoke: all assertions passed\n", .{});
    std.process.exit(0);
}

fn roundTrip(port: u16, request: []const u8, server: *http.Server) ![]const u8 {
    const fd = c.dsh_sock_connect(port);
    if (fd < 0) return error.ConnectFailed;
    defer _ = c.dsh_sock_close(fd);
    const written = c.dsh_sock_write(fd, request.ptr, request.len);
    if (written != @as(c_long, @intCast(request.len))) return error.WriteFailed;
    try server.handleOne();
    var buf: [8192]u8 = undefined;
    var used: usize = 0;
    while (used < buf.len) {
        const n = c.dsh_sock_read(fd, buf[used..].ptr, buf.len - used);
        if (n <= 0) break;
        used += @intCast(n);
    }
    return buf[0..used];
}
