//! HTTP/1.1 最小服务（M-3 第三件）—— protocol.md §2.6 桥接语义的纯 Zig 对照。
//! v1：C 套接字薄包装 transport（socket_wrap.c，POSIX 阻塞语义）+ 路由表
//!     （exact/prefix 与 WebRoute kind 对齐）+ 请求解析（16KB 上限）+
//!     Content-Length 响应 + 每请求一连接。
//! 信任栅栏（§2.5）：v1 以 loopback 为受信（简化版）。
//! 验证：`zig build http-smoke-run`（客户端经同一包装自往返）。

const std = @import("std");

pub const c = @cImport({
    @cInclude("socket_wrap.h");
});

pub const Handler = *const fn (ctx: *Server, req: Request, out: *Response) void;
pub const Response = struct {
    status: u16 = 200,
    content_type: []const u8 = "text/plain; charset=utf-8",
    body: []const u8 = "",
    /// keep-alive 语义：true → Connection: keep-alive（连接复用）；false → close
    keep_alive: bool = false,
};

pub const Route = struct {
    exact: bool,
    path: []const u8,
    handler: Handler,
};

pub const Request = struct {
    method: []const u8,
    path: []const u8,
    version: []const u8,
    headers: []const u8,
    body: []const u8 = "",
};

pub const Server = struct {
    listen_fd: c_int = -1,
    routes: []const Route = &.{},

    pub fn listen(port: u16, routes: []const Route) !Server {
        const fd = c.dsh_sock_listen(port);
        if (fd < 0) return error.ListenFailed;
        return Server{ .listen_fd = fd, .routes = routes };
    }

    pub fn close(self: *Server) void {
        if (self.listen_fd >= 0) {
            _ = c.dsh_sock_close(self.listen_fd);
            self.listen_fd = -1;
        }
    }

    pub fn handleOne(self: *Server) !void {
        const conn = c.dsh_sock_accept(self.listen_fd);
        if (conn < 0) return error.AcceptFailed;
        defer _ = c.dsh_sock_close(conn);
        var read_buf: [16 * 1024]u8 = undefined;
        const raw = try readRequest(conn, &read_buf);
        const req = parseRequest(raw);
        var out = Response{};
        if (routeLookup(self.routes, req.path)) |r| {
            r.handler(self, req, &out);
        } else {
            out = .{ .status = 404, .body = "not found" };
        }
        try writeResponse(conn, &out);
    }

    pub fn serve(self: *Server, connections: usize) !void {
        var served: usize = 0;
        while (served < connections) : (served += 1) try self.handleOne();
    }
};

pub fn readRequest(fd: c_int, buf: []u8) ![]u8 {
    var used: usize = 0;
    while (used < buf.len) {
        const n = c.dsh_sock_read(fd, buf[used..].ptr, buf.len - used);
        if (n <= 0) break;
        used += @intCast(n);
        if (std.mem.indexOf(u8, buf[0..used], "\r\n\r\n") != null) break;
    }
    return buf[0..used];
}


pub fn parseRequest(raw: []const u8) Request {
    const line_end = std.mem.indexOf(u8, raw, "\r\n") orelse
        return .{ .method = "", .path = "/", .version = "HTTP/1.1", .headers = "", .body = "" };
    const request_line = raw[0..line_end];
    const header_end = std.mem.indexOf(u8, raw, "\r\n\r\n");
    const headers = if (raw.len > line_end + 2) raw[line_end + 2 .. if (header_end) |he| he else raw.len] else "";
    const body = if (header_end) |he| raw[he + 4 ..] else "";
    var it = std.mem.splitScalar(u8, request_line, ' ');
    const method = it.next() orelse "";
    const path = it.next() orelse "/";
    const version = it.next() orelse "HTTP/1.1";
    return .{ .method = method, .path = path, .version = version, .headers = headers, .body = body };
}

fn routeLookup(routes: []const Route, path: []const u8) ?Route {
    for (routes) |r| {
        if (r.exact) {
            if (std.mem.eql(u8, r.path, path)) return r;
        } else {
            if (std.mem.startsWith(u8, path, r.path)) return r;
        }
    }
    return null;
}

pub fn writeResponse(fd: c_int, res: *const Response) !void {
    var head_buf: [512]u8 = undefined;
    const head = try std.fmt.bufPrint(&head_buf,
        "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: {s}\r\n\r\n",
        .{ res.status, statusText(res.status), res.content_type, res.body.len, if (res.keep_alive) "keep-alive" else "close" });
    _ = c.dsh_sock_write(fd, head.ptr, head.len);
    if (res.body.len > 0) _ = c.dsh_sock_write(fd, res.body.ptr, res.body.len);
}

pub fn statusText(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        404 => "Not Found",
        403 => "Forbidden",
        else => "XXX",
    };
}
