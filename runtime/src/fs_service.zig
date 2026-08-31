//! fs 服务核心（M-3）—— fs-local 语义子集（POSIX；Windows M5）。
//! API 为 std.Io（0.16 新式）：initIo -> cwd 相对/绝对 resolve（词法归一化）、
//! stat/readText/readBytes(上限)/listDir/writeText（原子 tmp+rename）/
//! contains（路径前缀语义）/ processPath（= 内部绝对键）。
//! 沙箱挂钩点：resolve 前经 policy（M-4 接入）；本文件提供路径边界原语。
//! 验证：`zig build fs-smoke-run`。

const std = @import("std");

const sys_c = @cImport({
    @cInclude("sys/stat.h");
});

pub const Kind = enum { file, directory, other };

pub const Info = struct {
    kind: Kind,
    size: u64,
    inode: u64,
    mode: u32,
    mtime_ns: i128,
};

pub const Entry = struct {
    name: []const u8,
    kind: Kind,
    size: u64,
};

pub const Error = error{
    NotFound,
    EntryTooLarge,
    PathOutside,
};

/// 运行时 Io（Threaded / page_allocator；后续换多线程策略时不变 API）
var io_runtime: std.Io.Threaded = undefined;

pub fn initIo() void {
    io_runtime = std.Io.Threaded.init(std.heap.page_allocator, .{});
}

pub fn ioNow() std.Io {
    return std.Io.Threaded.io(&io_runtime);
}
inline fn io() std.Io {
    return ioNow();
}

pub fn errnoKind(kind: @import("std").Io.File.Kind) Kind {
    return switch (kind) {
        .directory => .directory,
        .file => .file,
        else => .other,
    };
}

pub const Fs = struct {
    cwd: []const u8,
    arena: std.mem.Allocator,
    policy: ?*const @import("policy.zig").Policy = null,

    pub fn init(cwd: []const u8, arena: std.mem.Allocator) Fs {
        return .{ .cwd = cwd, .arena = arena };
    }

    pub fn initPoliced(cwd: []const u8, arena: std.mem.Allocator, policy: ?*const @import("policy.zig").Policy) Fs {
        return .{ .cwd = cwd, .arena = arena, .policy = policy };
    }

    /// resolve：相对 -> 绝对（词法归一化：折叠 // 与 /./，处理 /../）。
    /// fs-local 的 realpath-优先语义留待 M-3 收尾（需要 realpath API 同款确认）。
    pub fn resolve(self: Fs, path: []const u8) ![]const u8 {
        if (path.len == 0) return self.cwd;
        const joined = if (std.fs.path.isAbsolute(path))
            path
        else
            (try std.fmt.allocPrint(self.arena, "{s}/{s}", .{ self.cwd, path }));
        return try normalizePath(self.arena, joined);
    }

    pub fn listDir(self: Fs, target: []const u8) ![]Entry {
        const dir = std.Io.Dir.openDirAbsolute(io(), target, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return error.NotFound,
            else => return err,
        };
        var iter = std.Io.Dir.Iterator.init(dir, .reset);
        var out: std.ArrayList(Entry) = .{ .items = &.{}, .capacity = 0 };
        defer out.deinit(self.arena);
        while (try iter.next(io())) |entry| {
            var child_buf: [std.fs.max_path_bytes]u8 = undefined;
            const child = std.fmt.bufPrint(&child_buf, "{s}/{s}", .{ target, entry.name }) catch continue;
            const st = std.Io.Dir.statFile(std.Io.Dir.cwd(), io(), child, .{}) catch null;
            const size: u64 = if (st) |s| s.size else 0;
            const name_owned = try self.arena.dupe(u8, entry.name);
            try out.append(self.arena, .{ .name = name_owned, .kind = errnoKind(entry.kind), .size = size });
        }
        return out.toOwnedSlice(self.arena);
    }

    /// 原子写（tmp + rename；renameAbsolute 已提供跨平台语义）。
    /// policy 挂钩：写前 checkWrite（read_only / workspace_write 边界）。
    pub fn writeText(self: Fs, target: []const u8, content: []const u8) !void {
        if (self.policy) |pol| try pol.checkWrite(target);
        const tmp = try std.fmt.allocPrint(self.arena, "{s}.dsh-tmp", .{target});
        defer self.arena.free(tmp);
        try std.Io.Dir.writeFile(std.Io.Dir.cwd(), io(), .{ .sub_path = tmp, .data = content });
        try std.Io.Dir.renameAbsolute(tmp, target, io());
    }

    /// 读带策略：checkRead 后委托 readText（free fn 无 self，故提供方法形态）
    pub fn readTextPoliced(self: Fs, target: []const u8) ![]u8 {
        if (self.policy) |pol| try pol.checkRead(target);
        return readText(target);
    }

};

/// contains：路径前缀语义（与 fs-local 一致：relative(child,parent) 不以 .. 开头）
pub fn contains(parent: []const u8, child: []const u8) bool {
    // 0.16 的 relative 需分配器；语义按 fs-local：rel 不以 ".." 开头即包含。
    const rel = std.fs.path.relative(std.heap.page_allocator, "", null, parent, child) catch null orelse return false;
    defer std.heap.page_allocator.free(rel);
    return rel.len == 0 or (!std.mem.startsWith(u8, rel, ".."));
}

pub fn stat(target: []const u8) !?Info {
    // libc stat（C 薄包装）：mode/inode/size 全真值（沙箱 sameIdentity 面；
    // std.Io 抽象无 mode——C 直调最稳）。
    const z = try std.heap.page_allocator.dupeZ(u8, target);
    defer std.heap.page_allocator.free(z);
    var st: sys_c.struct_stat = undefined;
    const rc = sys_c.stat(z.ptr, &st);
    if (rc != 0) {
        const errno = std.c._errno().*;
        const e = std.os.linux.E;
        if (errno == @intFromEnum(e.NOENT) or errno == @intFromEnum(e.NOTDIR) or errno == @intFromEnum(e.ACCES)) return null;
        return error.StatFailed;
    }
    const kind: Kind = if ((st.st_mode & sys_c.S_IFDIR) != 0)
        .directory
    else if ((st.st_mode & sys_c.S_IFREG) != 0)
        .file
    else
        .other;
    return Info{
        .kind = kind,
        .size = @intCast(st.st_size),
        .inode = @intCast(st.st_ino),
        .mode = @intCast(st.st_mode & 0o7777),
        .mtime_ns = @as(i128, st.st_mtim.tv_sec) * 1_000_000_000 + st.st_mtim.tv_nsec,
    };
}

/// chmod（mode 真值——writeFileAtomic/DSH 权限语义）。
pub fn chmod(target: []const u8, mode: u32) !void {
    const z = try std.heap.page_allocator.dupeZ(u8, target);
    defer std.heap.page_allocator.free(z);
    const rc = std.os.linux.chmod(z.ptr, @intCast(mode));
    const err = std.os.linux.errno(rc);
    if (err != .SUCCESS) return error.ChmodFailed;
}

/// mkdirp：逐段创建目录（绝对路径；EEXIST 容忍）。纯 syscall（std.os.linux.mkdir）。
pub fn mkdirp(target: []const u8) !void {
    const linux = std.os.linux;
    if (target.len == 0) return;
    var end: usize = 0;
    while (end < target.len) : (end += 1) {
        if (target[end] != '/' and end + 1 != target.len) continue;
        // 段边界（含最后的完整段）
        const seg_end = if (target[end] == '/') end else end + 1;
        if (seg_end <= 1) continue; // root
        const z = std.heap.page_allocator.dupeZ(u8, target[0..seg_end]) catch return error.PathTooLong;
        defer std.heap.page_allocator.free(z);
        const rc = linux.mkdir(z.ptr, 0o755);
        const err = linux.errno(rc);
        switch (err) {
            .SUCCESS => {},
            .EXIST => {},
            else => return error.MkdirFailed,
        }
        if (target[end] == '/' and end + 1 == target.len) break;
    }
}

/// 真实路径（libc realpath(3) 全解析；std.c 绑定）
pub fn realpath(target: []const u8) ![]u8 {
    const z = std.heap.page_allocator.dupeZ(u8, target) catch return error.PathTooLong;
    defer std.heap.page_allocator.free(z);
    var buf: [std.fs.max_path_bytes]u8 = undefined; // 调用方缓冲（[*]u8 不允许零地址——libc NULL 形态被 zig 类型拒绝）
    const c = std.c.realpath(z.ptr, &buf) orelse return error.NotFound;
    return std.heap.page_allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(c)))) catch return error.PathTooLong;
}

/// 重命名（同文件系统内原子；std.c.rename）
pub fn rename(from: []const u8, to: []const u8) !void {
    const a = std.heap.page_allocator.dupeZ(u8, from) catch return error.PathTooLong;
    defer std.heap.page_allocator.free(a);
    const b = std.heap.page_allocator.dupeZ(u8, to) catch return error.PathTooLong;
    defer std.heap.page_allocator.free(b);
    if (std.c.rename(a.ptr, b.ptr) != 0) return error.RenameFailed;
}

/// 删除文件（std.c.unlink；目录删除 v1 不支持）
pub fn remove(target: []const u8) !void {
    const z = std.heap.page_allocator.dupeZ(u8, target) catch return error.PathTooLong;
    defer std.heap.page_allocator.free(z);
    if (std.c.unlink(z.ptr) != 0) return error.RemoveFailed;
}

/// 目录名字列表（readdir 面）
pub fn listNames(target: []const u8) ![][]const u8 {
    const dir = std.Io.Dir.openDirAbsolute(io(), target, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return error.NotFound,
        else => return err,
    };
    var iter = std.Io.Dir.Iterator.init(dir, .reset);
    var out: std.ArrayList([]const u8) = .{ .items = &.{}, .capacity = 0 };
    defer out.deinit(std.heap.page_allocator);
    while (try iter.next(io())) |entry| {
        const name_owned = try std.heap.page_allocator.dupe(u8, entry.name);
        try out.append(std.heap.page_allocator, name_owned);
    }
    return out.toOwnedSlice(std.heap.page_allocator);
}

pub fn readText(target: []const u8) ![]u8 {
    // readText 为自由函数——policy 检查交给调用侧（Fs.method 形态保留在服务层）
    return std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io(), target, std.heap.page_allocator, .unlimited);
}

pub fn readBytes(target: []const u8, max_bytes: usize) ![]u8 {
    return std.Io.Dir.readFileAlloc(
        std.Io.Dir.cwd(),
        io(),
        target,
        std.heap.page_allocator,
        std.Io.Limit.limited(max_bytes),
    );
}

fn normalizePath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    // 简化 POSIX 归一化：/./ -> /, // -> /, /../ -> 弹栈
    var parts: std.ArrayList([]const u8) = .{ .items = &.{}, .capacity = 0 };
    defer parts.deinit(allocator);
    var iter = std.mem.tokenizeScalar(u8, path, '/');
    const absolute = path.len > 0 and path[0] == '/';
    while (iter.next()) |seg| {
        if (std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (parts.items.len > 0) {
                _ = parts.pop();
            }
            continue;
        }
        try parts.append(allocator, seg);
    }
    var out: std.ArrayList(u8) = .{ .items = &.{}, .capacity = 0 };
    defer out.deinit(allocator);
    if (absolute) try out.append(allocator, '/');
    for (parts.items, 0..) |seg, i| {
        if (i > 0) try out.append(allocator, '/');
        try out.appendSlice(allocator, seg);
    }
    if (out.items.len == 0) try out.append(allocator, '/');
    return out.toOwnedSlice(allocator);
}
