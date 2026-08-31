//! HostModuleLoader seam — Zig side.
//!
//! Mirrors the TypeScript contract in deepseek-harness `vendor/loader/src/host-loader.ts`
//! (M-0 patch): the plugin tree imports every entry module through ONE seam —
//! `import(specifier, baseUrl, attributes) -> namespace`. Nothing else in the
//! loader is host-specific.
//!
//! This file is the RUNTIME-CONTRACT definition only (types + adapter outline):
//! the quickjs-ng binding lands in M-2 alongside the vendored engine. Keep this
//! file free of engine includes so it can be type-checked standalone.

const std = @import("std");

/// Import attributes of the importing entry (`with { type: 'json' }` et al).
pub const ImportAttributes = struct {
    type: ?[]const u8 = null,
};

/// Entry-tree base URL: the resolution anchor for relative specifiers.
/// `file:///path/to/profile/` in the Node host; same shape here.
pub const BaseUrl = []const u8;

/// Opaque handle to one loaded module namespace. The concrete value is owned
/// by the engine host (quickjs-ng JSValue for the module namespace object);
/// the entry tree only passes it to `unwrapExports`.
pub const ModuleNamespace = *anyopaque;

/// HOST constructor-context: everything the loader needs to drive imports.
pub const ModuleHost = struct {
    allocator: std.mem.Allocator,

    // Implemented by the quickjs-ng host (M-2):
    //
    //  resolve(specifier, baseUrl, attrs) -> ResolvedModule
    //    - bare specifier: node_modules walk + package.json exports/imports
    //      conditions (`import`, `node`, `default`), subpaths, self-reference
    //    - '.'-relative: new URL(specifier, baseUrl) semantics
    //    - 'cordis:' handled by the loader BEFORE reaching this seam
    //    - builtin table: 'node:fs' etc. -> shim module source
    //  evaluate(resolved) -> ModuleNamespace
    //    - ESM: quickjs-ng module loader callback (JS_LoadModule)
    //    - CJS: `(module, exports, require, __dirname, __filename)` wrapper,
    //      require() routed back through resolve()
    //    - JSON: `export default <parsed>;` synthetic module
    //  dispose(namespace) -> void
    //    - JS_FreeValue on the namespace; module cache ownership is the
    //      runtime's, NOT the host's (memory rule #4 in 方案 §6.2)
    resolveFn: *const fn (*ModuleHost, []const u8, BaseUrl, ImportAttributes) anyerror!ResolvedModule,
    evaluateFn: *const fn (*ModuleHost, ResolvedModule) anyerror!ModuleNamespace,
    disposeFn: *const fn (*ModuleHost, ModuleNamespace) void,
    /// Release the resolver-owned payload (source bytes, resolved path).
    /// MUST be called exactly once per resolved module after evaluation.
    releaseResolvedFn: ?*const fn (*ModuleHost, ResolvedModule) void = null,

    pub fn import(self: *ModuleHost, specifier: []const u8, base: BaseUrl, attrs: ImportAttributes) !ModuleNamespace {
        const resolved = try self.resolveFn(self, specifier, base, attrs);
        defer self.releaseResolved(resolved);
        return self.evaluateFn(self, resolved);
    }

    fn releaseResolved(self: *ModuleHost, resolved: ResolvedModule) void {
        if (self.releaseResolvedFn) |release| release(self, resolved);
    }
};

/// One resolved module: source bytes plus the format name the evaluator needs.
pub const ResolvedModule = struct {
    /// Format discriminator: "module" | "commonjs" | "json" | "builtin".
    format: ModuleFormat,
    /// Absolute file path or builtin id; used for module-cache keys.
    key: []const u8,
    /// Owned by the resolver; released via `releaseResolvedFn` after evaluation.
    source: []const u8,
};

pub const ModuleFormat = enum {
    module,
    commonjs,
    json,
    builtin,
};

// ---------------------------------------------------------------------------
// 合规锚点（方案 §6.2 备忘录 → 对应代码边界）
//
// 1. JSValue owner           — ModuleNamespace 是唯一持有点；跨函数传递
//                             必须显式传递 ownership（Zig 无 GC，defer 兜底）。
// 2. 桥接调用帧              — 每次 host<->guest 往返结束释放全部临时值。
// 3. context/runtime 生命周期 — 会话即 context；关闭 = JS_FreeContext(+Runtime)。
// 4. 模块缓存归属 runtime    — 此处 disposeFn 永远不 pin 模块缓存。
// 5. timer/signal/job 队列   — 挂 fiber；context 释放前清空。
// 6. interrupt handler 复位  — JS_SetInterruptHandler 每次执行后复位（M-2 检查项）。
// 7. 异常路径配对            — JS_Call/Eval 后 exception 值成对释放（M-2 检查项）。
// 8. 空闲 JS_RunGC           — 宿主 idle 定时器触发（M-4 落地）。
// ---------------------------------------------------------------------------

test "seam types compile and import helper works with a stub host" {
    const Testing = struct {
        fn resolveFn(_: *ModuleHost, spec: []const u8, _: BaseUrl, _: ImportAttributes) anyerror!ResolvedModule {
            return .{ .format = .builtin, .key = spec, .source = "" };
        }
        fn evaluateFn(_: *ModuleHost, r: ResolvedModule) anyerror!ModuleNamespace {
            return @ptrCast(@constCast(r.key.ptr));
        }
        fn disposeFn(_: *ModuleHost, _: ModuleNamespace) void {}
    };
    var host = ModuleHost{
        .allocator = std.testing.allocator,
        .resolveFn = Testing.resolveFn,
        .evaluateFn = Testing.evaluateFn,
        .disposeFn = Testing.disposeFn,
    };
    const ns = try host.import("node:fs", "file:///base/", .{ .type = null });
    try std.testing.expect(@intFromPtr(ns) != 0);
}
