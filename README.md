# dhz — DeepSeek Harness Zig 重实现

把 DSH（deepseek-harness）从 **Node.js 单进程承载一切**，重写为 **Zig 宿主 + quickjs-ng 引擎 + 多 context 生命周期** 的工程仓库。

> **状态：核心目标已达成** —— cordis 契约不动 + 宿主世界全 Zig + 单二进制（ReleaseFast **9.9MB**）+ headless/web/工具全链 + **31 项回归**与稳定性矩阵全绿。
> **权威总览**（状态 / 架构 / 快速开始 / 留档清单）：**[docs/OVERVIEW.md](docs/OVERVIEW.md)**。

## 快速开始

```bash
cd runtime
export PATH=/home/dapao/zig/zig-x86_64-linux-0.16.0:$PATH
zig build boot-smoke-run      # full（默认，生态面）
zig build core-smoke-run      # core（性能档）
zig build headless-smoke-run  # headless（agent 全链 + 黄金对照）
zig build web-smoke-run       # web（网关 + 静态 + 协议矩阵）
bash tools/release.sh         # 发布（单二进制 + 黄金校验 + MANIFEST）
# web 常驻服务：DSH_WEB_PORT=3088 DSH_WEB_SERVE=1 <boot-smoke 二进制> web（SIGTERM 停止）
```

依赖：python3（llm-mock 自动拉起）、无网络（LLM 录播线）。完整 31 步回归矩阵见 [docs/OVERVIEW.md](docs/OVERVIEW.md)。

## 当前基线（ReleaseFast）

| 模式 | 峰值 RSS | 启动（engine-ready） | 对照 Node 285MB |
|---|---|---|---|
| core（性能档） | **27.0MB** | ≈0.21s | 约 10.6x |
| full（生态面） | **36.9MiB** | ≈0.27s（smoke 编排墙钟 4.14s 另列门禁） | 约 7.7x |
| headless | ≈full | ≈full | 全量 + agent 环 |

嵌入模块图 **817 模块 / 133 包**；发布件 `runtime/out/dsh-zig-runtime/`（9.9MB，SHA-256 `8ef597cf…`，golden 逐字节校验通过）。

## 文档地图

| 文档 | 定位 |
|---|---|
| [docs/OVERVIEW.md](docs/OVERVIEW.md) | **权威总览**（状态 / 架构 / 快速开始 / 留档） |
| [docs/design-runtime-core.md](docs/design-runtime-core.md) | 接口级设计（§1-6）+ 引擎绑定要点沉淀（§7） |
| [docs/protocol.md](docs/protocol.md) | WebUI 协议台账（基线 0.1.1-rc.2） |
| [docs/upstream-sync-0.1.2.md](docs/upstream-sync-0.1.2.md) | 上游 0.1.2-alpha.1（未发布）同步评估与实施 staging |
| [docs/archive/](docs/archive/) | 历史归档：迁移方案 / 轮记录流水 / 里程碑日志 / 早期探针与补丁 |

## 上游跟踪

出货基线 = npm 已发布 **0.1.1-rc.2**（golden / 协议台账 / LLM 录播对齐可安装产品）。上游 master 已至 v0.1.2-alpha.1（未发布），契约级 delta 与实施触发条件登记于 [docs/upstream-sync-0.1.2.md](docs/upstream-sync-0.1.2.md)。
