// cordis timer 插件级 checker：真实 cordis + cordis-plugin-timer 在 quickjs 中执行，
// ctx.timeout(ctx.interval) 经宿主事件循环（timerfd→epoll→JS_Call）驱动。
// 覆盖：Service/mixin → ctx 全局 setTimeout/clearTimeout 标准名面 → 插件 fiber 清理回调。
globalThis.__step = []
globalThis.__err = null
try {
  const { Context } = await import('@deepseek-ai/cordis')
  globalThis.__step.push('cordis-imported')
  const timer = await import('@deepseek-ai/cordis-plugin-timer')
  globalThis.__step.push('timer-imported:' + typeof timer.TimerService)

  const ctx = new Context()
  globalThis.__step.push('ctx-created')
  await ctx.plugin(timer.TimerService)
  globalThis.__step.push('timer-plugin-activated')

  globalThis.__timerHits = 0
  globalThis.__intHits = 0
  await ctx.plugin({
    name: 'timer-user',
    inject: ['timer'],
    apply(c) {
      globalThis.__step.push('timer-user-apply:timeout=' + (typeof c.timeout))
      c.timeout(() => { globalThis.__timerHits += 1 }, 40)
      c.interval(() => { globalThis.__intHits += 1 }, 25)
      globalThis.__step.push('timers-scheduled')
    },
  })
  globalThis.__step.push('user-plugin-activated')
  globalThis.__armed = true
} catch (e) {
  globalThis.__err = String(e)
  globalThis.__step.push('caught:' + String(e))
}
