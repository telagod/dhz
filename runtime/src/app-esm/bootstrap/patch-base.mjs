// patch 层清单（cordis.patch.yml 语义子集：insert 行 { id, name, config?, disabled? }；
// `!!js <expr>` 表达式在 v1 原样为字符串保留——eval 面 v2）。
// 语义（自 bundle/base/cordis.patch.yml 注释）：last write wins per row（后层覆盖同 id 行）；
// 行序无装载语义（activation 服务可用性驱动）；disabled 行跳过。
export default [
  [ // layer 1
    { id: 'boot-sysprompt', name: 'boot-sysprompt' }, // base 行子集——本闭包包内真实行
    { id: 'boot-llm', name: 'boot-llm' }, // 路由桩（read_image 能力声明面）
    { id: 'boot-attachments', name: 'boot-attachments' }, // 图片存储（AttachmentStore 子类）
    { id: 'boot-agent-factory', name: 'boot-agent-factory' }, // agent 工厂桩（create→register 链）
    { id: 'boot-approval', name: 'boot-approval' }, // approval 桩（escalate 兑现面）



    { id: 'fs-policy', name: 'boot-fs-policy' }, // SandboxPolicyService（mode 折叠）
    { id: 'timer', name: '@deepseek-ai/cordis-plugin-timer' },
    { id: 'agent', name: '@deepseek-ai/dsh-agent' },
    { id: 'subagent', name: '@deepseek-ai/dsh-subagent' },
    { id: 'session', name: '@deepseek-ai/dsh-session' },
    { id: 'session-query', name: '@deepseek-ai/dsh-session-query-sqlite', config: { path: '/tmp/dsh-sq.db', openAt: 'startup' } },
    { id: 'tools', name: '@deepseek-ai/dsh-tools' },
    { id: 'tool-fs', name: '@deepseek-ai/dsh-tool-fs', config: { readStreamMinSize: 4096 } },
    { id: 'fs', name: '@deepseek-ai/dsh-fs-sandbox' },
    { id: 'subprocess-runtime', name: 'bootstrap/subprocess-runtime.mjs' }, // M-7 ctx.subprocess（引擎实现）
    { id: 'shell-executor', name: 'bootstrap/shell-executor.mjs', config: {} }, // M-7 ctx.shell（引擎实现）
    { id: 'tool-bash', name: '@deepseek-ai/dsh-tool-bash', config: { enableRunInBackground: true } }, // M-7 bash 工具面
    { id: 'boot-consumer', name: 'boot-consumer' },
    { id: 'title', name: 'boot-title', config: { mode: 'base' } },
    { id: 'mode', name: 'boot-mode', config: { mode: '!!js process.env.DSH_PERMISSION_MODE ?? \"workspace-write\"' } },
  ],
  [ // layer 2（overlay：last write wins by id）
    { id: 'title', name: 'boot-title', config: { mode: 'overlay' } },
    { id: 'disabled-row', name: 'boot-disabled', disabled: true },
    { id: 'disabled-js-on', name: 'boot-consumer-extra', disabled: '!!js process.platform === "win32" ? true : false' }, // linux → 装载（表达式 disabled 求值）
    { id: 'disabled-js-off', name: 'boot-consumer-extra', disabled: '!!js process.platform !== "win32" ? true : false' }, // linux → 跳过
  ],
]
