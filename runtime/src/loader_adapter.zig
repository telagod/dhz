//! HostModuleLoader 适配器骨架（M-5 第一件）—— seam.ModuleHost 契约 ↔ QuickjsHost。
//! resolve（纯解析：表直查 / <pkg>/index.js / node: builtin stub）
//! → evaluate（引擎动态 import → namespace 句柄）→ dispose（句柄释放）。
//! 引擎经模块级单例桥（seam 契约无 userdata 字段——多 host 实例化属 v2，契约演化留档）。
//! 验证：`zig build test-adapter`。

const std = @import("std");
const seam = @import("seam.zig");
const app = @import("app_modules.zig");
const host_q = @import("host_quickjs.zig");

pub const Adapter = struct {
    host: host_q.QuickjsHost,
    module_host: seam.ModuleHost,

    /// 堆分配返回（g_adapter 指向本对象；栈临时销毁会悬垂——已踩）。
    pub fn init() !*Adapter {
        const act = try std.heap.page_allocator.create(Adapter);
        act.* = undefined;
        act.host = try host_q.QuickjsHost.init();
        act.module_host = .{
            .allocator = std.heap.page_allocator,
            .resolveFn = resolveFn,
            .evaluateFn = evaluateFn,
            .disposeFn = disposeFn,
            // 源来自 @embedFile 常量表（非堆）→ 无需释放
            .releaseResolvedFn = null,
        };
        g_adapter = act;
        return act;
    }

    pub fn deinit(self: *Adapter) void {
        if (g_adapter == self) g_adapter = null;
        self.host.deinit();
        std.heap.page_allocator.destroy(self);
    }
};

/// 引擎桥（契约无 userdata；单实例适配器 v1）
var g_adapter: ?*Adapter = null;

// ---------------------------------------------------------------------------
// builtin 桩（与 spike_cordis 同面；真实绑定在 M-3 fs/crypto/os 服务）
// ---------------------------------------------------------------------------
const stub_crypto = "export function randomUUID() { return '00000000-0000-4000-8000-000000000000'; }";
const stub_fs = "export function mkdirSync() {} export function readFileSync() { return null; } export function writeFileSync() {}";
const stub_fs_promises = "export async function opendir() {} export async function realpath() { return ''; }";
const stub_os = "export function homedir() { return '.'; }";
const stub_path = "export function dirname(p) { const i = p.lastIndexOf('/'); return i < 0 ? '.' : (i === 0 ? '/' : p.slice(0, i)); } export function join() { return Array.from(arguments).filter(Boolean).join('/'); } export function resolve(p) { return p; } export function basename(p) { const i = p.lastIndexOf('/'); return i < 0 ? p : p.slice(i + 1); }";

const builtins = [_]struct { name: []const u8, src: []const u8 }{
    .{ .name = "node:crypto", .src = stub_crypto },
    .{ .name = "node:fs", .src = stub_fs },
    .{ .name = "node:fs/promises", .src = stub_fs_promises },
    .{ .name = "node:os", .src = stub_os },
    .{ .name = "node:path", .src = stub_path },
};

fn builtinSource(name: []const u8) ?[]const u8 {
    for (builtins) |b| {
        if (std.mem.eql(u8, b.name, name)) return b.src;
    }
    return null;
}

/// 解析：裸包名（表直查 → <pkg>/index.js）；node: 前缀 → builtin stub；
/// 相对名 → 表直查（适配器 v1 只服务插件树入口；绝对规格化由引擎 normalizer 承担）。
fn resolveFn(
    _: *seam.ModuleHost,
    spec: []const u8,
    base: seam.BaseUrl,
    attrs: seam.ImportAttributes,
) anyerror!seam.ResolvedModule {
    _ = base;
    _ = attrs;
    std.debug.print("[adapter] resolveFn spec='{s}'\n", .{spec});
    if (std.mem.startsWith(u8, spec, "node:")) {
        const src = builtinSource(spec) orelse return error.Unresolved;
        return .{ .format = .builtin, .key = spec, .source = src };
    }
    var cand_buf: [256]u8 = undefined;
    const cand = if (std.mem.endsWith(u8, spec, "/index.js"))
        spec
    else
        std.fmt.bufPrint(&cand_buf, "{s}/index.js", .{spec}) catch spec;
    var c2_buf: [256]u8 = undefined;
    const cand2 = std.fmt.bufPrint(&c2_buf, "{s}/lib/index.js", .{spec}) catch cand;
    var c3_buf: [256]u8 = undefined;
    const cand3 = std.fmt.bufPrint(&c3_buf, "{s}/lib/index.mjs", .{spec}) catch cand;
    const key = blk: {
        for (app.modules) |m| {
            if (std.mem.eql(u8, m.name, spec) or
                std.mem.eql(u8, m.name, cand) or
                std.mem.eql(u8, m.name, cand2) or
                std.mem.eql(u8, m.name, cand3)) break :blk m.name;
        }
        return error.Unresolved;
    };
    return .{ .format = .module, .key = key, .source = "" };
}

fn evaluateFn(_: *seam.ModuleHost, resolved: seam.ResolvedModule) anyerror!seam.ModuleNamespace {
    _ = resolved.format;
    const act = g_adapter orelse return error.NoAdapter;
    return act.host.import(resolved.key, "", .{ .type = null });
}

fn disposeFn(_: *seam.ModuleHost, ns: seam.ModuleNamespace) void {
    if (g_adapter) |act| act.host.dispose(ns);
}
