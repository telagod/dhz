# protocol.md — WebUI 冻结协议台账（v0.1）

> **基线声明（2026-08-30）**：本台账对齐 **npm 已发布 0.1.1-rc.2**（出货基线不变）。上游 master（v0.1.2-alpha.1，未发布）已发生破坏性协议变更——WS 下链改 `/api/remote.mux`、ApiProxy 删除、新增浏览器令牌认证层（HMAC cookie + `?token` 303 交换，PRIVILEGED_METHODS 废除）——登记于 [upstream-sync-0.1.2.md](upstream-sync-0.1.2.md)，实施触发条件 = npm 发布 0.1.2。

> 依据：deepseek-harness @0.1.1-rc.2 源码提取，全部来自 `packages/client/*`、`packages/api/*`、`packages/host/*`。
> 原则（决策 #2）：**WebUI 零改动** ⇒ 以下协议在 Zig 宿主侧必须**逐字节一致**。本文是实现的规范来源，也是差分测试的锚点。
> 行规：每条给 `常量 + 源码位置 + 语义`；改动协议必须改到这里（双端同步）。

## 1. HTTP 载体（client-connection / webserver / frontend-static / client-modules）

| 项 | 值 | 源码 | 语义 |
|---|---|---|---|
| API 前缀 | `/api` | `packages/client/connection/src/api-path.ts:8` | 全部远程调用走此前缀 |
| MUX 事件下链 | `/api/events.mux` | `api-path.ts:11` | WebSocket 升级路径（mux 帧流） |
| HOST 事件下链 | `/api/events.host` | `api-path.ts:14` | WebSocket 升级路径（host 帧流） |
| GET 到 events 路径 | `426 Upgrade Required` + `connection: Upgrade, upgrade: websocket` | `connection/src/index.ts:150-155` | 非升级请求的固定应答 |
| 模块加载前缀 | `/plugins`（prefix，`serveBundle`） | `client/modules/src/index.ts:340` | Web 插件表 bundle 路由 |
| 静态站点 | `/`（index.html）+ Vite 资产（hash 文件名） | `host/frontend-static` | 原 dist 打包进二进制 |
| 探针路径 | `/__dsh_invariant_probe__`（仅测试） | `host/webserver/src/invariant.ts:39` | 不纳入 Zig 产品面 |

**WebRoute 契约**（`host/webserver/src/index.ts:42-56`）：

```ts
interface WebRoute {
  kind: 'exact' | 'prefix'          // 唯一路由形态
  path: string                       // 绝对路径，无尾斜杠
  handler: (req, res) => void | Promise<void>   // 可持有响应（SSE）
}
interface WebUpgradeRoute {
  path: string
  handler: (req, socket, head) => void | Promise<void>
}
```

监听配置：`host: '127.0.0.1' | '0.0.0.0'`，`port: number`（0 = 系统分配）。

## 2. 受信请求（isTrustedApiRequest）

- `/api` 路由、两个 WS 升级、`/plugins`：全部经 `isTrustedApiRequest(req, trustedHosts) == false` ⇒ 403 / 拒绝升级。
- **`PRIVILEGED_METHODS` 全集（逐字提取，`connection/src/index.ts:89-119`）——Zig 侧必须原样搬**：

```
agentPreset.read | agentPreset.copy | agentPreset.openDocument | agentPreset.remove
host.pickDirectory | host.openPath
settings.describe | settings.openDocument | settings.update | settings.replace | settings.mutate
credentials.describe | credentials.set | credentials.unset
llm.discoverModels          （共 16 个）
```

- 语义：非受信请求调用这些方法 → 403；受信判定来自 `isTrustedApiRequest`（来源/header 校验；`trustedHosts` 解析）。

## 2.6 /api 桥接语义（http-bridge.ts，逐字语义）

- **请求侧**：完整缓冲请求体（`content-length` 超限 → `413 { connection: close }` + destroy）；构造 WHATWG `Request`（基准 URL `http://dsh.internal`），`signal` 挂 **ServerResponse 'close'** 而非 IncomingMessage——Node 16 起请求体消费完即触发请求 close，会误杀 SSE；`writableEnded` 区分正常结束与客户端离开。
- **响应侧**：`for await (chunk of response.body)` → `res.write(chunk)`，返回 false 时等待 `drain`/`close`（**背压**）；SSE 性由 handler 保持响应开流 + 分块传输天然实现，桥本身无 event-stream 帧处理。
- **Zig 实现要求**：fetch Response.body 支持 async 迭代；chunked 传输编码；写背压（暂停/恢复）；客户端断开→中止上游流。以这段桥代码为语义基准，web 快照测试直接验证。

## 3. WS 下链帧协议（WebSocketDownlinks）

- 帧 = `RpcRequest<Frame>`：`{ rpcId, method: frame.payload.type, payload }`，JSON 序列化后 `socket.send(...)`（`websocket-downlink.ts:12-29`）。
- 两种流：`mux`（多路复用事件流）与 `host`（宿主事件流）；`payload.type` 是事件/方法名；`type: 'server-request'` 包装；`stream/error` 为载荷错误类型。
- 背压/关闭：socket 关闭后拒绝发送；服务器侧维护帧泵（frame pump）。
- Zig 实现：RFC6455 服务端 + JSON 帧编解码；**帧结构必须逐字一致**（浏览器端在 `client/connection/src/client/*`，不可改）。
- 注意：`MuxFrame`/`HostFrame` 具体字段定义随客户端 SDK 类型导出（`RpcRequest` 携带 `rpcId`），实现时以 `client/connection/src/client/*` + sdk 类型声明为准。
- **MuxFrame = 判别联合**：`type` 变体如 `approval/requested`、`question/requested`、`stream/error` 等（定义在 `@deepseek-ai/dsh-sdk-protocol`；`host/apiproxy/src/api-proxy.ts:42` 引入、`:421/:631` 订阅/发出）。浏览器端每条事件流都骑 mux 帧。**完整联合提取 = TODO**（类型由 generator 产出，以 sdk 产物为准）。

## 2.5 浏览器信任栅栏（api-request-trust）

- `isTrustedApiRequest` / `assertTrustedAuthority` 实现在 `packages/client/connection/src/api-request-trust.ts`（DNS-rebinding 防护：仅受信 authority 可访问 `/api` 与升级路径）。
- Zig 侧：**逐函数语义移植**（host 头校验、loopback/LAN 判定、trustedHosts 解析），测试以 api-request-trust 单测为基准。

## 4. 远程 API（api-gateway / api-remotes / apiproxy）

- `/api/<method>` 由 `apiProxy.respond(ClientResponse)` 分发（`api-gateway` 的 method → service 路由表）；`api-remotes` 是浏览器可见远程声明。
- **事件 allowlist 全集（逐字提取，`api/remotes/src/remote-events.ts:1-13`）**：

```
agent-preset/selected, commands/change, credentials/reference-updated,
cordis/request-run, cordis/request-run-resolved, cordis/dynamic-package,
cordis/dynamic-retract, cordis/inspect-query, cordis/inspect-query-resolved,
llm/adapters-updated, settings/document-updated     （共 11 个）
```

- 注意：动态 cordis 的事件在两个地方出现——`remote-events.ts` 的转发名单里是 `cordis/dynamic-package` / `cordis/dynamic-retract`（即 host-runner README 中的 `dynamicCordisRunner/package/retract` 的线名），`request-run` 同名。实现时以该清单为准。
- apiproxy：`fflate` gzip 压缩响应（纯 JS，无需 Zig 重写，但响应解压路径要一致）。

## 5. client-modules（WebBootGraph）

- `ctx.clientModules.graph(): WebBootGraph` + `clientPath(id)` + `rebuilt(id)`——插件表的增量扫描与 bundle 路由（`/plugins`）。
- **`/plugins` 响应头（逐字，`client/modules/src/index.ts:556-557`）**：`content-type: text/javascript; charset=utf-8`（sourcemap 为 `application/json; charset=utf-8`）+ `cache-control: no-cache`；URL 带 rev 查询串做 cache-busting；包元数据按名缓存、插件集合变更需重启。
- Zig 侧：静态服务这些头语义；`graph()/clientPath()` 逻辑为纯 JS 上层，不需重写。

## 6. 动态 cordis wire（cordis-host-runner / cordis-client-runner）

| 事件 | 方向 | 载荷 |
|---|---|---|
| `cordis/request-run` | host→browser | `{requestId, agentId, id, name, purpose}`（元数据，永不带代码） |
| `cordis/request-run-resolved` | browser→host→browser | `{requestId, outcome}` |
| `dynamicCordisRunner/package` | host→browser | `{id, name, rev}` |
| `dynamicCordisRunner/retract` | host→browser | `{id, rev}` |
| `harness.handle` invoke（`host.call`） | browser→host | package 私有方法名 + JSON 参数 |

- 代码永不经事件传递；host 半部经 `runHostHalf`、browser 半部经 `getClientCode` 单播。
- 拒绝原因枚举：`definition-missing | host-half-failed | client-half-failed | rejected | cancelled | not-running`。

## 7. 目录选择器（directory-picker / browse / native）

- `ctx.directoryPicker.capability(): DirectoryPickerCapability`（native / browse / auto 等）。
- browse 实现是服务端目录扫描（`host/directory-picker-browse/src/index.ts:296`：`{path, home, crumbs, entries, truncated}` 结构）；native 是 win32 对话框（koffi，M5 替换）。
- Zig 侧：browse 的 `entries/truncated` 结构与排序语义一致；native 延后。

## 8. 会话投影与事件流（session-query / projections）

- 浏览器读取的是**投影快照**（`sessionProjectionCache.cachedSnapshot` / `coldSnapshot`），非原始事件流。
- **投影 wire 键（宿主侧注册，`SessionProjectionMap` 模块扩展）**：`goal`（GoalProjection|null，last-wins）、`plan`（PlanProjection）、`todos`（TodoItem[]|null）、`subagentTiming`、`subagent`（SubagentIdentityProjection|null）——来源文件：`goal/goal/src/types.ts:106`、`plan/plan-mode/src/types.ts:25`、`todo/tool-todo/src/types.ts:19`、`subagent/subagent/src/projection-types.ts:50`。浏览器端还有客户端包扩展的键（以 web 产物为准）。
- Zig 侧：只需保证会话事件与投影**数据格式**兼容（sqlite/jsonl schema 不变），无需复刻投影实现。

## 9. 校验手段（当前可用的差分测试）

| 层 | 已有基建 |
|---|---|
| 浏览器端快照 | `vitest.web.config.ts` 快照套件（playwright）——在 Zig host 上跑**同一 URL** |
| API 协议 | `packages/examples/acp-demo`、`acp-snapshot`（录播） |
| 状态格式 | `differential.spec.ts`（sqlite vs jsonl vs memory）——扩展为 Node vs Zig |
| 动态 cordis | `cordis-host-runner` 单元套件 + 本会话探针（`compat_probe`） |

## TODO（下一轮扩展）

- [x] PRIVILEGED_METHODS 清单逐字提取（16 个，§2）
- [x] api-remotes allowlist 全集提取（11 个，§4）
- [x] `/plugins` 响应头（§5）；信任栅栏来源定名（§2.5）；/api 桥接语义（§2.6）；投影 wire 键（§8）
- [ ] MuxFrame/HostFrame 判别联合完整字段 —— **由 generator 产出的 sdk 产物**（`dsh-sdk-protocol` 发布物），从打包产物提取，不追手写源码
- [ ] 浏览器端投影扩展键（随 web 构建产物）
