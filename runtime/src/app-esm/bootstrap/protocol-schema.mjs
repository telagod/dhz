// 协议通知 schema——z 面（无 literal（用 z.const）；必填字段显式 .required()；校验调用式）
const zkk = await import('@deepseek-ai/schemastery')
const z = zkk.default
globalThis.__zModProbe = typeof z + '|u:' + typeof z.union + '|c:' + typeof z.const + '|req:' + typeof z.string().required

const protoSchema = z.union([
  z.object({ op: z.union(['events', 'query', 'sandboxStatus', 'sandboxSet']), session: z.string().required() }),
  z.object({ op: z.const('emit'), type: z.string().required() }),
  z.object({ op: z.const('sandboxSet'), session: z.string().required(), mode: z.string().required() }),
  z.object({ op: z.union(['sessions', 'poll', 'subscribe', 'whoami']) }),
])

globalThis.__zVerify1 = (() => { try { const r = protoSchema({ op: 'sessions' }); return 'ok:' + typeof r } catch (e) { return 'throw:' + String(e).slice(0, 60) } })()
globalThis.__zVerify2 = (() => { try { const r = protoSchema({ op: 'events' }); return 'ok:' + typeof r } catch (e) { return 'bad:' + String(e).slice(0, 60) } })()

export { protoSchema, z }
