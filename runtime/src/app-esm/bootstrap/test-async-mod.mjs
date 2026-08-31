// 最小模块级 async（诊断驻留）：模块内 await 引擎 done——resume 面验证
import { deadline, timeoutOf } from '@deepseek-ai/dsh-timeout'
import { ShellExecutor } from '@deepseek-ai/dsh-shell'

export async function runArgvReplica(subprocess, spec) {
  const d = deadline(undefined, 5000, 'BASH_TIMEOUT')
  const s2 = { ...spec, signal: d.signal }
  const handle = subprocess.spawn(s2)
  const outcome = await handle.done
  const collected = handle.collected
  const timedOut = timeoutOf(d.signal, 'BASH_TIMEOUT') !== void 0
  try { d[Symbol.dispose]() } catch (e) {}
  return { ...outcome, timedOut, stdout: collected.stdout ? collected.stdout.readFrom(0).text : '', stderr: collected.stderr ? collected.stderr.readFrom(0).text : '' }
}

export { ShellExecutor }
