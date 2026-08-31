// cordis 机制级运行 checker：真实 cordis 在 quickjs 引擎中执行。
// 覆盖：模块链接（闭包）→ Context 构造（Proxy/Fiber/Reflect/Registry/Events/Logger）
//      → ctx.plugin 生命周期 → ctx.provide/get → ctx.on/emit 事件往返。
const { Context } = await import('@deepseek-ai/cordis')
const kit = await import('@deepseek-ai/cosmokit')
const anon = await import('@deepseek-ai/dsh-anonymous-user-id')

const shape = [
  'cordis=' + typeof Context,
  'cosmokit=' + typeof kit.hyphenate,
  'anonymous=' + typeof anon.getOrCreateAnonymousUserId,
].join(' ')

const ctx = new Context()
let applied = false
await ctx.plugin({
  name: 'spike',
  apply(c) {
    applied = true
    c.provide('spike.value', 42)
  },
})
const provided = String(ctx.get('spike.value'))
let heard = false
ctx.on('spike/evt', () => { heard = true })
ctx.emit('spike/evt')

globalThis.__cordisShape = shape + ' | ctx-run: ' + [
  'plugin=' + applied,
  'provided=' + provided,
  'event=' + heard,
].join(' ')
