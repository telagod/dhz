//! quickjs-ng 的**唯一** cimport 源。
//! 跨模块函数指针/值类型（JSValue/JSCFunction…）必须出自同一份 cimport，
//! 否则两份 @cImport 生成互不兼容类型（§7 反复踩坑的单一化规则）。
//! 其他模块：`pub const c = @import("engine_c.zig").c;`（保留各自 `xxx.c` 路径）。

pub const c = @cImport({
    @cInclude("quickjs.h");
});
