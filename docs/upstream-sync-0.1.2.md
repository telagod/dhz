# upstream-sync-0.1.2.md — 上游 0.1.1-rc.2 → master（0.1.2-alpha.1）同步评估

> 评估日期：2026-08-30。上游基线：npm 已发布 **0.1.1-rc.2**（dsh-v0.1.1-rc.2 = b150a55，2026-08-21）；
> 上游前沿：master = **v0.1.2-alpha.1** 标签（cd5ef81），**未发布 npm**（dist-tags latest/next 均仍 rc.2）。
> 跨度：1079 提交 / 6421 文件。方法：本地 clone 全量 diff + .agents/notes 设计留档逐域挖掘。

## 基线决策

**出货基线保持 0.1.1-rc.2 不变**。我们的 golden 逐字节、协议台账、LLM 录播全部对齐「已发布产品」，
而 0.1.2-alpha.1 尚未上 npm——现在实施 master 协议会让本 runtime 与实际可安装的 GUI 失配。
本文件登记全部契约级 delta；**实施触发条件 = npm 发布 0.1.2（任何 dist-tag）**。

## A. Web/API 协议（破坏性，protocol.md 需出 v2）

| # | 变化 | 证据 |
|---|---|---|
| A1 | **WS 下链重构**：`/api/events.mux` + `/api/events.host` 删除。改由 API Gateway 自有单条 **`/api/remote.mux`** WebSocket：多条可独立取消的逻辑流复用一条物理连接；Host 每 30s 发 Ping（`websocketHeartbeatIntervalMs`），浏览器协议层回 Pong；一元调用走 HTTP POST；进程内载体 `connection.rpc.open` 不开 socket | `packages/api/gateway/src/stream-protocol.ts:6` `REMOTE_STREAM_MUX_PATH`；`packages/api/gateway/README.zh.md:35` |
| A2 | **ApiProxy 包整体删除**：Typert Gateway 认领生成的 Remote endpoint，未认领请求 404（原为 apiproxy fallback）；415 媒体类型栅栏存续，移至 `packages/client/connection/src/rpc-host.ts:216` | `refactor(api): remove ApiProxy package`（4f00a8b82）；CLI 依赖删 `dsh-host-apiproxy` |
| A3 | **浏览器令牌认证（新层）**：每个 Host RPC 方法与 WS stream 统一要求浏览器会话——按方法特权的 loopback 列表（PRIVILEGED_METHODS 16 项）**废除**。每进程随机启动令牌；`dsh-web-app` 打印/打开 `?token=...` 根 URL；仅 `GET /?token=...` 把令牌换成签名 cookie 并 303 到干净 `/`；API 路径与 Authorization header 均不接受令牌 | `.agents/notes/implemented/architecture/2026-08-24-browser-token-authentication.zh.md` |
| A4 | **cookie 形制**：HMAC 签名 + authority 绑定（规范化 hostname+port 同时入确定性名称与签名 payload，同 home 多端口不冲突）；host-only、`Path=/`、`HttpOnly`、`SameSite=Strict`、loopback HTTP 刻意不设 `Secure`；绝对有效期默认 30 天（`cookieMaxAgeDays`）；签名密钥 = credentials grant 记录 **`client-connection/browser-session`**（本地落 `$DSH_HOME/.credentials.yaml`）；删记录+重启 = 全局撤销 | 同上 note |
| A5 | **状态码语义**：Host/Origin 信任栅栏失败 403（媒体类型/Host/Origin/sec-fetch-site 规则不变）；Host 可信但无有效会话 401（缺失与无效凭据同一份最小响应）；静态资产保持公开；`dsh web --host 0.0.0.0` 仍拒绝 | 同上 note + connection README |

实施影响：`http_server.zig`/`http_gateway.zig` 需加认证层（HMAC cookie 签发/校验、303 交换、credentials 记录读写）+ remote.mux WS 协议（逻辑流帧、Ping/Pong 心跳、取消）；protocol.md §1/§2/§3 重写为 v2；web-smoke 协议矩阵重录。

## B. boot / profile / CLI

- **CLI 运行时依赖 72 → 106 个 @deepseek-ai 包**。新增面：ACP（`dsh-acp-app`/`dsh-acp`/`@agentclientprotocol/sdk@1.4.0`）、LLM 拆分（`dsh-llm-deepseek`/`dsh-llm-pi-ai`/`dsh-llm-replay`）、本地桥接独立成包（`bash-local`/`subprocess-local`/`credentials-local`/`attachment-local`/`settings-file`/`session-persistence-jsonl`/`session-log-deepseek`）、沙箱面（`sandbox-local`/`sandbox-policy`/`fs-sandbox`/`fs-observation-policy`/`user-approval`）、hooks（`hooks-claude-code`/`hooks-codex`）、subagent 进程内提供方（`subagent-fork-in-process`/`subagent-spawn-in-process`/`tool-subagent-report`）、webhook（`webhook`/`webhook-github`）、实验 agent-team 三件套、`session-query`、`sdk-app`/`sdk-minimal`、`agent-spine-demo`、`schemastery`；删除 `dsh-host-apiproxy`；新增 `ws@8.21.0` 依赖。
- **profile 组合机制改为 `configTrees`**：presets 移入 `packages/preset/agent-presets/presets/{cordis,minimal,ptc,standard}`（**新增 ptc preset**；cordis preset 自带两个 skill），CLI 以 `scanRoster` 挂载；persona 文档大改（+102 行）。
- 实施影响：模块生成器需对 0.1.2 依赖图重跑（当前嵌入 817 模块/133 包将显著增长），`compat-report.json` 重分类。

## C. agent 工具面（词汇级）

- **真新增工具仅 `list_subagent_models`**（`dsh-tool-subagent`）：发现 subagent 可用 LLM 路由（列提供方/列模型/校验精确模型+推理强度）。
- **subagent 委派工具 schema 扩展**：Session 策略启用时增加 `provider`、`model`、`reasoning_effort` 字段（动态路由）；工具描述与 `tool:<toolName>` 系统提示词段相应变化；`subagent_fork` 始终固定路由。
- **PTC 改名**：`mode: code` → `mode: ptc`（`packages/core/tools/src/ptc.ts`，tool-catalog 同步）；**session 持久化词汇刻意不变**（fail-closed 兼容——旧会话重放不受改名影响）。
- 内部类型 `CallId` → `ToolCallId`（不进协议）。
- 实施影响：rc.2 基线内 LLM 录播 golden 自洽无需动；0.1.2 对齐时录播与 web 协议矩阵需重录。

## D. runtime / 存储 / SDK

- **session-persistence-sqlite**：user-version **17 → 19** 迁移（upsert-session/update-session-revision 变更）+ 新增 zstd 字典——随模块图刷新自动流入（SQL 在 JS 侧执行，我们的 sqlite 桥无需改），compat 重跑即可。
- **webworker-runtime builtin_modules +3997 行**：新增 zlib、util/types 实现与 dns/net/sqlite/vm/worker_threads mock——上游自身 JS 运行时实验，非我方契约；可作 builtin-stubs 路线参考。
- **无 LLM SDK 版本跳动**（pnpm-lock diff 无 anthropic/openai/pi-ai 相关行）。

## 不跟进项

- experimental agent-team（10 工具，dsh-base bundle 默认禁用）；ACP application bundle（独立 profile，非默认面）；webworker-runtime（上游实验）；inspector（实验包）；文档/网站/CI 面。

## 实施 staging（触发：npm 发布 0.1.2）

1. 模块图重生成 + compat report 重跑（B）；2. protocol.md v2：remote.mux + 认证层（A1-A5）；3. `http_gateway` 认证实现（HMAC/cookie/303/credentials 记录）+ remote.mux WS；4. LLM 录播与协议矩阵重录（C）；5. release golden 刷新。预估：A 面（认证+WS）为最大工程量，B/C/D 多为生成器与录播重跑。
