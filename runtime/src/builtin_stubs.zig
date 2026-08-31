//! 由 tools/gen-app-esm.py 生成 —— 请勿手改。（M-5 builtin 面）
//! 闭包依赖扫描出的 node: 模块 -> stub 源码（真实绑定在 M-3 服务层）。
pub const Builtin = struct { name: []const u8, src: []const u8 };

pub const builtins = [_]Builtin{
    .{ .name = "node:assert", .src = @embedFile("builtin-stubs/n-assert") },
    .{ .name = "node:async_hooks", .src = @embedFile("builtin-stubs/n-async_hooks") },
    .{ .name = "node:buffer", .src = @embedFile("builtin-stubs/n-buffer") },
    .{ .name = "node:child_process", .src = @embedFile("builtin-stubs/n-child_process") },
    .{ .name = "node:constants", .src = @embedFile("builtin-stubs/n-constants") },
    .{ .name = "node:crypto", .src = @embedFile("builtin-stubs/n-crypto") },
    .{ .name = "node:events", .src = @embedFile("builtin-stubs/n-events") },
    .{ .name = "node:fs", .src = @embedFile("builtin-stubs/n-fs") },
    .{ .name = "node:fs/promises", .src = @embedFile("builtin-stubs/n-fs_promises") },
    .{ .name = "node:module", .src = @embedFile("builtin-stubs/n-module") },
    .{ .name = "node:os", .src = @embedFile("builtin-stubs/n-os") },
    .{ .name = "node:path", .src = @embedFile("builtin-stubs/n-path") },
    .{ .name = "node:perf_hooks", .src = @embedFile("builtin-stubs/n-perf_hooks") },
    .{ .name = "node:process", .src = @embedFile("builtin-stubs/n-process") },
    .{ .name = "node:querystring", .src = @embedFile("builtin-stubs/n-querystring") },
    .{ .name = "node:sqlite", .src = @embedFile("builtin-stubs/n-sqlite") },
    .{ .name = "node:stream", .src = @embedFile("builtin-stubs/n-stream") },
    .{ .name = "node:string_decoder", .src = @embedFile("builtin-stubs/n-string_decoder") },
    .{ .name = "node:timers", .src = @embedFile("builtin-stubs/n-timers") },
    .{ .name = "node:timers/promises", .src = @embedFile("builtin-stubs/n-timers_promises") },
    .{ .name = "node:url", .src = @embedFile("builtin-stubs/n-url") },
    .{ .name = "node:util", .src = @embedFile("builtin-stubs/n-util") },
    .{ .name = "node:util/types", .src = @embedFile("builtin-stubs/n-util_types") },
    .{ .name = "node:vm", .src = @embedFile("builtin-stubs/n-vm") },
    .{ .name = "node:worker_threads", .src = @embedFile("builtin-stubs/n-worker_threads") },
    .{ .name = "node:zlib", .src = @embedFile("builtin-stubs/n-zlib") },
};
