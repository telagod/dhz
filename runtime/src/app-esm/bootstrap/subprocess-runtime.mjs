// M-7 SubprocessRuntime 引擎实现（@deepseek-ai/dsh-subprocess 抽象契约的引擎面）。
// 主机基元：dshServices.proc.spawn（proc_bridge —— fork/setsid/3 管道/execvp + envp + landlock）。
// 形态纪律（引擎实测）：**纯工厂 + 闭包**（闭包↔var_ref 环在 quickjs-ng 环收集面
// 不被回收——类实例/模块级队列持有者会留一个 bytecode function 引用——ABRT 泄漏断言；
// 工厂形态与 raw 桥验证面同构）。done= thenable 信号（无 Promise 环——同因规避）。
// 覆盖：spawn（pipe/collect stdio）、resolveExecutable（PATH 扫描 fs.stat + X_OK）、
//       terminate 升级链（TERM→graceMs→KILL）。spawnTerminal（PTY）——排期（throw NotImplemented）。
// 语义对齐（dsh-subprocess）：env = scrubbedParentEnv() + spec.env（显式合并；undefined 墓碑删除）；
// done 在进程关闭时以 { exitCode, signal } 结算；stdin/out/err=pipe 原样交由调用方。

import { SubprocessRuntime, scrubbedParentEnv } from '@deepseek-ai/dsh-subprocess'

const PUMP_MS = 15

/** 无 Promise 环的 done 信号（thenable——await/消费者 .then 均兼容）。 */
function makeDoneSignal() {
  const s = { _fn: null, _rej: null, _settled: false, _failed: false, _outcome: null }
  s.then = (res, rej) => {
    s._fn = res
    if (rej) s._rej = rej
    if (s._settled) { const f = s._fn; s._fn = null; f(s._outcome) }
    else if (s._failed && s._rej) { const g = s._rej; s._rej = null; g(s._err) }
    return s
  }
  s.catch = (fn) => { s._catchFn = fn; return s }
  s.settle = (o) => {
    s._settled = true
    s._outcome = o
    if (s._fn) { const f = s._fn; s._fn = null; f(o) }
  }
  s.fail = (e) => {
    s._failed = true
    s._err = e
    if (s._rej) { const g = s._rej; s._rej = null; g(e) }
    else if (s._catchFn) { s._catchFn(e); s._catchFn = null }
  }
  return s
}

/** 最简监听器集（无 Map——纯对象数组；引擎收集面保守）。 */
function makeListeners() {
  const h = {}
  return {
    on(name, fn) { (h[name] ??= []).push(fn); return this },
    emit(name, v) { const a = h[name]; if (a) for (const fn of [...a]) { try { fn(v) } catch (e) {} } },
  }
}

const _pumpQueue = []
function _pumpDispatch() {
  const st = _pumpQueue.shift()
  if (st && st.running && !st.resolved) st.pumpAndSchedule()
}

function mergeEnv(specEnv) {
  const env = {}
  Object.assign(env, scrubbedParentEnv())
  if (specEnv) {
    for (const [k, v] of Object.entries(specEnv)) {
      if (v === undefined) delete env[k]
      else env[k] = String(v)
    }
  }
  const out = []
  for (const [k, v] of Object.entries(env)) out.push(k + '=' + v)
  return out
}

/**
 * collect 收集端：内存缓冲（maxBytes tail 保留——溢出丢头并记 dropped）
 * + readFrom(fromByte) 偏移读面（独立读不互相消费——lossy 报丢头）。
 */
function makeCollector(raw, name, maxBytes) {
  let buf = ''
  let dropped = 0
  const cap = typeof maxBytes === 'number' && maxBytes > 0 ? maxBytes : 64 * 1024
  return {
    _pump() {
      let c = ''
      try { c = raw.read(name) } catch (e) { return }
      if (c.length) {
        buf += c
        if (buf.length > cap) {
          dropped += buf.length - cap
          buf = buf.slice(buf.length - cap)
        }
      }
    },
    readFrom(fromByte) {
      const base = dropped
      if (fromByte < base) {
        return { text: buf, nextOffset: base + buf.length, lossy: true }
      }
      if (fromByte <= base + buf.length) {
        const at = fromByte - base
        return { text: buf.slice(at), nextOffset: base + buf.length, lossy: false }
      }
      return { text: '', nextOffset: fromByte, lossy: false }
    },
  }
}

function makeSpawnHandle(spec, raw) {
  const mode = { stdin: 'pipe', stdout: 'pipe', stderr: 'pipe', ...(spec.stdio ?? {}) }
  const done = makeDoneSignal()
  const isCollect = (m) => m === 'collect' || (m && typeof m === 'object' && typeof m.maxBytes === 'number')
  const collectCap = (m) => (m && typeof m === 'object' && typeof m.maxBytes === 'number') ? m.maxBytes : 64 * 1024
  const cOut = isCollect(mode.stdout) ? makeCollector(raw, 'out', collectCap(mode.stdout)) : null
  const cErr = isCollect(mode.stderr) ? makeCollector(raw, 'err', collectCap(mode.stderr)) : null
  const outL = makeListeners()
  const errL = makeListeners()
  const st = {
    closedIn: false,
    exited: false,
    resolved: false,
    termRequested: false,
    outcome: null,
    running: true,
    pid: raw.pid,
    // —— 句柄面（this 方法；零捕获——引擎收集面：闭包环不回收）
    readOut() { try { return raw.read('out') } catch (e) { return '' } },
    readErr() { try { return raw.read('err') } catch (e) { return '' } },
    pump() {
      if (!this.running) return true
      if (cOut) cOut._pump()
      if (cErr) cErr._pump()
      let w = 0
      try { w = raw.wait() } catch (e) { w = -1 }
      if (w === 1) {
        const code = (() => { try { return raw.code() } catch (e) { return -1 } })()
        const sig = (() => { try { return raw.termsig() } catch (e) { return 0 } })()
        const names = ['', 'HUP', 'INT', 'QUIT', 'ILL', 'TRAP', 'ABRT', 'BUS', 'FPE', 'KILL', 'USR1', 'SEGV', 'USR2', 'PIPE', 'ALRM', 'TERM']
        this.outcome = { exitCode: code >= 0 ? code : null, signal: sig > 0 ? (names[sig] ? 'SIG' + names[sig] : 'SIG' + sig) : null }
        const tail = this.readOut()
        if (tail.length) { if (cOut) cOut._pump(); if (mode.stdout === 'pipe') outL.emit('data', tail) }
        this.running = false
        return true
      }
      if (w < 0) {
        this.outcome = { exitCode: 1, signal: null }
        this.running = false
        return true
      }
      return false
    },
    settle() {
      if (!this.resolved) {
        this.resolved = true
        done.settle(this.outcome)
      }
      const qi = _pumpQueue.indexOf(this)
      if (qi >= 0) _pumpQueue.splice(qi, 1)
      this.running = false
    },
    pumpAndSchedule() {
      if (this.pump()) { this.settle(); return }
      if (_pumpQueue.indexOf(this) < 0) _pumpQueue.push(this)
      globalThis.setTimeout(_pumpDispatch, PUMP_MS)
    },
    terminate() {
      if (this.exited || this.termRequested) return
      this.termRequested = true
      try { raw.terminate() } catch (e) {}
      const grace = Number(spec.graceMs) > 0 ? Number(spec.graceMs) : 300
      globalThis.setTimeout(() => { if (!this.exited && !this.resolved) { try { raw.kill() } catch (e) {} } }, grace)
    },
    waitForExit(signal) {
      if (signal && signal.aborted) return false
      return done.then(() => true)
    },
    close() { try { raw.close() } catch (e) {} },
  }
  const handle = {
    pid: raw.pid,
    done,
    stdin: mode.stdin === 'pipe' ? {
      write(d) { if (st.closedIn) return false; const ok = (() => { try { return raw.write(String(d)) } catch (e) { return false } })(); if (!ok) st.closedIn = true; return ok },
      end() { if (!st.closedIn) { try { raw.endIn() } catch (e) {} ; st.closedIn = true } },
      closed: false,
    } : undefined,
    stdout: mode.stdout === 'pipe' ? { read: () => st.readOut(), on: (n, f) => outL.on(n, f) } : undefined,
    stderr: mode.stderr === 'pipe' ? { read: () => st.readErr(), on: (n, f) => errL.on(n, f) } : undefined,
    collected: {
      ...(cOut ? { stdout: cOut } : {}),
      ...(cErr ? { stderr: cErr } : {}),
    },
    terminate() { st.terminate() },
    waitForExit(signal) { return st.waitForExit(signal) },
    close() { st.close() },
  }
  // stdin {data}：写并发 endIn（executor 的管道输入面）
  if (mode.stdin && typeof mode.stdin === 'object' && typeof mode.stdin.data === 'string') {
    try { raw.write(mode.stdin.data); raw.endIn() } catch (e) {}
    st.closedIn = true
  }
  _pumpQueue.push(st)
  globalThis.setTimeout(_pumpDispatch, PUMP_MS)
  if (spec.signal?.aborted) st.terminate()
  if (spec.signal && typeof spec.signal.addEventListener === 'function') spec.signal.addEventListener('abort', () => st.terminate())
  return handle
}

export default class EngineSubprocessRuntime extends SubprocessRuntime {
  /**
   * 引擎实现：spawn 立即返回活句柄；done 在进程关闭时以 { exitCode, signal } 结算；
   * stdin/out/err=pipe 原样；collect 面（内存缓冲 + readFrom 偏移读）。
   * terminate=TERM→grace→KILL（进程组）。spawnTerminal（PTY）——排期（后续：PTY 引擎）。
   */
  spawn(spec) {
    const argv = [...spec.argv]
    if (!argv.length) throw new Error('subprocess: argv must contain a program')
    const envArr = mergeEnv(spec.env)
    let raw
    try {
      raw = globalThis.dshServices.proc.spawn(argv, envArr.length === 0 ? undefined : envArr)
    } catch (e) {
      const done = makeDoneSignal()
      const h = { pid: -1, done, terminate() {}, waitForExit() { return done.then(() => true) }, close() {} }
      done.fail(e)
      return h
    }
    return makeSpawnHandle(spec, raw)
  }

  async resolveExecutable(command, env, signal) {
    if (!command) throw new Error('subprocess: executable must be non-empty')
    signal?.throwIfAborted()
    const isAbs = command.startsWith('/')
    if (!isAbs && command.includes('/')) {
      throw new Error(`subprocess: command ${JSON.stringify(command)} is a relative path; use an absolute path or a bare PATH name`)
    }
    const envBase = env ?? globalThis.process.env
    const path = envBase && envBase.PATH ? envBase.PATH : '/usr/bin:/bin'
    const candidates = isAbs ? [command] : path.split(':').map((d) => (d ? d + '/' + command : command))
    for (const candidate of candidates) {
      signal?.throwIfAborted()
      try {
        const st = globalThis.dshServices.fs.stat(candidate)
        if (st.kind === 'file' && (st.mode & 0o111) !== 0) return candidate
      } catch (e) { /* 下一候选 */ }
    }
    signal?.throwIfAborted()
    throw new Error(isAbs
      ? `subprocess: command ${JSON.stringify(command)} is not an executable file`
      : `subprocess: command ${JSON.stringify(command)} was not found on PATH`)
  }

  spawnTerminal() {
    throw new Error('subprocess: spawnTerminal (PTY) not implemented in engine runtime')
  }
}
