# dhz 迁移项目总览

> **权威入口**。项目定位、当前状态、架构、快速开始、文档地图与留档清单都以此页为准。
> 历史流水（轮记录 1-255 / 里程碑日志 213 条）已归档至 [archive/](archive/)；干净设计文档见 [design-runtime-core.md](design-runtime-core.md)。

## 项目定位

把 DSH（deepseek-harness）从 **Node.js 单进程承载一切**，迁移为 **Zig 宿主 + quickjs-ng 引擎 + 多 context 生命周期** 的工程。

**当前已达成的核心主链**：
- **cordis 契约保持**（应用包保留原 JS 契约；Node 专有面通过 Zig 服务桥与明确 stub 接入）
- **宿主世界全部 Zig**（事件循环 + quickjs-ng 编译链 + 服务桥 + 模块加载器）
- **单二进制分发**（ReleaseFast 当前发布产物约 **9.9MB**，完整剥离符号，含完整嵌入模块表）
- **headless/web/工具全链**（CLI→profile→loader→LLM→工具→退出；HTTP/WS 网关；smoke 与发布 golden 全绿）

## 当前状态（持续兼容验收）

| 面 | 状态 |
|---|---|
| 引擎 | quickjs-ng 0.16 Zig 宿主：HostModuleLoader（ESM 全链 + CJS 换装/require 链/cache/cycle + JSON 模块 + package exports/subpath/裸内置 resolver）+ 服务桥（fs/sqlite/crypto/proc/http/timer）+ web_globals（fetch/URL/streams/TextEncoder/crypto）+ 安全边界（256MB 内存限制 + interrupt）+ ASAN/泄漏哨兵双轨 |
| 核心链 | **headless**（黄金逐字节，无网录播）/ **web**（网关+静态+协议矩阵）/ **core-full 双模** / LLM 录播链（LlmRuntime+BlockAssembler+多轮工具环）/ 配置插件按环境启用 |
| 生态装载 | 生成器当前嵌入 **817 个模块 / 133 个包**；compat report 记录 9 条已分类问题（当前均为 info 级设计跳过/替代），6 个 profile design-skip，并标出 7 个已通过兼容适配层 |
| 质量 | `test`、QuickJS、三套 shim 契约（YAML 20 例、Turndown/GFM 15 例、OTEL 8 例）、settings 写路径与 credentials 加载探针、core/headless/web smoke、compat/perf report 与 release golden 均通过；连续 full boot 稳定性压力 5/5；剩余生态项保留在结构化报告中 |

### 资源基线（ReleaseFast 二进制）

| 模式 | 峰值 RSS | 启动 | 对照 Node 285MB |
|---|---|---|---|
| core（性能档） | **27.0MB** | engine-ready ≈0.21s | 约 10.6x 低于 Node 基线 |
| full（生态面） | **36.9MiB** | **engine-ready ≈0.27s**（smoke 全链路墙钟 4.14s 为编排开销） | 约 7.7x 低于 Node 基线；远低于 256MiB 门禁 |
| headless | **≈full**（同模块图） | ≈full | 全量 + agent 环 |

核心链冒烟走 **llm 录播线**（mock 服务，无网可复现）；**真 LLM 渠道已通**：`tools/llm-relay.py` 本地明文 HTTP→上游 HTTPS+Bearer 中继（密钥只读 `~/.dsh/.credentials.yaml`，不进 Zig/guest），`DSH_LLM_REAL=1` 时 guest 直驱 adapter wire 面走真 API（验收：glm-5.3-flash 真往返 + WS 会话面板多轮对话）。

## 架构（分层）

```
┌─ 应用层：boot entry（patch-base → bundle profile → 行装载）────────────┐
│   headless（CLI→profile→loader→LLM→bash 工具→golden）                │
│   web（HTTP/WS 网关 + 静态面 + 协议 op）                              │
│   core/full 双模（bundle 行集可选）                                    │
├─ 引擎层：quickjs-ng 0.16（Zig 宿主）──────────────────────────────────┤
│   HostModuleLoader（seam 契约）——ESM/CJS/JSON/exports/子路径/裸内置    │
│   web_globals（fetch/URL/streams/TextEncoder/crypto/AbortSignal）     │
│   安全边界（JS_SetMemoryLimit 256MB + interrupt handler）             │
├─ 宿主桥：dshServices（fs/sqlite/crypto/proc/http/timer）──────────────┤
│   proc_wrap（fork/setsid/3 管道/landlock/execvp + 终止升级链）         │
│   http_bridge（网关路由/WS 升级/逐块回调/异步 post 流）                │
├─ 运行时：Zig event loop（timerfd→epoll→宿主回调→引擎 job→guest JS）──┤
└─ 生态：vendored DSH 包（@embedFile 闭包 817 模块）+ node: 面 stub 与兼容 shim ─┘
```

## 快速开始

```bash
cd runtime
export PATH=/home/dapao/zig/zig-x86_64-linux-0.16.0:$PATH

# 全量回归（runtime Zig 合约 + QuickJS + core/headless/web smoke）
for t in test spike-run esm-spike-run loader-spike-run cordis-spike-run require-spike-run \
  sqlite-smoke-run fs-smoke-run http-smoke-run event-loop-smoke-run fs-bridge-smoke-run \
  cordis-timer-smoke-run test-quickjs host-services-smoke-run cordis-services-smoke-run \
  http-bridge-smoke-run http-gateway-smoke-run trust-fence-smoke-run proc-smoke-run \
  sqlite-bridge-smoke-run test-adapter boot-smoke-run core-smoke-run headless-smoke-run \
  web-smoke-run crypto-smoke-run utf8-probe-run test-yaml-shim test-turndown-shim test-otel-shim; do zig build $t; done

# 发布（ReleaseFast 约 9.9MB 完整剥离符号的单二进制 + 黄金校验 + MANIFEST）
bash tools/release.sh

# 生成结构化生态兼容问题报告（保留 smoke 证据）
bash tools/compat-report.sh

# 生成精确 Debug/ReleaseFast 资源性能报告
bash tools/perf-baseline.sh  # 写入 runtime/out/perf-report.json

# 单模式运行
zig build boot-smoke-run      # full（默认，生态面）
zig build core-smoke-run      # core（性能档，27.0MB）
zig build headless-smoke-run  # headless（agent 全链 + 黄金对照）
zig build web-smoke-run       # web（网关 + 静态 + 协议矩阵）

# web 常驻服务模式（断言全过后对外服务，端口默认 18086）
DSH_WEB_PORT=3088 DSH_WEB_SERVE=1 \
  $(find .zig-cache -name boot-smoke -type f -executable -printf '%T@ %p\n' | sort -rn | head -1 | cut -d' ' -f2) web
# 端点：/ 与 /index.html（同一首页）、/ping、/post-echo、/ws（RFC6455 + 协议 op）；停止：SIGTERM/SIGINT 干净收尾
# 终端启动器：dhz-web [端口=3088]（~/bin/dhz-web）；停止：dhz-web stop
# ⚠ 单实例：会话库 /tmp/dsh-sq.db（WAL）与 llm-mock 18099 为固定共享资源——
#   并发第二实例会在 boot 异步链上停滞（曾误报 ScaleSessions），启动器已做互斥守卫
```

依赖：python3（llm-mock 自动拉起）、无网络（llm 录播线）。

**web 服务模式**（本轮新增）：`DSH_WEB_SERVE` 置位时 web 模式在断言全过后驻留事件循环对外服务（`DSH_WEB_PORT` 指定端口）；实现要点——①serve 模式跳过 WS 测试后的网关 teardown（`jsStop`），服务器生命周期改为 serve 循环后的统一清理；②修复事件循环潜伏 bug：`epoll_wait` 原始返回值未检错，信号打断（EINTR）时负 errno 被当作巨大 usize 事件数导致越界读崩溃——现 EINTR 重试、其他错误终止本轮驱动；serve 信号处理器带 `SA_RESTART`。诊断探针 `DSH_HTTP_TRACE=1`（listen/jsStop 打点，零成本门控）。

**探针竞态治理（同轮）**：两个既有瞬态 flake 已根因修复——①`ProcTermShouldNotExit`：旧探针对「忽略 TERM 的子进程」盲发 TERM，子进程尚在 fork/exec/trap 设置窗口时 TERM 走默认动作致死（strace/高负载放大窗口）；改为 `trap '' TERM; echo ready; sleep 5` 就绪握手，读到 stdout `ready`（trap 已安装）才进入终止链。②`ScaleSessions`：旧断言 `sessions.list().length >= 52` 依赖 boot-child 等其他会话的异步创建时序（llmLoop 交错时 51<52 假阴性）；改为只数本探针自建的 `scale-*` 前缀会话（===50），并新增 `__scaleErr` 诊断打印。验证：boot 15/15、strace boot 3/3（原放大器）、web 5/5、headless/core 各过、31 步全绿。同时本轮修复的 `epoll_wait` EINTR 未检错崩溃与上述两项一并消除了孤立重跑的全部已知 flake 源。

## 文档地图

| 文档 | 定位 |
|---|---|
| **本页（OVERVIEW.md）** | 权威总览：状态 / 架构 / 快速开始 / 留档 |
| [design-runtime-core.md](design-runtime-core.md) | 接口级设计（§1-6）+ 引擎绑定要点沉淀（§7） |
| [protocol.md](protocol.md) | WebUI 协议台账（/api 前缀、WS 帧、动态 cordis wire 等）——基线 0.1.1-rc.2 |
| [upstream-sync-0.1.2.md](upstream-sync-0.1.2.md) | 上游 0.1.2-alpha.1（未发布）同步评估：remote.mux/令牌认证/工具词汇/模块图 delta 与实施 staging |
| [archive/](archive/) | 历史归档：迁移方案 / 轮记录流水 / 里程碑日志 / 早期探针与补丁 |
| [README.md](../README.md) | 仓库主页（项目简介 + 快速开始 + 基线表） |

## 兼容问题上报

`bash tools/compat-report.sh` 执行 ReleaseFast boot smoke，并写入 `runtime/out/compat-report.json`。报告固定包含主链 `status/exitCode`、独立的 `compatibilityStatus`、`issueCounts`、结构化 `issues`、已验证的 `compatibilityLayers`、设计性跳过 `designSkips` 和可追溯 `evidence`；`issues[].disposition` 区分 `investigate`、`configuration-required`、`optional-skip`、`design-skip` 与 `zig-replacement`，因此兼容缺口不会被“smoke 通过”掩盖。

`bash tools/perf-baseline.sh` 会分别构建并解析精确的 Debug/ReleaseFast 缓存产物，测量启动时间、峰值 RSS、二进制大小，并写入 `runtime/out/perf-report.json`；门禁分两条口径——`releaseEngineReady`（产品启动：进程起点 → entry import 落定，门限 500ms）与 `releaseFullStartup`（smoke 全链路墙钟，含编排等待，门限 10s），RSS 门限为 `256MiB`。

**真渠道与会话面板（本轮新增）**：①`llm-relay.py`——Zig 运行时无 TLS 面，中继转发上游并注入 Bearer；响应全量缓冲+Content-Length 回写（契同 llm-mock——close-delimited 会被 guest 读成空 body）；消息白名单化（剥 dsh 附加字段，真 API 否则 400）。②`DSH_LLM_REAL`（+`DSH_LLM_PROVIDER/MODEL/RELAY_PORT/IMPORT`）——relay 自拉起（defer 须函数域，块内 defer 出块即杀中继）+ `__dshLlmReal` 注入 + realWire/realLlm 探针。③`tools/export-session.py`——Node 版 `session.jsonl.zstd` 导出双轨（展示轨 200 事件 + LLM 上下文轨归一化：合并连续同角色、首条须 user、2×tail 窗口——上游对非交替/assistant 开头的序列 stream 下静默回空）。④web 会话面板——`chat/*` 自定义事件类型（绕开 surfaceOp 契约）、ws 扩展 op `history`/`chat-send`（绕开上游协议 schema）、chat 轮**直驱 adapter._stream**（LlmRuntime 的 isolate 在 serve 循环拿不到 job 泵，流不推进——排障实锤）；WS 回复面换 128K 模块级缓冲（原 16KB 栈缓冲静默丢帧）。⑤`dhz-web chat`——自动定位当前目录最新主会话→导出→真渠道 serve。已知边界：v1 无工具环（纯文本对话）、导入为时点快照（Node 版后续写入不回流）。

## 当前已知限制

0. **内存构成（实测定论，模块缓存修复后修订）**：早前"约 136MiB 函数元数据（约 24.5 万函数）属架构性成本"的定论已被推翻——`DSH_LOAD_TRACE=1` 实测发现引擎模块缓存键恒不匹配：loader 以 canonical 注册模块，引擎却按规范化 specifier 查找（`js_find_loaded_module`），导致每条 import 边都重复编译整份模块（4041 次编译 / 仅 311 个去重名，cosmokit 单模块 345 个实例）。修复为"以引擎查找名注册模块 + normalizer 经 raw→canonical 表还原相对导入基目录"后：编译 4041→355 次、funcs 24.8 万→6,568、QuickJS 堆 malloc 235→14.4MiB、full 峰值 RSS 约 249→**36.9MiB**（core 84.6→27.0MB）、启动 6.4→4.11s。急切编译全量模块图的真实成本仅约 14MiB 堆——按需激活（lazy activation）从必要架构方向降级为可选优化；`DSH_PERF_REPORT` / `out/perf-report.json` 保留门禁证据。启动口径同轮修正：boot-smoke 计时打点实测进程起点 → entry import 落定仅 **≈0.27s**（编译 221ms / 实例化+顶层求值 65ms），此前报告的 4.11s 为 smoke 编排墙钟（spawn-kill 宽限、mock LLM 往返等待等探针故意等待）；残留双实例实测仅 7 个模块（3 个 pi-ai lazy + 4 个 node: builtin 桩）结案不动。字节码预编译随之降级入架（实测只能再省 ≈0.2s，触发条件：模块量翻倍或 engine-ready 超 1s）
1. **外部件依赖**：GUI 快照/web 套件（无 GUI 环境）、Node 版逐字节参照（无 Node 环境——golden 为自基线）、长跑压力（10 项目+5 subagent）、Windows 三平台（方案注后置）
2. **生态深链**：settings/credentials、skill-filesystem、tool-web 的入口和 YAML/Markdown 适配面已通过；koffi、sharp、部分 subprocess/sandbox/attachment 行明确按 native-only 处理；OpenTelemetry 当前使用嵌入 shim 与 fetch exporter。
3. **无用户面**：Intl（vendors 零使用——不预置）
4. **架构抉择**：boot 桩路线（官方行 design-skip）、subagent 生态行（桩路线）、多 runtime 隔离（单 runtime 全量限制）、CJS 命名导出/中文面

全部限制均由 `runtime/out/compat-report.json` 生成证据（当前 `compatibilityStatus=design-skips-only`），并在 [archive/rounds-log.md](archive/rounds-log.md) 轮记录中保留原因和后续方向；GUI 快照、Node 逐字节参照、长跑压力和 Windows 验证仍是外部验收项。
