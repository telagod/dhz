// cordis 服务注入面 checker：dshServices（宿主服务对象树）→ cordis 服务。
// host-service-bridge 插件 provide('fs'/'timer') → svc-consumer 插件
// inject: ['fs','timer'] → apply 中 c.fs.* / c.timer.* 直通宿主。
// 覆盖：provide/inject/消费时序 + 宿主事件循环 + fs 回环。
globalThis.__step = []
globalThis.__err = null
try {
  const { Context } = await import('@deepseek-ai/cordis')
  const ctx = new Context()
  await ctx.plugin({
    name: 'host-service-bridge',
    apply(c) {
      c.provide('dshFs', {
        readText: (p) => dshServices.fs.readText(p),
        writeText: (p, s) => dshServices.fs.writeText(p, s),
        size: (p) => dshServices.fs.size(p),
      })
      c.provide('timer', {
        setTimeout: (cb, ms) => dshServices.timer.setTimeout(cb, ms),
      })
      c.provide('proc', {
        run: (cmd, args) => dshServices.proc.run(cmd, args),
      })
      c.provide('sqlite', {
        open: (p) => dshServices.sqlite.open(p),
        exec: (id, sql) => dshServices.sqlite.exec(id, sql),
        run: (id, sql, params) => dshServices.sqlite.run(id, sql, params),
        all: (id, sql, params) => dshServices.sqlite.all(id, sql, params),
        close: (id) => dshServices.sqlite.close(id),
      })
      c.provide('http', {
        start: (p) => dshServices.http.start(p),
        handle: (p, fn, e) => dshServices.http.handle(p, fn, e),
        request: (p, path) => dshServices.http.request(p, path),
        stop: () => dshServices.http.stop(),
      })
    },
  })
  globalThis.__step.push('bridge-provided')
  const dshFsLocal = await import('@deepseek-ai/dsh-fs-local')
  globalThis.__step.push('dsh-fs-local-imported:' + typeof dshFsLocal.default)
  await ctx.plugin(dshFsLocal.default)   // LocalFileSystem（真实 fs 后端）→ provide 'fs'
  globalThis.__step.push('dsh-fs-local-activated')
  const agentMod = await import('@deepseek-ai/dsh-agent')
  await ctx.plugin(agentMod.default)
  globalThis.__step.push('agent-activated')
  await ctx.plugin({
    name: 'agent-consumer',
    inject: ['agents'],
    apply(c) {
      globalThis.__agentType = typeof c.agents
      globalThis.__agentName = (c.agents && c.agents.name) || ''
    },
  })
  globalThis.__step.push('agent-consumer-activated')
  // node 面实名化：node:fs 经 stub 直连 dshServices.fs（宿主真实现）→ 真实文件 IO
  const nfs = await import('node:fs')
  nfs.mkdirSync('/tmp/dsh-ns')
  nfs.writeFileSync('/tmp/dsh-ns/hello.txt', 'node-fs-ok')
  globalThis.__nodeFs = nfs.readFileSync('/tmp/dsh-ns/hello.txt')
  globalThis.__step.push('node-fs-realio')
  await ctx.plugin({
    name: 'svc-consumer',
    inject: ['dshFs', 'fs', 'timer', 'http', 'proc', 'sqlite'],
    apply(c) {
      globalThis.__step.push('consumer-apply:dshFs=' + typeof c.dshFs + ',fs=' + typeof c.fs + ',timer=' + typeof c.timer)
      globalThis.__dshFsInst = !!(c.fs && 'sandboxMode' in c.fs && c.fs.name === 'fs')
      globalThis.__fsByName = (c.fs && c.fs.name) || ''
      c.dshFs.writeText('/tmp/dsh-cordis-svc.txt', 'via-cordis')
      globalThis.__svcRead = c.dshFs.readText('/tmp/dsh-cordis-svc.txt')
      c.timer.setTimeout(() => { globalThis.__svcTick = 3; }, 30)
      globalThis.__svcProc = c.proc.run('echo', ['via-cordis']).stdout
      globalThis.__repDb = c.sqlite.open('/tmp/dsh-report.db')
      c.sqlite.exec(__repDb, 'create table if not exists r (k text, v text)')
      c.sqlite.run(__repDb, 'delete from r')
      c.sqlite.run(__repDb, 'insert into r (k, v) values (?, ?)', ['ts', 'cordis'])
      globalThis.__repRow = c.sqlite.all(__repDb, 'select v from r where k = ?', ['ts'])[0].v
      c.http.start(18082)
      c.http.handle('/echo', (p) => 'cordis-http:' + p)
      globalThis.__svcHttp = c.http.request(18082, '/echo')
      c.http.stop()
    },
  })
  globalThis.__step.push('consumer-activated')
  await ctx.plugin({
    name: 'dsh-report-persist',
    inject: ['dshFs', 'timer', 'proc', 'sqlite'],
    apply(c) {
      // 真实业务流：报告持久化（fs）+ 心跳（timer）+ 幂等 DB 记录（sqlite）+ 进程调用（proc）
      c.dshFs.writeText('/tmp/dsh-report.txt', 'report:{ts:1}')
      globalThis.__reportRead = c.dshFs.readText('/tmp/dsh-report.txt')
      globalThis.__procCode = c.proc.run('sh', ['-c', 'exit 7']).code
      c.sqlite.run(globalThis.__repDb, 'insert into r (k, v) values (?, ?)', ['src', 'report-persist'])
      c.timer.setTimeout(() => { globalThis.__hb = 1; }, 25)
      globalThis.__step.push('report-persist-applied')
    },
  })
  globalThis.__step.push('report-persist-activated')
  globalThis.__armed = true
} catch (e) {
  globalThis.__err = String(e)
  globalThis.__step.push('caught:' + String(e))
}
