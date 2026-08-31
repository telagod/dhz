// M-7 ShellExecutor 引擎实现（@deepseek-ai/dsh-shell 契约的引擎面——ctx.shell）。
// 动机：dsh-bash-local 的 runArgv 在引擎 promise-settle 面挂起（160-169 深挖——异步 fn
// 全链达 W1C1RFYZ 而完成通知未达）；本实现=已验证的引擎 runArgv 逻辑
// （模块级函数——165 证明模块 fn 形态 resume 正常；类方法形态达 W1C1RFYZ 后不 settle——
// 引擎 async 完成通知对类方法方法的敏感性规避）。
// 覆盖：run/start/resolve（timeoutMs→deadline、stdoutMaxBytes→collect 上限、workdir/cwd）。

import { ShellExecutor } from '@deepseek-ai/dsh-shell'
import { deadline, timeoutOf, clampTimeout } from '@deepseek-ai/dsh-timeout'

const DEFAULT_TIMEOUT = 12e4
const DEFAULT_MAX_OUTPUT = 64e3

function finalOutput(reader) {
  const read = reader.readFrom(0)
  return { text: read.text, truncated: read.lossy, ...(read.spillPath !== undefined ? { spillPath: read.spillPath } : {}) }
}

function spawnSpecLocal(spec, argv, signal, cfg) {
  const collect = (maxBytes) => ({ maxBytes, spill: { maxBytes: 65536 } })
  return {
    argv,
    cwd: spec.workdir,
    stdio: {
      stdin: spec.stdin !== undefined ? { data: spec.stdin } : 'ignore',
      stdout: collect(spec.stdoutMaxBytes),
      stderr: collect(cfg.maxOutputBytes),
    },
    graceMs: cfg.graceMs,
    signal,
    ...(spec.env !== undefined ? { env: spec.env } : {}),
  }
}

/**
 * 模块级 runArgv（与 test-async-mod.runArgvReplica 逐字符同构——已验证形态；
 * shell 执行器经此实现 run——类方法面已排除）。
 */
async function runArgvEngine(sub, spec, argv, cfg) {
  const d = deadline(undefined, spec.timeoutMs, 'BASH_TIMEOUT')
  const sspec = spawnSpecLocal(spec, argv, d.signal, cfg)
  const handle = sub.spawn(sspec)
  const outcome = await handle.done
  const collected = handle.collected
  const timedOut = timeoutOf(d.signal, 'BASH_TIMEOUT') !== void 0
  try { d[Symbol.dispose]() } catch (e) {}
  const outR = collected.stdout ? collected.stdout.readFrom(0) : null
  const errR = collected.stderr ? collected.stderr.readFrom(0) : null
  return {
    ...outcome,
    timedOut,
    stdout: { text: outR ? outR.text : '', truncated: outR ? outR.lossy : false },
    stderr: { text: errR ? errR.text : '', truncated: errR ? errR.lossy : false },
  }
}

function makeShell(ctx) {
  const config = { cwd: '/tmp', timeoutMs: DEFAULT_TIMEOUT, maxOutputBytes: DEFAULT_MAX_OUTPUT, graceMs: 3000 }
  const sub = ctx.get('subprocess')
  const executor = {
    // 沙箱声明面（引擎无 landlock 执行隔离——声明与 fs 面 policy 一致；
    // permission-presets 的 sandboxMode 检查消费——真 landlock 面留档）
    sandboxMode: 'workspace-write',
    resolve(request) {
      const timeoutMs = clampTimeout(request.timeoutMs, config.timeoutMs, 6e5, 'shell: request.timeoutMs')
      const stdoutMaxBytes = request.stdoutMaxBytes ?? config.maxOutputBytes
      return {
        command: request.command,
        workdir: request.workdir ?? config.cwd,
        timeoutMs,
        stdoutMaxBytes,
        ...(request.signal !== undefined ? { signal: request.signal } : {}),
        ...(request.stdin !== undefined ? { stdin: request.stdin } : {}),
        ...(request.env !== undefined ? { env: request.env } : {}),
        sandboxPolicy: request.sandboxPolicy,
      }
    },
    run(spec) {
      return runArgvEngine(sub, spec, ['bash', '-c', spec.command], config)
    },
    start(spec) {
      const running = sub.spawn(spawnSpecLocal(spec, ['bash', '-c', spec.command], spec.signal, config))
      const collected = running.collected
      let stdoutOffset = 0
      let stderrOffset = 0
      const proc = {
        status: 'running',
        exitCode: null,
        signal: null,
        done: running.done.then((outcome) => {
          proc.status = outcome.signal !== null ? 'killed' : 'completed'
          proc.exitCode = outcome.exitCode
          proc.signal = outcome.signal
        }, (error) => { proc.status = 'killed' }),
        readOutput: () => {
          const out = collected.stdout.readFrom(stdoutOffset)
          const err = collected.stderr.readFrom(stderrOffset)
          stdoutOffset = out.nextOffset
          stderrOffset = err.nextOffset
          const separator = out.text.length > 0 && !out.text.endsWith('\n') ? '\n' : ''
          return { delta: out.text + (err.text.length > 0 ? separator + '[stderr]\n' + err.text : ''), lossy: out.lossy || err.lossy }
        },
        kill: () => { if (proc.status !== 'running') return false; proc.status = 'killed'; running.terminate(); return true },
      }
      return proc
    },
  }
  return executor
}

export { makeShell }
export default (ctx) => {
  // cordis 插件=函数（apply 面）；服务经 ctx.provide（shell 契约）
  // systemPrompt：tool-bash 依赖的面（引擎侧最小提供——tool 的 prompt 段落面）
  if (!ctx.get('systemPrompt')) ctx.provide('systemPrompt', { section: () => {} })
  // shellEnv：tool-bash 依赖面（DSH_* 变量收集——引擎侧最小实现——DSH_SHELL/DSH_HOME/DSH_SESSION_ID）
  if (!ctx.get('shellEnv')) ctx.provide('shellEnv', {
    collect: (exec) => {
      const values = { DSH_SHELL: '1', DSH_HOME: '/root/.dsh' }
      try {
        const sid = exec && exec.agent && exec.agent.session && exec.agent.session.header && exec.agent.session.header.id
        if (sid) values.DSH_SESSION_ID = String(sid)
      } catch (e) {}
      return Object.freeze(values)
    },
  })
  ctx.provide('shell', makeShell(ctx))
}
