# runtime-core 设计（接口级）

> 本文 = Zig 宿主核心的接口级设计（§1-6，落地已验证）+ 引擎绑定要点沉淀（§7）。
> **权威总览**（状态/架构/快速开始/留档清单）见 [OVERVIEW.md](OVERVIEW.md)；仓库主页见 [README.md](../README.md)。
> 历史流水（spike 笔记原始记录 + 轮记录 1-255 + 项目终态页）已归档至 [archive/rounds-log.md](archive/rounds-log.md)。

## 1. 进程与线程模型

- **单进程单线程主体**：Zig 事件循环（epoll/kqueue）驱动 quickjs-ng 的 job 队列（`JS_ExecutePendingJob`）与宿主 I/O。
- 每会话/子代理 = 独立 `JSRuntime` + `JSContext`；quickjs-ng 的 runtime 不可跨线程 → **线程 = 引擎分离层**：默认单线程主环；M-4 引入"重任务队列"（每线程一个 runtime 池）前不引入线程。
- 不被线程化：sqlite（同步 API）、fs（异步，复用内核线程池或 io_uring）。

## 2. 事件循环集成（核心工程点）

```
Zig poll loop                     quickjs-ng
├─ epoll wait ────────────────────┤
├─ IO completions → 发起回调      │  JS_EnqueueJob  (promise/timer/桥接)
├─ timer heap (ctx.timeout 映射)  │      ↓
├─ signal handlers                │  JS_ExecutePendingJob (每轮循环)
└─ idle hooks → JS_RunGC（卫生）  │      ↓ 回到 Zig
```

- 桥接调用 ABI：guest→host = `JS_NewCFunction`（绑定暴露为全局函数）；host→guest = 在 host 侧持有 `JSValue`（带 owner 标记）并在 job 内调用。
- **每次桥接调用 = 一个调用帧**：进入时建立 scope，返回时释放该帧全部临时 `JSValue`（§6.2 规则 1/2 的封套）。

## 3. Context 生命周期（规则 3 的落实）

- `SessionContext` 句柄：`create(baseUrl) → Session`, `close(Session)`。
- close = 优先清空：挂起 job → 注册的宿主回调（timer/watch/spawn disposer）→ `JS_FreeContext` → `JS_FreeRuntime`。
- 模块缓存挂在 runtime 的内部对象上（规则 4）：close 后无任何宿主结构引用其 module namespace；`seam.disposeFn` 只做值释放，不参与缓存所有权。

## 4. 模块链接器（seam.zig 的引擎侧实现，M-2）

对应补丁集 M-0 的 `HostModuleLoader` 接口：

| 步骤 | 实现 |
|---|---|
| resolve | node_modules 向上遍历；package.json `exports`/`imports` 条件（默认 `import`/`node`/`default`；仅 OTEL ESM 路径受控启用 `module`）；subpath/self-reference；`file:` URL；JSON/WASM 判定 |
| ESM 链接 | quickjs-ng `JS_LoadModule` 回调：从 `ResolvedModule.source` 喂模块字节；`import.meta.url` 注入 |
| CJS 包装 | `(module, exports, require, __dirname, __filename)`；`require` 递归回 resolve；`__esModule` 判别（与 loader.unwrapExports 配对） |
| builtins | 注册表：`node:fs` → `@dsh/shims/node-fs` JS 模块（经 Zig binding 暴露真实能力） |
| 缓存与循环 | key = `ResolvedModule.key`；CJS 先注册 exports 后执行（循环引用语义） |

## 5. 内存纪律（§6.2 → 代码级检查项）

| 规则 | 落地 |
|---|---|
| JSValue 唯一 owner | `JsValue` 包装 `deinit`；`defer` 强制；禁止跨 await 裸持 |
| 桥接帧 | `CallFrame` scope，退出释放 |
| context 生命周期 | §3 close 协议 |
| 模块缓存归属 | §4 缓存所有权声明 |
| timer/signal 清空 | context 关闭前调用各订阅 disposer（Zig 侧 `Registry`） |
| interrupt 复位 | `exec_ok` 包装：try/finally 复位 handler |
| 异常配对 | `JS_GetException` + `JS_FreeValue` 成对（`catchAndFree` helper） |
| 空闲 GC | 事件循环 idle hook 驱动 `JS_RunGC`（可配置间隔） |

## 6. 里程碑映射

- M-2：本骨架（seam 编译 ✅）+ quickjs-ng 集成 **spike 已验证**（4/4 probes，见 `runtime/src/spike_quickjs.zig`）+ 最小模块链接器 → headless-agent 全链路。
- M-3：`node:sqlite` shim（DatabaseSync 镜像）、Zig fs（含 sandbox 策略挂钩）、HTTP/WS。
- M-4：context 生命周期管理（§3）进产品路径、单二进制（`@embedFile` app JS）、内存卫生门禁（测试注入 ASAN/Valgrind）。


## 7. 引擎绑定要点（沉淀版）

Zig 0.16.0 + quickjs-ng 0.16.x（vendored amalgamated 单 quickjs.c/h @ `2c620e4`）。以下为仍然有效的工程要点；逐轮原始记录见 [archive/rounds-log.md](archive/rounds-log.md)。

1. **模块缓存键（最重要）**：引擎 `js_find_loaded_module` 按注册文件名原子比对——loader 必须以「引擎后续查找用的名字」（raw specifier）注册模块；normalizer 需配 raw→canonical 映射表还原相对导入基目录，否则裸名模块内的 `./x.js` 无法定位。此键序错位曾造成 4041 次重复编译 / 249MiB RSS；修复后 355 次编译 / 36.9MiB。
2. **Zig 0.16 时钟**：`std.time.nanoTimestamp` 已移除；用 `std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts)` 换算 i128 纳秒（参见 `host_quickjs.zig` `monoNs()`）。
3. **quickjs-ng 递归坑**：`.map(闭包)` 内自递归在 obj→arr 交替嵌套形状下触发 `Maximum call stack size exceeded`（栈帧往返）；改显式 for 循环即绕开，输出字节不变。
4. **内存纪律**：guest 堆上限 256MiB + interrupt handler；大图启动 GC 阈值 32MiB（16/32/64 A/B 后选定）；泄漏哨兵 `JS_DUMP_LEAKS` + ASAN 双轨；桥接调用每帧一个 scope、返回即释放帧内全部临时 `JSValue`。
5. **装载面**：ESM 全链 + CJS 换装/require 链/cache/cycle + JSON 模块 + package exports/subpath 封锁 + 裸内置 resolver；双实例残留实测仅 7 模块（pi-ai lazy×3 + node: builtin 桩×4），有界，不动 exports 封锁语义。
6. **测量口径**：`engine-ready`（进程起点 → entry import 落定，full ≈0.27s）与 smoke 编排墙钟（4.14s）分两条门禁，防止编排开销被误读为产品启动；常驻零成本追踪 `DSH_LOAD_TRACE=1`（逐模块 + `[load:stats]`）/ `DSH_PERF_TRACE=1`（内存）。
7. **shim 契约**：yaml（20 例）/ turndown+GFM（15 例）/ OTEL（8 例）独立契约测试步常驻回归；shim 化后原树仅为生成器输入，不进嵌入表。
8. **入架项与触发条件**：字节码预编译+STRIP_SOURCE（实测只能再省 ≈0.2s；触发：模块量翻倍或 engine-ready >1s）；lazy activation（可选优化）；Hermes 引擎替换（V2 才评估）。
