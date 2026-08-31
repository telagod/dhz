//! sandbox 策略（M-4 文档 §4.8）—— fs 写口的边界挂钩。
//! 语义对齐 dsh-sandbox-policy 的三种模式：
//!   read_only          —— 拒绝一切写；读限 workspace 内
//!   workspace_write    —— 写限 workspace 内；读限 workspace 内
//!   danger_full_access —— 不限制（部署显式选择）
//! 附加钩子： confine argv（landlock/seccomp 预留，M-4 接 landlock-run）。

const std = @import("std");

pub const Mode = enum {
    read_only,
    workspace_write,
    danger_full_access,

    pub fn parse(s: []const u8) ?Mode {
        if (std.mem.eql(u8, s, "read-only") or std.mem.eql(u8, s, "read_only")) return .read_only;
        if (std.mem.eql(u8, s, "workspace-write") or std.mem.eql(u8, s, "workspace_write")) return .workspace_write;
        if (std.mem.eql(u8, s, "danger-full-access") or std.mem.eql(u8, s, "danger_full_access")) return .danger_full_access;
        return null;
    }
};

pub const Policy = struct {
    mode: Mode,
    workspace_root: []const u8,

    pub fn init(mode: Mode, workspace_root: []const u8) Policy {
        return .{ .mode = mode, .workspace_root = workspace_root };
    }

    /// 读检查（同目录前缀语义；full 放行一切）
    pub fn checkRead(self: Policy, path: []const u8) !void {
        if (self.mode == .danger_full_access) return;
        if (!isInside(self.workspace_root, path)) return error.PathOutside;
    }

    /// 写检查：read_only 拒绝一切；workspace_write 限 workspace 内
    pub fn checkWrite(self: Policy, path: []const u8) !void {
        switch (self.mode) {
            .read_only => return error.ReadOnly,
            .workspace_write => {
                if (!isInside(self.workspace_root, path)) return error.PathOutside;
            },
            .danger_full_access => return,
        }
    }

    /// 子进程 confine 预留：返回 argv 前置集（M-4 接 landlock-run CLI 契约）
    pub fn confineArgv(self: Policy, argv_base: []const []const u8, arena: std.mem.Allocator) ![]const []const u8 {
        _ = self;
        _ = arena;
        return argv_base;
    }
};

/// workspace 前缀语义：child 在 root 内（含 root 自身）
pub fn isInside(root: []const u8, child: []const u8) bool {
    if (std.mem.eql(u8, root, child)) return true;
    if (!std.mem.startsWith(u8, child, root)) return false;
    return child.len > root.len and child[root.len] == '/';
}
