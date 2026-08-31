# dhz — DeepSeek Harness Zig 重实现

把 [DSH](https://github.com/deepseek-ai/deepseek-harness)（deepseek-harness）从 **Node.js 单进程承载一切**，重写为 **Zig 宿主 + quickjs-ng 引擎 + 多 context 生命周期** 的工程仓库。出货基线对齐 npm 已发布的 `@deepseek-ai/dsh` **0.1.1-rc.2**。

> **状态：核心目标已达成** —— cordis 契约不动 + 宿主世界全 Zig + 单二进制（ReleaseFast ≈9.9MB）+ headless/web/工具全链 + 31 项回归与稳定性矩阵全绿。
> **权威总览**（逐面状态 / 留档清单）：**[docs/OVERVIEW.md](docs/OVERVIEW.md)**。

## 为什么重写

| 维度 | Node 宿主 | 本仓库（Zig 宿主） |
|---|---|---|
| 峰值 RSS（full 生态面） | ≈285MB | **36.9MiB**（约 7.7x） |
| 峰值 RSS（core 性能档） | 同上 | **27.0MB**（约 10.6x） |
| 启动（进程起点 → entry import 落定） | 秒级 | **≈0.27s**（core ≈0.21s） |
| 分发形态 | Node + node_modules | **单二进制 ≈9.9MB**（完整剥离符号，嵌入 817 模块） |
| 宿主面可控性 | V8/libuv 黑盒 | 事件循环、模块加载、服务桥全部自有 Zig |

JS 应用生态一行不改：cordis 插件契约原样保留，Node 专有面（fs/sqlite/crypto/proc/http/timer 等）经 **Zig 服务桥** 与明确 stub 接入。

## 特性总览

- **引擎**：quickjs-ng 0.16（vendored，含本地补丁）+ Zig 宿主 `HostModuleLoader`——ESM 全链 / CJS 换装与 require 链 / 模块 cache 与 cycle / JSON 模块 / package exports 与子路径 / 裸内置 resolver
- **宿主桥** `dshServices`：fs / sqlite（WAL）/ crypto（SHA-256、subtle）/ proc（fork+setsid+三管道+landlock+终止升级链）/ http（网关路由、WS RFC6455 升级、逐块回调、异步 post 流）/ timer
- **web_globals**：fetch / URL / streams / TextEncoder / crypto / AbortSignal
- **安全边界**：`JS_SetMemoryLimit` 256MB + interrupt handler；ASAN / 泄漏哨兵双轨构建
- **四种运行模式**：`full`（生态面，默认）/ `core`（性能档）/ `headless`（agent 全链 + 黄金逐字节对照）/ `web`（HTTP/WS 网关 + 协议矩阵，支持常驻 serve）
- **LLM 录播线**：核心链全部走本地 mock（无网可复现）；真实 provider 适配装载面完整（网络执行未接线，见「已知限制」）
- **生态兼容台账**：`tools/compat-report.sh` 产出结构化报告，问题按 `investigate / configuration-required / optional-skip / design-skip / zig-replacement` 分类，兼容缺口不会被「smoke 通过」掩盖

## 架构（分层与源码索引）

```
┌─ 应用层：boot entry（patch-base → bundle profile → 行装载）
│    runtime/src/app-esm/bootstrap/entry.mjs
│    headless（CLI→profile→loader→LLM→bash 工具→golden）
│    web（HTTP/WS 网关 + 状态页 + 协议 op）
│    core/full 双模（bundle 行集可选）
├─ 引擎层：quickjs-ng 0.16（Zig 宿主）
│    runtime/src/host_quickjs.zig      —— 引擎绑定与模块加载缝
│    runtime/src/app_modules.zig       —— 嵌入模块表（生成器产出，817 模块/133 包）
│    web_globals / 安全边界（256MB limit + interrupt）
├─ 宿主桥：dshServices
│    runtime/src/fs_service.zig / fs_bridge.zig
│    runtime/src/http_bridge.zig       —— 路由/WS 升级/流式 post
│    runtime/src/sqlite_bridge.zig / crypto_bridge.zig / proc 相关
├─ 运行时：Zig event loop
│    runtime/src/event_loop.zig        —— timerfd→epoll→宿主回调→引擎 job→guest JS
└─ 生态：vendored DSH 包（@embedFile 闭包）+ node: 面 stub 与兼容 shim
     runtime/src/app-esm/ / runtime/src/builtin-stubs/ / runtime/tools/*-shim.js
```

设计要点（模块缓存键、Zig 0.16 API、递归坑、测量口径等 8 条永久教训）沉淀于 [docs/design-runtime-core.md](docs/design-runtime-core.md) §7。

## 仓库结构

```
├─ README.md                  —— 本页
├─ docs/
│  ├─ OVERVIEW.md             —— 权威总览（状态/架构/快速开始/留档）
│  ├─ design-runtime-core.md  —— 接口级设计 §1-6 + 引擎绑定要点 §7
│  ├─ protocol.md             —— WebUI 协议台账（基线 0.1.1-rc.2）
│  ├─ upstream-sync-0.1.2.md  —— 上游 0.1.2-alpha.1（未发布）同步评估与 staging
│  └─ archive/                —— 历史归档（迁移方案/255 轮记录/213 条里程碑/补丁）
└─ runtime/
   ├─ build.zig               —— 全部构建/冒烟目标（31 步回归矩阵）
   ├─ src/                    —— Zig 宿主源码 + 嵌入 ESM 树 + 桩
   ├─ vendor/                 —— quickjs-ng（吸收式 vendored）+ sqlite amalgamation
   ├─ tools/                  —— release/compat/perf 脚本、llm-mock、dhz-web 启动器、shim
   ├─ golden/                 —— headless 黄金对照
   ├─ fixtures/               —— ESM 加载夹具
   └─ out/                    —— 发布产物（gitignore，本地 release.sh 生成）
```

## 快速开始

### 依赖

- **Zig 0.16.x**（版本需精确——工程跟随 0.16 API；[ziglang.org/download](https://ziglang.org/download/) 下载解压后加入 `PATH`，`zig version` 验证）
- **python3**（冒烟链自动拉起 `tools/llm-mock.py`）
- 网络：核心验证链**不需要网络**（LLM 走录播 mock）

### 构建 + 冒烟

```bash
cd runtime

zig build boot-smoke-run      # full（默认，生态面）——看到 boot smoke OK 即通过
zig build core-smoke-run      # core（性能档，27.0MB RSS 基线）
zig build headless-smoke-run  # headless（agent 全链 + golden/headless.txt 逐字节）
zig build web-smoke-run       # web（网关 + 静态 + WS 协议矩阵）
```

全量 31 步回归（合约 + QuickJS + 各桥 smoke + shim 套件）：

```bash
for t in test spike-run esm-spike-run loader-spike-run cordis-spike-run require-spike-run \
  sqlite-smoke-run fs-smoke-run http-smoke-run event-loop-smoke-run fs-bridge-smoke-run \
  cordis-timer-smoke-run test-quickjs host-services-smoke-run cordis-services-smoke-run \
  http-bridge-smoke-run http-gateway-smoke-run trust-fence-smoke-run proc-smoke-run \
  sqlite-bridge-smoke-run test-adapter boot-smoke-run core-smoke-run headless-smoke-run \
  web-smoke-run crypto-smoke-run utf8-probe-run test-yaml-shim test-turndown-shim test-otel-shim; do
  zig build $t || echo "STEP_FAIL $t"
done
```

### 发布

```bash
bash tools/release.sh    # ReleaseFast 单二进制 + golden 校验 + MANIFEST → runtime/out/dsh-zig-runtime/
bash tools/perf-baseline.sh   # Debug/ReleaseFast 精确性能报告 → out/perf-report.json
bash tools/compat-report.sh   # 生态兼容结构化报告 → out/compat-report.json
```

性能门禁口径：`releaseEngineReady` ≤500ms（进程起点→entry import 落定，实测 ≈0.27s）、`releaseFullStartup` ≤10s（smoke 编排墙钟，实测 4.14s）、RSS ≤256MiB（实测 36.9MiB）。

### web 常驻服务

```bash
runtime/tools/dhz-web          # 前台启动，默认 http://127.0.0.1:3088
runtime/tools/dhz-web 3090     # 换端口
runtime/tools/dhz-web stop     # 停止（另开终端）
```

端点：`/` 与 `/index.html`（状态页，text/html）、`/ping`（活性）、`/post-echo`（回显）、`/ws`（RFC6455 + 协议 op：events/query/poll/sandboxStatus/sandboxSet/subscribe/whoami）。停止：`Ctrl+C` 或 SIGTERM，干净收尾（路由释放 + mock 回收，exit 0）。

> ⚠ **单实例设计**：会话库 `/tmp/dsh-sq.db`（WAL）与 llm-mock 固定端口 18099 是进程间共享资源。同时跑第二个实例会在 boot 异步链上停滞（曾误报 `ScaleSessions`）；启动器已做互斥守卫，直接裸跑二进制请自避。

## 生态兼容

- 生成器嵌入 **817 模块 / 133 包**；compat report 当前 9 条已分类问题（均为 info 级设计跳过/替代）、6 个 profile design-skip、7 个已通过兼容适配层
- shim 契约套件：YAML 20 例 / Turndown-GFM 15 例 / OTEL 8 例，全绿
- native-only 明确跳过：`koffi`、`sharp`、部分 subprocess/sandbox/attachment 行；OpenTelemetry 走嵌入 shim + fetch exporter

## 诊断探针（零成本门控，默认关闭）

| 环境变量 | 作用 |
|---|---|
| `DSH_LOAD_TRACE=1` | 模块装载打点（重复编译/实例数——模块缓存键修复的功臣） |
| `DSH_PERF_TRACE=1` | 启动阶段计时打点 |
| `DSH_HTTP_TRACE=1` | http 桥 listen/jsStop/连接表打点 |

## 已知限制

- **LLM 为本地录播**：headless/web 链路走 `tools/llm-mock.py`；真实 provider（deepseek 等）适配器装载面完整，但**网络执行尚未接线**——无 Authorization 头、provider/model 固定 mock。接线方案在案（env 密钥直通 + Bearer 注入），是下一阶段第一项
- **单实例**（见上节警告）
- **平台**：仅 Linux x86_64 验证；Windows/macOS 未验（方案后置）
- **外部验收项**（本环境不可执行）：GUI 视觉快照、Node 版逐字节参照（golden 为自基线）、长跑压力（10 项目+5 subagent）、Windows 三平台

## 路线图

- **上游 0.1.2 同步**：触发条件 = npm 发布 0.1.2（任意 dist-tag）。staging 已登记：①模块图重生成+兼容报告 ②protocol.md v2 ③http_gateway 令牌认证 + remote.mux ④LLM 录播重录 ⑤release golden 刷新。详见 [docs/upstream-sync-0.1.2.md](docs/upstream-sync-0.1.2.md)
- **搁置项（带触发条件）**：字节码预编译（模块量翻倍或 engine-ready >1s 时启动）/ lazy activation（可选优化）/ Hermes 替换（V2 方向）/ quickjs-ng 上游 issue #976 跟踪

## 文档地图

| 文档 | 定位 |
|---|---|
| [docs/OVERVIEW.md](docs/OVERVIEW.md) | **权威总览**（状态 / 架构 / 快速开始 / 留档） |
| [docs/design-runtime-core.md](docs/design-runtime-core.md) | 接口级设计（§1-6）+ 引擎绑定要点沉淀（§7） |
| [docs/protocol.md](docs/protocol.md) | WebUI 协议台账（/api 前缀、WS 帧、动态 cordis wire） |
| [docs/upstream-sync-0.1.2.md](docs/upstream-sync-0.1.2.md) | 上游 0.1.2-alpha.1 同步评估与实施 staging |
| [docs/archive/](docs/archive/) | 历史归档：迁移方案 / 轮记录流水 / 里程碑日志 / 早期探针与补丁 |

## 常见问题

- **`error: ScaleSessions`**：几乎都是已有实例在跑（单实例冲突），`tools/dhz-web stop` 后重试
- **浏览器打开显示 HTML 源码**：旧版本响应 `text/plain` 所致——当前版本首页已是 `text/html`，强刷（Ctrl+Shift+R）即可
- **根路径 404**：旧版本只注册了 `/index.html`；当前 `/` 与 `/index.html` 同页
- **构建报 API 不存在**：Zig 版本需 0.16.x，旧版/新版 API 均不兼容

## 许可与出处

- 本仓库工程层（Zig 宿主/桥/工具）随项目演进；`runtime/src/app-esm/` 为从 npm `@deepseek-ai/dsh` 0.1.1-rc.2 提取的应用模块树（上游：[deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)）
- `runtime/vendor/` 出处与本地补丁见 [runtime/vendor/README.md](runtime/vendor/README.md)

