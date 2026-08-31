# WebUI 本体 Bringing-up 实录（rc.2 壳在 Zig 运行时上）

> 目标：3088 伺服完整 DSH WebUI——与 Node 版 3080 同形态。本文记录从零到验收的全过程、七只真 bug 的发现链与修复，以及验证矩阵。

## 架构终态

```
浏览器 ── GET / ──→ shell.html（捕获自 3080 的生成版，含 __DSH_BOOT__ 42 插件条目）
       ├─ /plugins/<pkg>/client.js ──→ vendor/web-shell/plugins/（42 个）
       ├─ /assets/* /fonts/* /langs/* ──→ vendor/web-shell/dist/（Vite 产物）
       ├─ /dsh-whale/* ──→ 吉祥物资产（image.png/rua.gif/3 个统计 json）
       ├─ /plugins/events ──→ HMR SSE（静默驻留）
       ├─ POST /api/<method> ──→ unary RPC（17 方法，client-request 全形信封）
       └─ GET /api/events.mux|host ──→ 双传输：浏览器 WS 下行 / Node SSE
```

关键认知：**rc.2 浏览器端走 WebSocket 下行**（`WebApiClient.readWebSocket`），SSE 是 Node 侧载体——同路径双传输。

## 七只真 bug（按发现顺序）

| # | Bug | 发现链 | 修复 |
|---|---|---|---|
| 1 | SSE-only 实现 | 浏览器 WS 握手拿 200 即断，客户端源码 `WebApiClient.openMux → readWebSocket` | 双传输：带 Upgrade 头走 WS，否则 SSE |
| 2 | `callGuest` conn_id=0 | 仪表 `muxWsId:0/muxPushRet:0`——guest 存 0 号 push 永不中 | 升级回调传 `entry.conn_id` |
| 3 | `MAX_ROUTES=16` 溢出 | boot 冒烟 `WsStatus` 404——静态面注册后 /ws 被静默挤掉 | 扩到 32 |
| 4 | WS 不回 pong | Node ws 库宽容不发 ping 故全绿；Firefox RFC6455 主动 ping 即断 | `parseWsFrame` 带 opcode + ping 自动回 pong |
| 5 | scale-* 会话噪音 | 53 帧 subscribed 直灌 GUI（boot 自建 50 个压力探针会话） | mux 流 + session.list 过滤探针会话 |
| 6 | HMR 404 | tcpdump 实证浏览器 TCP 直断无 close 帧 → 页面插件链 abort；扫插件网络面发现 `EventSource("/plugins/events")` 打在静态前缀路由 | exact 路由先于 prefix 注册，静默 SSE |
| 7 | whale 资产缺口 | ESM 仿真器网络足迹暴露 `/dsh-whale/last-turn.json` 等 5 个 404 | 从 3080 vendor（137 manifest 项） |

## 验证矩阵

| 层 | 手段 | 结果 |
|---|---|---|
| 资产字节 | curl 逐类 sha256 对比 | ✅ 全一致（含 b64 二进制侧车） |
| RPC 协议 | 17 方法 + 信封 schema（对齐 apiproxy 参考实现） | ✅ 全 200 ok |
| WS 传输 | RFC6455 向量 + Node 严格客户端 + Firefox 特征仿真（deflate+主动 ping） | ✅ 60s 零断 |
| 页面加载 | ESM 无头仿真（`tools/page-esm-sim.mjs`）：内联脚本→插件→GUI bundle | ✅ 零异常 |
| 连接循环+真数据 | 帧喂养仿真（FakeWebSocket 解析真帧） | ✅ 30s 零重连零 warn |
| 真浏览器渲染 | 探针（shell 注入 console.error→POST /debug/report） | ⏳ 待用户开新标签页 |

## 诊断面（常驻）

- `/debug/gateway`：unaryMiss（未实现方法追踪）/ muxWs/hostWs/hmrConns（连接计数）/ muxPushRet（推帧回执）/ reports（浏览器错误探针回报）
- `DSH_HTTP_TRACE=1`：请求级打点（含 upgrade 标记 + WS 握手全头 dump + 连接关闭事件）

## 写路径（session.prompt）

真 LLM 回合编排（rc.2 事件序）：`turn/start → user/message → step/start → assistant/chunk（block-start/text-delta/reasoning-delta/block-end 流式）→ session/title（自动）→ assistant/message → step/end → turn/end`——经 mux 实况广播。验收实录：401 chunk（reasoning+text 双块）流式到达。

## 残余边界

- v1 无工具环（GUI 回合为纯文本对话；bash 等工具执行是 v2）
- 会话导入为时点快照（Node 版后续写入不回流；重跑 `dhz-web chat` 刷新）
- settings/goal/workspace 变更类方法 → 501（unaryMiss 持续追踪）
