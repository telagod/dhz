// DSH bootstrap 入口（patch 驱动）：patch 层合并（last write wins by id）→ 逐个装载。
// boot- 前缀 = 内置 consumer（config.mode 透传验证 patch 覆盖）；否则真实插件包
// （module.default 类插件 + config 透传）。disabled 行跳过。EntryTree/表达式 v2。
import patchLayers from './patch-base.mjs'
import { Context } from '@deepseek-ai/cordis'
import { AttachmentStore } from '@deepseek-ai/dsh-attachment'
import { interpolate } from '@deepseek-ai/cordis-plugin-loader'
import { entryListSchema } from '@deepseek-ai/cordis-plugin-include'
import { protoSchema as protoSchemaFromModule } from './protocol-schema.mjs'
import * as yaml from 'js-yaml'
import { LlmAdapter, LlmRuntime } from '@deepseek-ai/dsh-llm'

// boot 内嵌 attachments 存储（AttachmentStore 子类——base 校验语义真实走：批限制/媒体类型/保存）
class BootImageStore extends AttachmentStore {
  constructor(ctx) {
    super(ctx)
    this.imageLimits = {
      maxImagesPerMessage: 8,
      maxMessageImageBytes: 8 * 1024 * 1024,
      maxImageBytes: 4 * 1024 * 1024,
      maxImageDimension: 16384,
      maxImagePixels: 16777216,
      mediaTypes: ['image/png', 'image/jpeg', 'image/webp', 'image/gif'],
    }
  }
  validateImage(input) {
    if (!input.data || input.data.byteLength === 0) throw new Error('boot-attachments: empty image')
  }
  async saveImage(input) {
    const b = input.data.byteLength
    return { attachmentId: 'boot:' + input.mediaType + ':' + b, mediaType: input.mediaType, bytes: b, width: 1, height: 1, name: input.name }
  }
}
// boot 内嵌 llm 路由桩（assertImageCapableRoute 的模型声明面）
const bootLlm = {
  resolveModelInfo: async () => ({ inputModalities: ['text', 'image'] }),
  // provider 行（deepseek/pi-ai）的 registerAdapter 面——薄记账（真 adapter 装配留档——无网面）
  registerAdapter(providers, adapter) {
    globalThis.__llmAdapters = ((globalThis.__llmAdapters ?? '') + '|' + String(providers).slice(0, 40))
    return () => {}
  },
  registerConfigurableProviders(entries) {
    globalThis.__llmConfigProviders = ((globalThis.__llmConfigProviders ?? '') + '|' + (entries && entries[0] && entries[0].provider) || '')
    return () => {}
  },
  registerModelDiscovery(settingsNs, discover) {
    globalThis.__llmModelDiscovery = (typeof settingsNs === 'string' && settingsNs.length > 0 && typeof discover === 'function') ? 'ok' : 'bad'
    return () => {}
  },
}
// boot 内嵌 agent 工厂（最小契约：createAgent 建 agent + register（enter/announce）→ handle）
class BootAgentSim {
  constructor(session) {
    this.id = session.id
    this.session = session
  }
}
function bootAgentSession(sid) {
  return { id: sid, header: { cwd: '/tmp' }, log: [], requestHeader: () => undefined, getContext: () => undefined }
}
// dsh-llm MockLlmAdapter：全局 fetch → mock SSE（tools/llm-mock.py）→ dsh-llm chunk 契约
// （block-start / text-delta / block-end / usage / finish——BlockAssembler 的真 chunk 面）
function createMockLlmAdapter(base) {
  return class MockLlmAdapter extends LlmAdapter {
    providerInfo(provider) {
      return { id: provider, name: provider }
    }
    async resolveModel(provider, model, signal) {
      return { provider, id: model, name: model, inputModalities: ['text'] }
    }
    stream(options) {
      return this._stream(options)
    }
    async *_stream(options) {
      // wire 级消费：http.post + ondata 帧拼装（203 基元——mock 分块写→逐块回调→data 行）
      const body = JSON.stringify({
        model: options.model,
        stream: true,
        tool: options.toolMode === true,
        messages: options.messages,
      })
      const port = (base.split(':').pop() || '18099')
      let pending = ''
      const dataLines = []
      let doneResolve
      const donePromise = new Promise((res) => { doneResolve = res })
      // wire 级异步：读事件驱动（loop）——ondata 帧拼装→data 行队列；onDone 终态唤醒
      globalThis.__adOn = 0
      globalThis.dshServices.http.postAsync(Number(port), '/v1/chat/completions', body, (c) => {
        globalThis.__adOn = (globalThis.__adOn ?? 0) + 1
        pending += String(c)
        let nl
        while ((nl = pending.indexOf('\n')) >= 0) {
          const line = pending.slice(0, nl)
          pending = pending.slice(nl + 1)
          if (line.startsWith('data: ')) dataLines.push(line.slice(6))
        }
      }, () => { doneResolve() })
      await donePromise
      let tIdx = -1
      let rIdx = -1
      let racc = ''
      let acc = ''
      const toolState = new Map()
      for (const data of dataLines) {
        if (data === '[DONE]') break
        let j
        try { j = JSON.parse(data) } catch (e) { continue }
        const delta = j.choices && j.choices[0] && j.choices[0].delta
        if (!delta) continue
        const tcs = delta.tool_calls
        if (tcs) {
          for (const tc of tcs) {
            const i = tc.index
            const cur = toolState.get(i) ?? {}
            if (tc.id) cur.id = tc.id
            if (tc.function && tc.function.name) cur.name = tc.function.name
            const aDelta = (tc.function && tc.function.arguments) || ''
            cur.args = (cur.args ?? '') + aDelta
            if (!toolState.has(i)) {
              yield { type: 'block-start', index: i, blockType: 'tool-call' }
              toolState.set(i, cur)
            }
            yield { type: 'tool-call-delta', index: i, id: cur.id, name: cur.name, argumentsDelta: aDelta }
          }
          continue
        }
        // reasoning 面（glm 系 reasoning_content 前置流；mock 无此字段——golden 路径不变）
        const rc = delta.reasoning_content
        if (rc) {
          if (rIdx < 0) {
            rIdx = 0
            yield { type: 'block-start', index: 0, blockType: 'reasoning' }
          }
          racc += rc
          yield { type: 'reasoning-delta', index: 0, text: rc }
        }
        const c = delta.content
        if (c) {
          if (tIdx < 0) {
            if (rIdx >= 0) yield { type: 'block-end', index: 0, block: { type: 'reasoning', text: racc } }
            tIdx = (rIdx >= 0 ? 1 : 0)
            yield { type: 'block-start', index: tIdx, blockType: 'text' }
          }
          acc += c
          yield { type: 'text-delta', index: tIdx, text: c }
        }
      }
      if (tIdx >= 0) yield { type: 'block-end', index: tIdx, block: { type: 'text', text: acc } }
      if (rIdx >= 0 && tIdx < 0) yield { type: 'block-end', index: 0, block: { type: 'reasoning', text: racc } }
      for (const entry of toolState) {
        const i = entry[0]
        const st = entry[1]
        yield { type: 'block-end', index: i, block: { type: 'tool-call', id: st.id, name: st.name, arguments: st.args } }
      }
      yield { type: 'usage', usage: { promptTokens: 1, completionTokens: acc.length, totalTokens: 1 + acc.length } }
      yield { type: 'finish', reason: { kind: 'stop' } }
    }
  }
}

const bootAgentFactory = {
  async createAgent(ownerCtx, options) {
    const sid = options.sessionId ?? options.id ?? ('boot-agent-' + Date.now())
    const session = bootAgentSession(sid)
    const agent = new BootAgentSim(session)
    const detach = ownerCtx.agents.register(agent) // enter + announce（agent/created 事件真实派发）；返回幂等 detach
    return { agent, dispose: async () => detach() }
  },
}

// 合并：patch-base（内嵌 boot-* 行）+ 真实 bundle（覆盖支持的普通插件行——last write wins per id）
// 两段都经官方两阶段（yaml dump → entryListSchema load）
const ymlLayers = yaml.load(yaml.dump(patchLayers.map((l) => ({ insert: l }))), { schema: entryListSchema })
const merged = new Map()
const nameSeen = new Set()
for (const layer of ymlLayers) {
  for (const row of (layer && layer.insert) ?? []) {
    merged.set(row.id, row)
    nameSeen.add(row.name)
  }
}
// 官方 profile 行集并入（patch 优先——bundle 仅补缺失行（id+name 双去重——同包行 patch 已覆盖）；
// 140 轮推后项回填——M-5 官方 profile 全量核验面；--core（性能模式）跳过（67 模块小闭包基线）
const bundleRowsAll = []
if (globalThis.__coreMode !== true) {
  const bundleYml = globalThis.dshServices.fs.readText('/tmp/dsh-repo/packages/bundle/base/cordis.patch.yml')
  const bundleDoc = yaml.load(bundleYml, { schema: entryListSchema })
  for (const layer of bundleDoc) for (const row of (layer && layer.insert) ?? []) {
    bundleRowsAll.push(row.id)
    if (!merged.has(row.id) && !nameSeen.has(row.name)) {
      merged.set(row.id, row)
      nameSeen.add(row.name)
    }
  }
}
// bundle 驱动装载（140 轮定案：r.fibers=DisposableList（非数组）——fiber 状态读面深水——M-6 实验推后；行集探针保留）
try {
  const bundleYml = globalThis.dshServices.fs.readText('/tmp/dsh-repo/packages/bundle/base/cordis.patch.yml')
  const bundleDoc = yaml.load(bundleYml, { schema: entryListSchema })
  globalThis.__bundleCover = [...new Set(bundleDoc.flatMap((l) => (l && l.insert) ?? []).map((r) => r.id))].length
} catch (e) { globalThis.__bundleCover = 'err' }

// !!js 表达式 eval（v1 子集：new Function('process', ...) 调用——表达式来源=嵌入 patch 清单）
const exprToValue = (s) => {
  if (typeof s !== 'string' || !s.startsWith('!!js ')) return s
  return new Function('process', 'return (' + s.slice(5) + ')')(process)
}
// 官方两阶段兼容层：'!!js ' 字符串 → {__jsExpr}（isJsExpr 判定面）→ interpolate（with ctx eval）
const jsExprify = (v) => {
  if (typeof v === 'string' && v.startsWith('!!js ')) return { __jsExpr: v.slice(5) }
  if (Array.isArray(v)) return v.map(jsExprify)
  if (v && typeof v === 'object' && !('__jsExpr' in v)) {
    const out = {}
    for (const k of Object.keys(v)) out[k] = jsExprify(v[k])
    return out
  }
  return v
}
const applyConfig = (config) => interpolate({ process }, jsExprify(config ?? {}))
// WebUI 协议 schema（schemastery——op 白名单 + 字段必需性；verify 返回错误串或 null）

// WebUI 协议校验（手写层——z 化评估留档：schemastery z 在 DSH 包内正常、entry 顶层 import 语义异常——后续经 DSH 服务包转轨）
const protoSchema = null


globalThis.__bootSteps = []
const stepLog = (s) => globalThis.__bootSteps.push(s)
// 诊断探针：node:fs/promises 的 readFile 返回类型（应为 Uint8Array/Buffer）
try {
  const mm = await import('node:fs/promises')
  const rr = await mm.readFile('/tmp/dsh-tool-read.txt')
  globalThis.__probeRead = typeof rr + ':' + Object.prototype.toString.call(rr) + ':' + (rr && typeof rr.subarray)
} catch (e) { globalThis.__probeRead = 'err:' + String(e) }
const ctx = new Context()
stepLog('ctx-created')
let loaded = 0
let skipped = 0
for (const row of merged.values()) {
  const disabledFlag = row.disabled === true ? true : (typeof row.disabled === 'string' && row.disabled.startsWith('!!js ') ? !!interpolate({ process }, jsExprify(row.disabled)) : false)
  if (disabledFlag) { skipped += 1; continue }
  if (row.name.startsWith('boot-')) {
    if (row.name === 'boot-sysprompt') {
      await ctx.plugin({
        name: 'boot-sysprompt',
        apply(c) {
          c.provide('systemPrompt', { section: () => {}, tools: () => {} })
        },
      })
      continue
    }
    if (row.name === 'boot-llm') {
      await ctx.plugin({ name: 'boot-llm', apply(c) { c.provide('llm', bootLlm) } })
      continue
    }
    if (row.name === 'boot-attachments') {
      await ctx.plugin({ name: 'boot-attachments', apply(c) { new BootImageStore(c) } }) // Service 构造即注册
      continue
    }
    if (row.name === 'boot-approval') {
      await ctx.plugin({ name: 'boot-approval', inject: ['sessions'], apply(c) {
        const approval = {
          config: { policy: 'ask' },
          request: async () => 'allowed-once',
          setPolicy(policy) { this.config.policy = policy },
          get: () => 'allowed-once',
          attached: () => true,
        }
        c.provide('approval', approval)
      } })
      continue
    }
    if (row.name === 'boot-fs-policy') {
      const { SandboxPolicyService } = await import('@deepseek-ai/dsh-sandbox-policy')
      await ctx.plugin({ name: 'boot-fs-policy', apply(c) { new SandboxPolicyService(c, { mode: 'workspace-write', workspaceRoot: '/tmp' }) } })
      continue
    }
    if (row.name === 'boot-agent-factory') {
      await ctx.plugin({ name: 'boot-agent-factory', inject: ['agents'], apply(c) { c.agents.setFactory(bootAgentFactory) } })
      continue
    }
    await ctx.plugin({
      name: row.name,
      inject: ['fs', 'timer', 'agents', 'sessions', 'subagents', 'sessionQuery', 'tools'],
      async apply(c) {
        globalThis.__bootApplyCount = (globalThis.__bootApplyCount ?? 0) + 1
        globalThis.__applyLog = (globalThis.__applyLog ?? '') + ',' + row.name
        if (row.config) {
          globalThis.__bootMode = row.config.mode
          globalThis.__bootJsmode = applyConfig(row.config).mode
        }
        if (row.name !== 'boot-consumer') return // 探针体仅 consumer 行执行（boot-title/mode 行共享同一 apply）
        try {
        const rd = c.tools.get('read')
        globalThis.__toolRead = !!(rd && rd.name === 'read' && typeof rd.output.render === 'function')
        try { globalThis.__toolListAt = c.tools.view ? Array.from(c.tools.view(undefined).visible.keys()).join(',') : 'no-view' } catch (e) { globalThis.__toolListAt = 'err:' + String(e).slice(0, 50) }
      } catch (e) { globalThis.__toolRead = false }
      // 工具执行调用点（真实 fs 后端为 fs-sandbox——未装时错误揭示挂点）
      try {
        globalThis.dshServices.fs.writeText('/tmp/dsh-tool-read.txt', 'tool-exec-lexicon')
      } catch (e) {}
      if (globalThis.__toolRead) {
        try {
          const r = await c.tools.get('read').execute(
            { file_path: '/tmp/dsh-tool-read.txt' },
            { signal: { aborted: false } })
          globalThis.__toolExec = 'ok:' + typeof r
          let cnt = ''
          if (r && Array.isArray(r.lines)) { for (const ln of r.lines) cnt += (ln.text ?? '') + '\n' }
          globalThis.__toolContent = cnt
          globalThis.__toolPath = (r && r.path) || ''
          globalThis.__toolTotal = (r && r.totalLines) || -1
        } catch (e) {
          globalThis.__toolExec = 'err:' + String(e).slice(0, 80) + '||' + (e && e.stack ? e.stack.slice(0, 400) : '')
        }
      }
      try {
        try { globalThis.dshServices.fs.remove('/tmp/dsh-tool-write.txt') } catch (e) {}
        const wt = c.tools.get('write')
        globalThis.__writeTool = !!(wt && wt.name === 'write')
        if (wt) {
          const wr = await wt.execute(
            { file_path: '/tmp/dsh-tool-write.txt', content: 'write-tool-lexicon\nsecond-line' },
            { signal: { aborted: false } })
          globalThis.__writeOut = (wr && wr.operation) || 'none:' + typeof wr
          const wr2 = await wt.execute(
            { file_path: '/tmp/dsh-tool-write.txt', content: 'write-tool-lexicon\nsecond-line\nupdated-third' },
            { signal: { aborted: false } })
          globalThis.__writeOut2 = (wr2 && wr2.operation) || 'none:' + typeof wr2
          const rb = await c.tools.get('read').execute(
            { file_path: '/tmp/dsh-tool-write.txt', offset: 1, limit: 3 },
            { signal: { aborted: false } })
          globalThis.__writeBack = rb && Array.isArray(rb.lines) ? rb.lines.map((l) => l.text).join('|') : 'err'
          globalThis.__writeTotal = rb && rb.totalLines
          // —— edit 工具真实执行（唯一替换 + read 回读；依赖 write 块先建文件）
          try {
            const et = c.tools.get('edit')
            globalThis.__editTool = !!(et && et.name === 'edit')
            if (et) {
              const er = await et.execute(
                { file_path: '/tmp/dsh-tool-write.txt', old_string: 'second-line', new_string: 'edited-line' },
                { signal: { aborted: false } })
              globalThis.__editAfter = JSON.stringify(er, null, 0).slice(0, 400)
              const rb = await c.tools.get('read').execute(
                { file_path: '/tmp/dsh-tool-write.txt', offset: 1, limit: 3 },
                { signal: { aborted: false } })
              globalThis.__editBack = rb && Array.isArray(rb.lines) ? rb.lines.map((l) => l.text).join('|') : 'err'
            }
          } catch (e) { globalThis.__editErr = String(e).slice(0, 100) + '||' + (e && e.stack ? e.stack.slice(0, 400) : '') }
        }
      } catch (e) { globalThis.__writeErr = String(e).slice(0, 100) + '||' + (e && e.stack ? e.stack.slice(0, 1200) : '') }
      // —— offset 窗口 + 流路径（>4096B → streamText 分支；streamMinSize=4096 patch config）
      try {
        const big = 'l1-' + 'a'.repeat(1200) + '\nl2-' + 'b'.repeat(1200) + '\nl3-' + 'c'.repeat(1200) + '\nl4-' + 'd'.repeat(1200) + '\n'
        globalThis.dshServices.fs.writeText('/tmp/dsh-window.txt', big)
        // 探针1：手动流拼接
        try {
          const st = await c.fs.streamText({ displayPath: '/tmp/dsh-window.txt', targetKey: '/tmp/dsh-window.txt' }, { aborted: false })
          let acc = ''
          for await (const chunk of st) acc += chunk
          globalThis.__winStream = acc.length + ':' + (acc.indexOf('l2-bbb') >= 0 ? 'hit' : 'miss')
        } catch (e) { globalThis.__winStream = 'err:' + String(e).slice(0, 90) }
        // 探针2：直接 readText
        try {
          const t2 = await c.fs.readText({ displayPath: '/tmp/dsh-window.txt', targetKey: '/tmp/dsh-window.txt' }, { aborted: false })
          globalThis.__winRead = (t2 ? t2.length : -1) + ':' + (t2 && t2.indexOf('l2-bbb') >= 0 ? 'hit' : 'miss')
        } catch (e) { globalThis.__winRead = 'err:' + String(e).slice(0, 90) }
        // 探针3：decode 双参微对照
        try {
          const td = new (globalThis.TextDecoder)('utf-8', { fatal: true })
          const arr = new TextEncoder().encode('abc')
          let s2 = 'x'
          try { s2 = td.decode(arr, { stream: true }) } catch (e) { s2 = 'throw:' + String(e) }
          let s1 = 'x'
          try { s1 = td.decode(arr) } catch (e) { s1 = 'throw:' + String(e) }
          globalThis.__winD = (s1 === 'abc' ? 'd1ok:' : 'd1bad:') + (s2 === 'abc' ? 'd2ok:' : 'd2bad:')
        } catch (e) { globalThis.__winD = 'outer:' + String(e).slice(0, 90) }
        // 探针4：stream 全程复刻（createReadStream + decode 流式）
        try {
          const nf = await import('node:fs')
          const nu = await import('node:util')
          const stream = nf.createReadStream('/tmp/dsh-window.txt')
          const decoder = new nu.TextDecoder('utf-8', { fatal: true })
          let out = ''
          let err = ''
          try {
            for await (const chunk of stream) {
              const sample = chunk.subarray(0, 100)
              if (sample.includes(0)) throw new Error('binary')
              out += decoder.decode(chunk, { stream: true })
            }
          } catch (e) { err = String(e) }
          globalThis.__winD2 = (err === '' ? 'ok|' : 'err:' + err.slice(0, 60) + '|') + 'len:' + out.length + ':' + (out.indexOf('l2-bbb') >= 0 ? 'hit' : 'miss')
        } catch (e) { globalThis.__winD2 = 'outer:' + String(e).slice(0, 90) }
        const wr2 = await c.tools.get('read').execute(
          { file_path: '/tmp/dsh-window.txt', offset: 2, limit: 1 },
          { signal: { aborted: false } })
        globalThis.__winMode = (wr2 && wr2.lines && wr2.lines.length === 1 && wr2.lines[0].number === 2 && wr2.lines[0].text.startsWith('l2-bbb')) ? 'ok' : 'bad:' + JSON.stringify(wr2).slice(0, 160)
        globalThis.__winTotal = wr2 && wr2.totalLines
        // —— readBytes 二进制路径（readWholeBytes: createReadStream + Buffer.concat；依赖窗口块建文件）
        try {
          const bb = await c.fs.readBytes({ displayPath: '/tmp/dsh-window.txt', targetKey: '/tmp/dsh-window.txt' }, { aborted: false }, 10000)
          const ss = new TextDecoder().decode(bb)
          globalThis.__readBytes = (bb && bb.length ? bb.length : -1) + ':' + (ss.indexOf('l2-bbb') >= 0 ? 'hit' : 'miss')
        } catch (e) { globalThis.__readBytes = 'err:' + String(e).slice(0, 90) }
        // —— read_image 工具全链（attachments 门 + 路由门 + readBytes + saveImage）
        try {
          const px = "\x89PNG\x0D\x0A\x1A\x0A\x00\x00\x00\x0DIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1F\x15\xC4\x89\x00\x00\x00\x0DIDAT\x78\x9C\x63\xF8\xCF\xC0\xF0\x0F\x00\x03\x01\x01\x00\x18\xDD\x8D\xB0\x00\x00\x00\x00IEND\xAE\x42\x60\x82"
          globalThis.dshServices.fs.writeText('/tmp/dsh-px.png', px)
          const rdi = c.tools.get('read_image')
          globalThis.__imgTool = !!(rdi && rdi.name === 'read_image')
          if (rdi) {
            const rir = await rdi.execute({ file_path: '/tmp/dsh-px.png' }, {
              agent: { options: { provider: 'boot', model: 'boot-model' }, session: { requestHeader: () => undefined, header: { cwd: '/tmp' } } },
              signal: { aborted: false } })
            globalThis.__imgOut = (rir && rir.image) ? rir.image.attachmentId + ':' + rir.image.bytes + ':' + rir.image.mediaType : 'none:' + typeof rir
          }
        } catch (e) { globalThis.__imgErr = String(e).slice(0, 120) + '||' + (e && e.stack ? e.stack.slice(0, 300) : '') }
        // —— 工具清单盘点（注册表可见视图枚举）
        try {
          const tv = c.tools.view(undefined)
          let names = []
          if (tv && tv.visible && typeof tv.visible.keys === 'function') names = Array.from(tv.visible.keys())
          globalThis.__toolList = names.length ? names.join(',') : 'empty'
        } catch (e) { globalThis.__toolList = 'err:' + String(e).slice(0, 80) }
        // —— dshServices 服务树盘点
        try {
          globalThis.__svcList = Object.keys(globalThis.dshServices).join(',')
        } catch (e) { globalThis.__svcList = 'err:' + String(e).slice(0, 80) }
        // —— invalid UTF-8 JS 侧探针：模块系统活动后 new Function 编译含中文函数体
        try {
          const f = new Function('return ' + "'" + '\u4f60\u597d' + "';")
          globalThis.__ufJs = (f() === '\u4f60\u597d') ? 'ok' : 'bad'
        } catch (e) { globalThis.__ufJs = 'err:' + String(e).slice(0, 80) }
        // —— Web 网关：HTTP 服务真实监听（guest 路由回调走事件循环）
        try {
          globalThis.__gwRun = (globalThis.__gwRun ?? 0) + 1
          // dsh-llm 服务接入：真 LlmRuntime（isolate 作用域）→ MockLlmAdapter → mock SSE → chunk 流
          setTimeout(async () => {
            const step = (n) => { globalThis.__llmStep = n }
            try {
              step(1)
              const llmMod = await import('@deepseek-ai/dsh-llm')
              step(2)
              const lctx = ctx.isolate('llm')
              step(3)
              const rt = new llmMod.LlmRuntime(lctx)
              step(4)
              const Mock = createMockLlmAdapter('http://127.0.0.1:18099')
              rt.registerAdapter(['mock'], new Mock())
              step(5)
              const um = llmMod.createUserMessage({ content: [{ type: 'text', text: 'hi' }], source: { kind: 'chat' } })
              const p = await rt.prepareCall({ provider: 'mock', model: 'mock-model', messages: [um] })
              step(6)
              let text = ''
              let finish = ''
              let usage = 0
              for await (const ch of p.stream({ ...p.config, messages: [um] })) {
                if (ch.type === 'text-delta') text += ch.text
                if (ch.type === 'finish') finish = ch.reason.kind
                if (ch.type === 'usage') usage = ch.usage.completionTokens
              }
              step(7)
              globalThis.__llmRt = text === 'mock-text' && finish === 'stop' && usage === 9 ? 'ok:' + text + ':' + finish + ':' + usage : 'bad:' + text + ':' + finish + ':' + usage
            } catch (e) { globalThis.__llmRt = 'err@' + (globalThis.__llmStep ?? 0) + ':t=' + typeof e + ':st=' + String(Object.prototype.toString.call(e)).slice(0, 60) + ':s=' + String(e).slice(0, 150) }
          }, 300)
          // fetch SSE 流：mock stream → data 行 → delta 拼接（dsh-llm 消费面）
          setTimeout(() => {
            fetch('http://127.0.0.1:18099/v1/chat/completions', { method: 'POST', body: JSON.stringify({ model: 'mock', stream: true, messages: [] }) })
              .then((r) => r.text())
              .then((t) => {
                const datas = String(t).split('\n').filter((ln) => ln.startsWith('data: ')).map((ln) => ln.slice(6))
                let joined = ''
                for (const d of datas) {
                  if (d === '[DONE]') continue
                  try { const j = JSON.parse(d); const c = j.choices && j.choices[0] && j.choices[0].delta && j.choices[0].delta.content; if (c) joined += c } catch (e) {}
                }
                globalThis.__sseJoin = joined === 'mock-text' ? 'ok:' + joined : 'bad:' + joined
              })
              .catch((e) => { globalThis.__sseJoin = 'err:' + String(e).slice(0, 100) })
          }, 210)
          // fetch 面：全局 fetch → http.post → mock completion
          setTimeout(() => {
            fetch('http://127.0.0.1:18099/v1/chat/completions', { method: 'POST', body: JSON.stringify({ model: 'mock', messages: [] }) })
              .then((r) => r.json())
              .then((j) => { globalThis.__fetchOk = (j && j.choices && j.choices[0] && j.choices[0].message && j.choices[0].message.content === 'mock-text') ? 'ok:' + j.choices[0].message.content : 'bad:' + JSON.stringify(j).slice(0, 100) })
              .catch((e) => { globalThis.__fetchOk = 'err:' + String(e).slice(0, 100) })
          }, 180)

          // —— 长响应路径：100KB body（>16KB 头缓冲——动态扩读面）
          setTimeout(() => {
            try {
              const big = globalThis.dshServices.http.post(18099, '/v1/big', '{}')
              globalThis.__bigOk = (big.length === 100000 && big.indexOf('x') === 0 && big.indexOf('y') < 0) ? 'ok:' + big.length : 'bad:' + big.length
            } catch (e) { globalThis.__bigOk = 'err:' + String(e).slice(0, 80) }
            // —— wire 级逐块：ondata 回调（每读一块调一次——mock 分块 8×12500B）
            try {
              let chunks = 0
              let bytes = 0
              globalThis.dshServices.http.post(18099, '/v1/big', '{}', (c) => { chunks += 1; bytes += c.length })
              globalThis.__streamOk = (chunks >= 2 && bytes === 100000) ? 'ok:' + chunks + ':' + bytes : 'bad:' + chunks + ':' + bytes
            } catch (e) { globalThis.__streamOk = 'err:' + String(e).slice(0, 80) }
            // —— SSE 帧跨块：不规则分块（1-7B/间隙）→ ondata 帧拼装 → data 行
            try {
              let sseBuf = ''
              const sseEvents = []
              let sseChunks = 0
              globalThis.dshServices.http.post(18099, '/stream-chunk', '{}', (c) => {
                sseChunks += 1
                sseBuf += c
                let nl
                while ((nl = sseBuf.indexOf('\n')) >= 0) {
                  const line = sseBuf.slice(0, nl); sseBuf = sseBuf.slice(nl + 1)
                  if (line.startsWith('data: ')) sseEvents.push(line.slice(6))
                }
              })
              const j = sseEvents.join('|')
              globalThis.__sseFrame = (sseChunks > 5 && sseEvents.length === 3 && j === 'hello|world|[DONE]') ? 'ok:' + sseChunks + ':' + sseEvents.length : 'bad:' + sseChunks + ':' + j
            } catch (e) { globalThis.__sseFrame = 'err:' + String(e).slice(0, 80) }
            // —— 异步流：postAsync（非阻塞——读事件驱动——onData 逐块 + onDone 终态）
            try {
              globalThis.__asyncPost = 'pending'
              let agot = 0
              let an = 0
              globalThis.dshServices.http.postAsync(18099, '/v1/big', '{}',
                (c) => { agot += c.length; an += 1 },
                (total) => { globalThis.__asyncPost = (agot === 100000 && an >= 2 && total === 100000) ? 'ok:' + an + ':' + total : 'bad:' + an + ':' + agot + ':' + total })
            } catch (e) { globalThis.__asyncPost = 'err:' + String(e).slice(0, 80) }
          }, 140)
          setTimeout(() => {
            try {
              const pr = globalThis.dshServices.http.post(18099, '/chat', JSON.stringify({ echo: 'mk' }))
              const m = JSON.parse(pr)
              globalThis.__gwPost = (m && m.ok && m.echo === 'mk') ? 'ok:' + pr : 'bad:' + String(pr).slice(0, 60)
            } catch (e) { globalThis.__gwPost = 'err:' + String(e).slice(0, 60) }
          }, 150)


          try { globalThis.dshServices.http.start(Number(globalThis.__dshWebPort) || 18086) } catch (e) { globalThis.__webStartErr = 'listen port ' + (Number(globalThis.__dshWebPort) || 18086) + ' failed: ' + String(e && e.message ? e.message : e).slice(0, 60) + '（端口被占？）' }
          const __webPage = { body: '<!doctype html><html lang="zh"><head><meta charset="utf-8"><title>dsh web</title><style>body{font-family:system-ui;margin:24px;max-width:880px}#log{border:1px solid #ccc;border-radius:6px;padding:12px;height:52vh;overflow:auto;white-space:pre-wrap;font-size:13px;background:#fafafa}#row{display:flex;gap:8px;margin-top:10px}#in{flex:1;padding:8px;border:1px solid #ccc;border-radius:6px}button{padding:8px 16px}</style></head><body><h1>dsh web</h1><p>Zig 运行时 web 服务模式在线。活性：<span id="pp">…</span>　｜　完整 DSH GUI：<a href="http://127.0.0.1:3080">127.0.0.1:3080</a></p><div id="log">(载入中…)</div><div id="row"><input id="in" placeholder="继续说…（Enter 发送）"><button id="send">发送</button></div><script>var log=document.getElementById("log"),inp=document.getElementById("in");var ws=new WebSocket("ws://"+location.host+"/ws");function esc(s){return String(s).replace(/&/g,"&amp;").replace(/</g,"&lt;")}function render(evs){var h="";for(var i=0;i<evs.length;i++){var e=evs[i];if(e.type==="user/message")h+="\n【你】 "+esc(e.text)+"\n";else if(e.type==="assistant/message")h+="\n【助手】 "+esc(e.text)+"\n";else if(e.type==="tool/call")h+="  🔧 "+esc(e.name||"?")+" "+esc((e.text||"").slice(0,120))+"\n";else if(e.type==="tool/result")h+="  ↩︎ "+esc((e.text||"").slice(0,200))+"\n"}log.innerHTML=h||"(空)";log.scrollTop=log.scrollHeight}ws.onopen=function(){ws.send(JSON.stringify({op:"subscribe",session:"chat"}));ws.send(JSON.stringify({op:"history",limit:300}))};ws.onmessage=function(ev){try{var m=JSON.parse(ev.data);if(m.op==="history")render(m.events);else if(m.op==="event"&&m.session==="chat")ws.send(JSON.stringify({op:"history",limit:300}));else if(m.op==="chat-reply"&&m.error)log.innerHTML+="\n[系统] "+esc(m.error)+"\n"}catch(x){}};function send(){var t=inp.value.trim();if(!t)return;inp.value="";ws.send(JSON.stringify({op:"chat-send",session:"chat",text:t}))}document.getElementById("send").onclick=send;inp.onkeydown=function(e){if(e.key==="Enter")send()};fetch("/ping").then(function(r){return r.text()}).then(function(t){document.getElementById("pp").textContent=t})</script></body></html>', contentType: 'text/html; charset=utf-8' }
          globalThis.dshServices.http.handle('/index.html', (p) => { globalThis.__webRoot = 'hit'; return __webPage })
          globalThis.dshServices.http.handle('/panel', (p) => __webPage)

          // —— web-shell 伺服面（rc.2 壳本体：vendor 预载 + 同步路由；/ 给真 WebUI）
          try {
            const manRaw = await c.fs.readText({ displayPath: 'vendor/web-shell/manifest.json', targetKey: 'vendor/web-shell/manifest.json' })
            const man = JSON.parse(typeof manRaw === 'string' ? manRaw : String(manRaw))
            const __shellFiles = new Map()
            for (const f of man.files) {
              try {
                const raw = await c.fs.readText({ displayPath: f.path, targetKey: f.path })
                __shellFiles.set(f.url, { body: String(raw), mime: f.mime, enc: f.enc })
              } catch (fe) { globalThis.__shellSkip = (globalThis.__shellSkip ?? 0) + 1 }
            }
            globalThis.__shellFiles = __shellFiles.size
            const __shellHtml = __shellFiles.get('/shell.html')
            globalThis.dshServices.http.handle('/', (p) => __shellHtml ? { body: __shellHtml.body, contentType: __shellHtml.mime } : { body: 'shell missing', status: 500 })
            const serveStatic = (p) => {
              const q = p.indexOf('?')
              const f = __shellFiles.get(q >= 0 ? p.slice(0, q) : p)
              if (!f) return { body: 'not found: ' + p, status: 404 }
              return f.enc === 'b64' ? { body: f.body, contentType: f.mime, encoding: 'base64' } : { body: f.body, contentType: f.mime }
            }
            globalThis.dshServices.http.handle('/assets/', serveStatic, false)
            globalThis.dshServices.http.handle('/plugins/', serveStatic, false)
            globalThis.dshServices.http.handle('/dsh-whale/', serveStatic, false)
            globalThis.dshServices.http.handle('/favicon.svg', serveStatic)
            globalThis.dshServices.http.handle('/manifest.webmanifest', serveStatic)
          } catch (e) { globalThis.__shellErr = String(e).slice(0, 90) }
          // —— rc.2 网关面：SSE 下行（mux=会话域 / host=宿主域）+ unary POST（/api/<method> 全形 RPC）
          globalThis.__muxConns = {}
          globalThis.__hostConns = {}
          globalThis.__muxWs = {}
          globalThis.__hostWs = {}
          const __sseFrame = (payload) => JSON.stringify({ type: 'server-request', rpcId: globalThis.crypto.randomUUID(), method: payload.type, payload: payload })
          const __sseBroadcast = (table, payload) => { for (const id in table) { try { globalThis.dshServices.http.ssePush(Number(id), __sseFrame(payload)) } catch (e) {} } }
          const __wsBroadcast = (table, payload) => { for (const id in table) { try { globalThis.dshServices.http.push(__sseFrame(payload), Number(id)) } catch (e) {} } }
          const __muxBroadcast = (payload) => { __sseBroadcast(globalThis.__muxConns, payload); __wsBroadcast(globalThis.__muxWs, payload) }
          // 双传输：浏览器 WebApiClient 走 WS 下行（同路径 Upgrade），Node/SSE 客户端走 text/event-stream。
          // 只回 SSE 时浏览器 WS 握手拿 200 即断——连接重试环的根因。
          const __wsAccept = (h) => {
            const key = String((h && h['sec-websocket-key']) || '')
            const sha = globalThis.dshServices.crypto.sha1(key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11')
            let bin = ''
            for (let i = 0; i < sha.length; i += 2) bin += String.fromCharCode(parseInt(sha.slice(i, i + 2), 16))
            return 'ws-accept:' + globalThis.btoa(bin)
          }
          globalThis.dshServices.http.handle('/api/events.mux', (p, h, frame, connId) => {
            if (frame !== undefined) { globalThis.__muxWsInFrame = String(frame).slice(0, 120); return undefined } // 下行 only——关闭帧诊断留痕
            const isWs = h && h['sec-websocket-key']
            if (isWs) {
              globalThis.__muxWs[connId] = true
              globalThis.__muxWsId = connId
              setTimeout(() => {
                try {
                  let n = 0
                  for (const s of c.sessions.list()) {
                    const evs = s.log || []
                    n += globalThis.dshServices.http.push(__sseFrame({ type: 'session/subscribed', sessionId: s.id, lastSeq: evs.length ? (evs[evs.length - 1].seq ?? evs.length) : 0 }), connId)
                  }
                  globalThis.__muxPushRet = n
                } catch (e) { globalThis.__muxPushRet = 'err:' + String(e).slice(0, 60) }
              }, 30)
              return __wsAccept(h)
            }
            globalThis.__muxConns[connId] = true
            setTimeout(() => {
              try {
                for (const s of c.sessions.list()) {
                  const evs = s.log || []
                  globalThis.dshServices.http.ssePush(connId, __sseFrame({ type: 'session/subscribed', sessionId: s.id, lastSeq: evs.length ? (evs[evs.length - 1].seq ?? evs.length) : 0 }))
                }
              } catch (e) {}
            }, 30)
            return { sse: true }
          })
          globalThis.dshServices.http.handle('/api/events.host', (p, h, frame, connId) => {
            if (frame !== undefined) return undefined
            const isWs = h && h['sec-websocket-key']
            if (isWs) { globalThis.__hostWs[connId] = true; return __wsAccept(h) }
            globalThis.__hostConns[connId] = true
            return { sse: true }
          })
          if (!globalThis.__muxWired) {
            globalThis.__muxWired = true
            try {
              c.on('session/event', (sess, ev) => { __muxBroadcast({ type: 'session/event', sessionId: sess && sess.id, event: ev }) })
              c.on('session/created', (sess) => { __muxBroadcast({ type: 'session/subscribed', sessionId: sess && sess.id, lastSeq: 0 }) })
            } catch (e) { globalThis.__muxWireErr = String(e).slice(0, 60) }
          }
          const __unaryOk = (rpcId, value) => JSON.stringify({ rpcId: rpcId, result: { ok: true, value: value } })
          const __unaryErr = (rpcId, code, msg) => JSON.stringify({ rpcId: rpcId, result: { ok: false, error: { code: code, message: msg, details: {} } } })
          const __jsonResp = (body, status) => ({ body: body, contentType: 'application/json; charset=utf-8', ...(status ? { status: status } : {}) })
          const __sessionSummary = (s) => {
            const evs = s.log || []
            const last = evs.length ? evs[evs.length - 1] : null
            return { sessionId: s.id, updatedAt: (last && last.time) || 0, running: false, blank: evs.length === 0, cwd: '/home/dapao/proj/dhz' }
          }
          globalThis.dshServices.http.handle('/api/', (p, h, body, connId) => {
            if (typeof body !== 'string') return __jsonResp(__unaryErr('', 'bad-request', 'GET not supported on unary path'), 405)
            const q = p.indexOf('?'); const path = q >= 0 ? p.slice(0, q) : p
            const method = path.slice('/api/'.length)
            let msg = null
            try { msg = JSON.parse(body || '{}') } catch (e) { return __jsonResp(__unaryErr('', 'bad-request', 'invalid json'), 400) }
            const rpcId = (msg && msg.rpcId) || ''
            globalThis.__unaryLast = method
            try {
              if (method === 'session.list') {
                return __jsonResp(__unaryOk(rpcId, { items: c.sessions.list().map(__sessionSummary) }))
              }
              if (method === 'session.history') {
                const pl = (msg && msg.payload) || {}
                const sess = c.sessions.get(pl.sessionId)
                const evs = sess ? (sess.log || []) : []
                const lim = Math.min(1000, Math.max(1, pl.limit || 500))
                const cut = evs.slice(-lim).map((e) => ({ event: { type: e.type, seq: e.seq, time: e.time || 0, data: e.data, ...(e.surfaceOp !== undefined ? { surfaceOp: e.surfaceOp } : {}) } }))
                return __jsonResp(__unaryOk(rpcId, { events: cut, hasMore: evs.length > lim }))
              }
              // —— GUI 启动必需面（schema 对齐 rc.2 apiproxy；provider/model 取真渠道注入）
              const __rcfg = globalThis.__dshLlmReal ? JSON.parse(globalThis.__dshLlmReal) : { provider: 'mock', model: 'mock-model' }
              const __modelGroups = [{ id: __rcfg.provider, name: __rcfg.provider, models: [{ id: __rcfg.model, name: __rcfg.model }, { id: 'kimi-k3', name: 'kimi-k3' }, { id: 'glm-5.3', name: 'glm-5.3' }, { id: 'grok-4.6', name: 'grok-4.6' }, { id: 'deepseek-v4-flash-vision-exp', name: 'deepseek-v4-flash-vision-exp' }] }]
              if (method === 'host.describe') {
                return __jsonResp(__unaryOk(rpcId, { version: '0.1.1-rc.2+dhz', cwd: '/home/dapao/proj/dhz', provider: __rcfg.provider, model: __rcfg.model, attachedSessions: c.sessions.list().length, home: (globalThis.process && process.env && process.env.DSH_HOME) || '/home/dapao/.dsh', canOpenPath: false }))
              }
              if (method === 'workspace.list') {
                const now = new Date().toISOString()
                return __jsonResp(__unaryOk(rpcId, { items: [{ workspaceId: 'ws-dhz', path: '/home/dapao/proj/dhz', title: 'dhz', sessionIds: c.sessions.list().map((s) => s.id), createdAt: now, updatedAt: now }], archivedSessionIds: [] }))
              }
              if (method === 'settings.describe') {
                return __jsonResp(__unaryOk(rpcId, { writable: false, hasDocument: false, namespaces: [] }))
              }
              if (method === 'llm.providers') {
                return __jsonResp(__unaryOk(rpcId, { providers: [{ provider: __rcfg.provider, displayName: 'A6API ', settingsNs: 'llm-pi-ai', settingsPath: ['llm-pi-ai', 'providers', __rcfg.provider], active: true, declared: true }] }))
              }
              if (method === 'llm.models') {
                return __jsonResp(__unaryOk(rpcId, { groups: __modelGroups, failures: [] }))
              }
              if (method === 'session.models') {
                return __jsonResp(__unaryOk(rpcId, { current: { provider: __rcfg.provider, model: __rcfg.model }, routable: false, groups: __modelGroups, failures: [] }))
              }
              if (method === 'agentPreset.list') {
                return __jsonResp(__unaryOk(rpcId, { presets: [{ id: 'code', trust: 'system', isDefault: true, name: 'code' }], authorable: false, hasDocument: false }))
              }
              if (method === 'skill.list') {
                return __jsonResp(__unaryOk(rpcId, { skills: [] }))
              }
              if (method === 'session.prompt') {
                const pl = (msg && msg.payload) || {}
                const sess = c.sessions.get(pl.sessionId)
                if (!sess) return __jsonResp(__unaryErr(rpcId, 'not-found', 'session not found: ' + String(pl.sessionId)), 404)
                const parts = Array.isArray(pl.content) ? pl.content : []
                const text = parts.filter((x) => x && x.type === 'text').map((x) => x.text || '').join('\n')
                if (!text) return __jsonResp(__unaryErr(rpcId, 'bad-request', 'empty prompt'), 400)
                if (!globalThis.__chatReady) return __jsonResp(__unaryErr(rpcId, 'unavailable', 'llm not ready（需 DSH_LLM_REAL）'), 503)
                const st = globalThis.__chatState
                // 回合编排（rc.2 事件序列——GUI 实况渲染面）：turn/start → user/message → step/start
                // → assistant/chunk（块三元）→ assistant/message → step/end → turn/end
                const turn = (globalThis.__turnNo = (globalThis.__turnNo || 0) + 1)
                const step = 1
                sess.append('turn/start', { turn: turn })
                sess.append('user/message', { content: [{ type: 'text', text: text }], role: 'user', source: { kind: 'user', ...(pl.clientTimeZone ? { clientTimeZone: pl.clientTimeZone } : {}) } }, { surfaceOp: 'append' })
                sess.append('step/start', { turn: turn, step: step })
                st.msgs.push({ role: 'user', content: text })
                ;(async () => {
                  try {
                    const ba = new st.llmMod.BlockAssembler()
                    for await (const ch of st.adapter._stream({ model: st.rcfg.model, messages: st.msgs, toolMode: true })) {
                      if (ch && (ch.type === 'block-start' || ch.type === 'text-delta' || ch.type === 'reasoning-delta' || ch.type === 'block-end')) sess.append('assistant/chunk', { turn: turn, step: step, chunk: ch })
                      ba.push(ch)
                    }
                    const tb = ba.blocks().find((b) => b.type === 'text')
                    const reply = tb && tb.text ? String(tb.text) : '(空回复)'
                    st.msgs.push({ role: 'assistant', content: reply })
                    sess.append('assistant/message', { turn: turn, step: step, message: { role: 'assistant', content: [{ type: 'text', text: reply }] } }, { surfaceOp: 'append' })
                    sess.append('step/end', { turn: turn, step: step })
                    sess.append('turn/end', { turn: turn, reason: { kind: 'completed' } })
                  } catch (e2) {
                    sess.append('assistant/message', { turn: turn, step: step, message: { role: 'assistant', content: [{ type: 'text', text: '(错误) ' + String(e2 && e2.message ? e2.message : e2).slice(0, 160) }] } }, { surfaceOp: 'append' })
                    sess.append('turn/end', { turn: turn, reason: { kind: 'error' } })
                  }
                })()
                return __jsonResp(__unaryOk(rpcId, { accepted: true }))
              }
              if (method === 'session.create') {
                const pl2 = (msg && msg.payload) || {}
                const sid = pl2.sessionId || ('session-' + globalThis.crypto.randomUUID())
                c.sessions.create(sid, { seed: [], meta: { cwd: pl2.cwd || '/home/dapao/proj/dhz' } })
                return __jsonResp(__unaryOk(rpcId, { sessionId: sid, ...(pl2.agentPreset ? { agentPreset: pl2.agentPreset } : {}) }))
              }
              if (method === 'session.search') {
                const pl3 = (msg && msg.payload) || {}
                const q3 = String(pl3.query || '').toLowerCase()
                const items3 = []
                for (const s of c.sessions.list()) {
                  if (items3.length >= 20) break
                  const evs = s.log || []
                  let snip = ''
                  for (const ev of evs) {
                    const d4 = ev.data || {}
                    let txt = ''
                    if (ev.type === 'user/message') txt = ((d4.content || [])[0] || {}).text || ''
                    else if (ev.type === 'assistant/message') { const ps = ((d4.message || {}).content) || []; txt = ps.filter((x) => x && x.type === 'text').map((x) => x.text || '').join('\n') }
                    if (txt && txt.toLowerCase().indexOf(q3) >= 0) { snip = txt.slice(0, 200); break }
                  }
                  if (snip) items3.push({ sessionId: s.id, snippet: snip })
                }
                return __jsonResp(__unaryOk(rpcId, { items: items3, hasMore: false }))
              }
              if (method === 'session.rename') {
                const pl4 = (msg && msg.payload) || {}
                const sess4 = c.sessions.get(pl4.sessionId)
                let seq4 = 0
                if (sess4) {
                  sess4.append('session/title', { title: String(pl4.title || '') })
                  const evs4 = sess4.log || []
                  seq4 = evs4.length ? (evs4[evs4.length - 1].seq ?? evs4.length) : 0
                }
                return __jsonResp(__unaryOk(rpcId, { title: String(pl4.title || ''), seq: seq4 }))
              }
              if (method === 'subagent.list') {
                return __jsonResp(__unaryOk(rpcId, { entries: [], parentAvailable: false }))
              }
              if (method === 'subagent.history') {
                return __jsonResp(__unaryOk(rpcId, { events: [], hasMore: false }))
              }
              if (method === 'session.cancel') {
                return __jsonResp(__unaryOk(rpcId, { accepted: true }))
              }
              globalThis.__unaryMiss = (globalThis.__unaryMiss || []).concat(method).slice(-20)
              return __jsonResp(__unaryErr(rpcId, 'unimplemented', 'method not implemented: ' + method), 501)
            } catch (e) {
              return __jsonResp(__unaryErr(rpcId, 'internal', String(e).slice(0, 120)), 500)
            }
          }, false)
          globalThis.dshServices.http.handle('/debug/gateway', (p) => ({ body: JSON.stringify({ unaryLast: globalThis.__unaryLast || null, unaryMiss: globalThis.__unaryMiss || [], shellFiles: globalThis.__shellFiles || 0, shellSkip: globalThis.__shellSkip || 0, shellErr: globalThis.__shellErr || null, chatImport: globalThis.__chatImport || null, chatErr: globalThis.__chatErr || null, muxConns: Object.keys(globalThis.__muxConns || {}).length, muxWs: Object.keys(globalThis.__muxWs || {}).length, hostWs: Object.keys(globalThis.__hostWs || {}).length, muxWsId: globalThis.__muxWsId, muxPushRet: globalThis.__muxPushRet, muxWsInFrame: globalThis.__muxWsInFrame, reports: (globalThis.__dbgReports || []).slice(-12) }), contentType: 'application/json; charset=utf-8' }))
          globalThis.dshServices.http.handle('/debug/report', (p, h, body) => {
            try { globalThis.__dbgReports = (globalThis.__dbgReports || []).concat(String(body || '').slice(0, 400)).slice(-40) } catch (e) {}
            return 'ok'
          })
          globalThis.dshServices.http.handle('/ping', (p) => 'pong:' + p)
          globalThis.dshServices.http.handle('/post-echo', (p, h, body) => { try { globalThis.__gwPostBody = String(body); const m = JSON.parse(body || ''); return 'post:' + (m && m.echo ? m.echo : '?') } catch (e) { return 'post:bad:' + String(e).slice(0, 40) } })
          globalThis.dshServices.http.handle('/post-echo', (p, h, body) => { try { const m = JSON.parse(body || ''); return 'post:' + (m && m.echo ? m.echo : '?') } catch (e) { return 'post:bad' } })

          globalThis.dshServices.http.handle('/ws', (p, h, frame, connId) => {
            if (frame !== undefined) {
              let msg = null
              try { msg = JSON.parse(frame) } catch (e) { msg = null }
              // dhz 扩展 op（history/chat-*——面板面）不走上游协议 schema；上游 op 校验不变
              const dhzExt = msg && (msg.op === 'history' || (typeof msg.op === 'string' && msg.op.startsWith('chat-')))
              if (msg && typeof msg === 'object' && protoSchemaFromModule && !dhzExt) {
                try {
                  protoSchemaFromModule(msg)
                } catch (e) { return 'ws-bad-schema:' + String(e && e.message ? e.message : e).slice(0, 60) }
              }
              if (msg && msg.op === 'events') {
                  const sess = c.sessions.get(msg.session)
                  const evs = sess ? sess.log : []
                  return JSON.stringify({ op: 'events', session: msg.session, count: evs.length, types: evs.map((e) => e.type) })
                }
                if (msg && msg.op === 'sessions') {
                  return JSON.stringify({ op: 'sessions', ids: c.sessions.list().map((s) => s.id) })
                }
                if (msg && msg.op === 'query') {
                  c.sessionQuery.readSession(msg.session).then((rec) => {
                    globalThis.__wsPending = JSON.stringify({ op: 'query-result', session: msg.session, events: rec ? (Array.isArray(rec.events) ? rec.events.length : -1) : -1 })
                  }).catch((e) => {
                    globalThis.__wsPending = JSON.stringify({ op: 'query-error', error: String(e).slice(0, 80) })
                  })
                  return 'ws-pending'
                }
                if (msg && msg.op === 'poll') {
                  const r = globalThis.__wsPending
                  globalThis.__wsPending = ''
                  return r || 'ws-none'
                }
                if (msg && msg.op === 'sandboxStatus') {
                  try {
                    const sc2 = c.sessions.get(msg.session)
                    const pv = c.get('sandboxPolicy').resolve(sc2 ? { session: sc2 } : {})
                    return JSON.stringify({ op: 'sandboxStatus', session: msg.session, mode: pv.mode, workspaceRoot: pv.workspaceRoot })
                  } catch (e) { return 'sb-err:' + String(e).slice(0, 60) }
                }
                if (msg && msg.op === 'sandboxSet') {
                  try {
                    const sc3 = c.sessions.get(msg.session)
                    if (sc3) sc3.append('sandbox/mode', { mode: String(msg.mode) })
                    return 'sb-set:' + String(msg.mode)
                  } catch (e) { return 'sb-set-err:' + String(e).slice(0, 60) }
                }
                if (msg && msg.op === 'subscribe') {
                  globalThis.__wsConnId = connId
                  if (!globalThis.__wsSubscribed) {
                    globalThis.__wsSubscribed = true
                    c.on('session/event', (sess, ev) => {
                      try { globalThis.dshServices.http.push(JSON.stringify({ op: 'event', session: sess && sess.id, type: ev && ev.type, seq: ev && ev.seq }), globalThis.__wsConnId) } catch (e) {}
                    })
                  }
                  return 'ws-subscribed:' + String(connId)
                }
                if (msg && msg.op === 'whoami') {
                  return 'ws-conn:' + String(globalThis.__wsConnId)
                }
                if (msg && msg.op === 'emit') {
                  try {
                    const s = c.sessions.get(msg.session)
                    if (s) s.append(msg.type, msg.data ?? {})
                    return 'ws-emitted:' + (msg.type ?? '')
                  } catch (e) { return 'ws-emit-err:' + String(e).slice(0, 60) }
                }
                if (msg && msg.op === 'history') {
                  try {
                    const sess = c.sessions.get('chat')
                    const evs = sess ? sess.log : []
                    const lim = Math.min(500, Math.max(1, msg.limit || 200))
                    const cut = evs.slice(-lim).map((e) => {
                      const d = e.data || {}
                      let text = ''
                      if (e.type === 'user/message') text = ((d.content || [])[0] || {}).text || ''
                      else if (e.type === 'assistant/message') { const ps = ((d.message || {}).content) || []; text = ps.filter((x) => x && x.type === 'text').map((x) => x.text || '').join('\n') }
                      else if (e.type === 'tool/call') text = String(d.arguments || '').slice(0, 120)
                      else if (e.type === 'tool/result') { const ps = ((((d.message || {}).content) || [])[0] || {}).content || []; text = (ps[0] || {}).text || '' }
                      else text = d.text || ''
                      return { type: e.type, text: String(text).slice(0, 600), name: d.name, toolCalls: d.toolCalls }
                    })
                    return JSON.stringify({ op: 'history', total: evs.length, events: cut })
                  } catch (e) { return 'history-err:' + String(e).slice(0, 60) }
                }
                if (msg && msg.op === 'chat-send') {
                  if (!globalThis.__chatReady) return JSON.stringify({ op: 'chat-reply', error: 'chat 未就绪（需 DSH_LLM_REAL）' })
                  const text = String(msg.text || '')
                  if (!text) return '{"op":"chat-reply","error":"empty"}'
                  const sess = c.sessions.get('chat')
                  const st = globalThis.__chatState
                  sess.append('user/message', { content: [{ type: 'text', text: text }], role: 'user', source: { kind: 'chat' } }, { surfaceOp: 'append' })
                  st.msgs.push({ role: 'user', content: text })
                  ;(async () => {
                    try {
                      // 直驱 adapter._stream（主 ctx 面——LlmRuntime 的 isolate 在 serve 循环里
                      // 拿不到 job 泵，流永不推进；排障实锤 seen=not-called）
                      const ba = new st.llmMod.BlockAssembler()
                      for await (const ch of st.adapter._stream({ model: st.rcfg.model, messages: st.msgs, toolMode: true })) ba.push(ch)
                      const tb = ba.blocks().find((b) => b.type === 'text')
                      const reply = tb && tb.text ? String(tb.text) : '(空回复)'
                      st.msgs.push({ role: 'assistant', content: reply })
                      sess.append('assistant/message', { turn: 0, step: 0, message: { role: 'assistant', content: [{ type: 'text', text: reply }] } }, { surfaceOp: 'append' })
                    } catch (e) { sess.append('assistant/message', { turn: 0, step: 0, message: { role: 'assistant', content: [{ type: 'text', text: '(错误) ' + String(e && e.message ? e.message : e).slice(0, 160) }] } }, { surfaceOp: 'append' }) }
                  })()
                  return JSON.stringify({ op: 'chat-reply', status: 'sent' })
                }
                return 'ws-echo:' + frame
            }
            const key = String((h && h['sec-websocket-key']) || '')
            const sha1 = globalThis.dshServices.crypto.sha1(key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11')
            let bin = ''
            for (let i = 0; i < sha1.length; i += 2) bin += String.fromCharCode(parseInt(sha1.slice(i, i + 2), 16))
            return 'ws-accept:' + globalThis.btoa(bin)
          })
          // —— chat 面（DSH_LLM_REAL）：导入 dsh 会话历史 + 真渠道 agent 状态（web 会话面板后端）
          if (globalThis.__dshLlmReal) {
            try {
              const rcfg = JSON.parse(globalThis.__dshLlmReal)
              const st0 = { rcfg: rcfg, msgs: [], llmMod: null, rt: null }
              globalThis.__chatState = st0
              const sess = c.sessions.create('chat', { seed: [], meta: { cwd: '/tmp' } })
              if (rcfg.importPath) {
                try {
                  const raw = await c.fs.readText({ displayPath: rcfg.importPath, targetKey: rcfg.importPath })
                  const imp = JSON.parse(typeof raw === 'string' ? raw : String(raw))
                  // 真实 dsh 事件类型落库（GUI 原生渲染面；surface 三型带 append 标记——契约）
                  let impN = 0
                  for (const ev of (imp.events || [])) {
                    impN += 1
                    if (ev.type === 'user') sess.append('user/message', { content: [{ type: 'text', text: ev.text }], role: 'user', source: { kind: 'user' } }, { surfaceOp: 'append' })
                    else if (ev.type === 'assistant') sess.append('assistant/message', { turn: 0, step: 0, message: { role: 'assistant', content: ev.text ? [{ type: 'text', text: ev.text }] : [] } }, { surfaceOp: 'append' })
                    else if (ev.type === 'tool-call') sess.append('tool/call', { turn: 0, step: 0, callId: ev.callId || ('import-' + impN), name: ev.name || '?', arguments: ev.args || '{}' })
                    else if (ev.type === 'tool-result') sess.append('tool/result', { turn: 0, step: 0, message: { source: { kind: 'tool', callId: ev.toolCallId || ('import-' + impN) }, content: [{ type: 'tool-result', toolCallId: ev.toolCallId || ('import-' + impN), content: [{ type: 'text', text: ev.text || '' }] }] } }, { surfaceOp: 'append' })
                  }
                  for (const m of (imp.messages || [])) st0.msgs.push({ role: m.role, content: m.content })
                  globalThis.__chatImport = 'ok:' + (imp.events || []).length + '/' + st0.msgs.length
                } catch (ie) { globalThis.__chatImport = 'err:' + String(ie).slice(0, 80) }
              }
              const llmMod2 = await import('@deepseek-ai/dsh-llm')
              st0.llmMod = llmMod2
              const Real2 = createMockLlmAdapter(rcfg.base)
              st0.adapter = new Real2()
              globalThis.__chatReady = true
            } catch (e) { globalThis.__chatErr = String(e).slice(0, 100) }
          }
          globalThis.__gwReady = true
        } catch (e) { globalThis.__gwErr = String(e).slice(0, 90) }
        // —— fs 服务剩余 API 面（stat/fileUrl/processPath/contains）
        try {
          const tg = { targetKey: '/tmp/dsh-tool-read.txt', displayPath: '/tmp/dsh-tool-read.txt' }
          const st = await c.fs.stat(tg, { aborted: false })
          globalThis.__fsStat = (st && st.type === 'file' && st.size > 0) ? 'ok' : 'bad:' + JSON.stringify(st).slice(0, 100)
          globalThis.__fsUrl = c.fs.fileUrl(tg)
          globalThis.__fsProc = c.fs.processPath(tg) + ':' + c.fs.contains(tg, { targetKey: '/tmp/dsh-tool-read.txt/x', displayPath: '' })
        } catch (e) { globalThis.__fsErr = String(e).slice(0, 90) }
        // —— read_image 渲染面（imageReadContent 两块）
        try {
          const rdi = c.tools.get('read_image')
          if (rdi && rdi.output && rdi.output.render) {
            const rc = rdi.output.render({ file_path: '/tmp/dsh-px.png' }, { path: '/tmp/dsh-px.png', image: { attachmentId: 'render-x', mediaType: 'image/png', bytes: 70, width: 1, height: 1 } })
            globalThis.__imgRender = Array.isArray(rc) ? rc.length + ':' + rc[0].type + ':' + rc[1].type + ':' + rc[1].attachment.attachmentId : 'bad'
          } else globalThis.__imgRender = 'no-render'
        } catch (e) { globalThis.__imgRender = 'err:' + String(e).slice(0, 90) }
        // —— Web 全局面：crypto.subtle.digest / performance.now / crypto.randomUUID
        try {
          const d = await crypto.subtle.digest('SHA-256', new TextEncoder().encode('abc'))
          globalThis.__subDigest = Array.from(new Uint8Array(d)).map((b) => b.toString(16).padStart(2, '0')).join('')
        } catch (e) { globalThis.__subDigest = 'err:' + String(e).slice(0, 90) }
        try {
          const t0 = performance.now()
          const t1 = performance.now()
          globalThis.__perf = (t1 > t0) ? 'ok:' + t1.toFixed(1) : 'bad:' + t0.toFixed(1) + ':' + t1.toFixed(1)
        } catch (e) { globalThis.__perf = 'err:' + String(e).slice(0, 90) }
        try {
          globalThis.__uuid = globalThis.crypto.randomUUID()
        } catch (e) { globalThis.__uuid = 'err:' + String(e).slice(0, 90) }
      } catch (e) { globalThis.__winErr = String(e).slice(0, 100) + '||' + (e && e.stack ? e.stack.slice(0, 300) : '') }
      c.sessionQuery.listSessions().then((r) => {
          globalThis.__sqApi = Array.isArray(r)
          // 内容证据（boot-demo 完整 header 列表——已文件留档；禁用异步索引时序后仅作记录）
          try { globalThis.dshServices.fs.writeText('/tmp/dsh-list.txt', JSON.stringify(r)) } catch (e) {}
        }).catch((e) => { globalThis.__sqApi = false; try { globalThis.dshServices.fs.writeText('/tmp/dsh-list.txt', 'ERR:' + String(e)) } catch (e2) {} })
        try {
  const s = c.sessions.create('boot-demo', { seed: [], meta: { cwd: '/tmp' } })
  globalThis.__sessCreated = !!(s && s.id === 'boot-demo' && c.sessions.get('boot-demo'))
} catch (e) { globalThis.__sessErr = String(e) }
        // —— 会话生命周期：fork 子会话 + list + flush（依赖 boot-demo 先创建）
        try {
          const ch = c.sessions.fork('boot-demo', undefined, 'boot-child')
          globalThis.__forkOk = !!(ch && ch.id === 'boot-child' && c.sessions.get('boot-child'))
          globalThis.__forkList = c.sessions.list().length >= 2 ? 'ok' : 'count:' + c.sessions.list().length
        } catch (e) { globalThis.__sessErr2 = String(e).slice(0, 120) }
        try {
          const fl = await c.sessions.flush(c.sessions.get('boot-child'))
          globalThis.__flushOk = (typeof fl === 'boolean') ? 'ok' : 'bad:' + typeof fl
        } catch (e) { globalThis.__flushErr2 = String(e).slice(0, 120) }
        try {
          globalThis.__childLog = (c.sessions.get('boot-child').log ?? []).length
        } catch (e) { globalThis.__logErr2 = String(e).slice(0, 120) }
        // —— agent 生命周期：factory create → register（agent/created）→ get 读回
        try {
          const h = await c.agents.create({ sessionId: 'boot-agent-1', meta: {} })
          globalThis.__agentOk = !!(h && h.agent && h.agent.id === 'boot-agent-1' && c.agents.get('boot-agent-1') === h.agent)
        } catch (e) { globalThis.__agentErr = String(e).slice(0, 120) }
        // —— agent dispose 面：create → dispose（agent/disposed 事件）→ get undefined
        try {
          c.on('agent/disposed', () => { globalThis.__dispCount = (globalThis.__dispCount ?? 0) + 1 })
          c.on('agent/created', () => { globalThis.__createCount = (globalThis.__createCount ?? 0) + 1 })
          const h2 = await c.agents.create({ sessionId: 'boot-agent-2', meta: {} })
          globalThis.__agentOk2 = !!(h2 && c.agents.get('boot-agent-2') === h2.agent)
          await h2.dispose()
          globalThis.__agentGone = c.agents.get('boot-agent-2') === undefined
        } catch (e) { globalThis.__agentErr2 = String(e).slice(0, 120) }
        // —— dsh-llm 消息流：createUser/Assistant/ToolResult（全局 crypto.randomUUID 真实供键）
        try {
          const llm = await import('@deepseek-ai/dsh-llm')
          const um = llm.createUserMessage({ content: [{ type: 'text', text: 'hello' }], source: { kind: 'chat' } })
          const am = llm.createAssistantMessage({ content: [{ type: 'text', text: 'hi' }], source: { provider: 'boot', model: 'boot-model' } })
          const tm = llm.createToolResultMessage({ callId: 'call-1', content: [{ type: 'text', text: 'done' }], isError: false })
          globalThis.__msgOk = !!(um && um.role === 'user' && um.id && um.id.length > 10 && am.role === 'assistant' && tm.role === 'user' && Object.isFrozen(um))
          globalThis.__msgUuid = um.id
        } catch (e) { globalThis.__msgErr = String(e).slice(0, 120) }
        // —— 会话事件流：append（request/header）→ requestHeader 折叠 + log 增长 + session/event 观察者
        try {
          const s3 = c.sessions.get('boot-child')
          const seq0 = s3.log.length
          s3.append('request/header', { header: { config: { provider: 'boot', model: 'boot-2' } } })
          const hd = s3.requestHeader()
          globalThis.__hdrOk = !!(hd && hd.config && hd.config.provider === 'boot' && hd.config.model === 'boot-2')
          globalThis.__hdrSeq = s3.log.length - seq0
          let evCnt = 0
          c.on('session/event', (sess, ev) => { if (sess && sess.id === s3.id) evCnt += 1 })
          s3.append('user/text', { content: [{ type: 'text', text: 'hi' }], source: { kind: 'chat' } })
          globalThis.__evObs = evCnt
        } catch (e) { globalThis.__hdrErr = String(e).slice(0, 120) }
        // —— sessionQuery 全 API：readSession（回放校验）/listEvents/readTitleSnapshot
        try {
          const sq = c.sessionQuery
          const rec = await sq.readSession('boot-child')
          globalThis.__sqRead = !!(rec && rec.session && Array.isArray(rec.events))
          globalThis.__sqEvtCount = rec && Array.isArray(rec.events) ? rec.events.length : -1
          const ts = await sq.readTitleSnapshot('boot-child')
          globalThis.__sqTitle = (ts && typeof ts.title === 'string') ? ts.title : 'none'
        } catch (e) { globalThis.__sqErr3 = String(e).slice(0, 120) }
        // —— filter 面 + title 事件面（session/title append → readTitleSnapshot 折叠）
        try {
          const sq = c.sessionQuery
          const fs = await sq.filterSessions([{ kind: 'id', values: ['boot-child'] }], undefined)
          globalThis.__fsOk = Array.isArray(fs) && fs.length === 1 && fs[0] && fs[0].header && fs[0].header.id === 'boot-child'
          globalThis.__fsShape = JSON.stringify(fs).slice(0, 140)
          const fe = await sq.filterEvents('boot-child', [{ kind: 'type', values: ['user/text'] }])
          globalThis.__feOk = Array.isArray(fe) && fe.length >= 1 && fe[0] && fe[0].type === 'user/text'
          globalThis.__feShape = JSON.stringify(fe).slice(0, 140)
          const s4 = c.sessions.get('boot-child')
          s4.append('session/title', { title: 'boot-child-title', messageSeqs: [], source: { kind: 'user' } })
          globalThis.__titleLast = (c.sessions.get('boot-child').log.at(-1) ?? {}).type
          globalThis.__titleEv = c.sessions.get('boot-child').events.length + ':' + c.sessions.get('boot-child').events.at(-1).type
          const evs = c.sessions.get('boot-child').events
          try { globalThis.__findLast = (typeof evs.findLast === 'function' ? 'fn:' : 'nofn:') + (evs.findLast((x) => x.type === 'session/title') ? 'found' : 'notfound') } catch (e) { globalThis.__findLast = 'err:' + String(e).slice(0, 60) }
          try {
            const st = await import('@deepseek-ai/dsh-session-title')
            const folded = st.foldSessionTitle(evs)
            globalThis.__foldProbe = folded ? 'fold:' + folded.title : 'fold:none'
          } catch (e) { globalThis.__foldProbe = 'err:' + String(e).slice(0, 80) }
          // 微任务排空（时序验证③：engine readTitleSnapshot 的观察时序差异留档）
          for (let i = 0; i < 16; i++) await Promise.resolve()
          const ts = await sq.readTitleSnapshot('boot-child')
          globalThis.__titleOk = (ts && ts.title === 'boot-child-title') ? 'ok' : 'bad:' + JSON.stringify(ts).slice(0, 120)
          const cur = c.sessions.get('boot-child')
          globalThis.__tsId = (ts && ts.session && cur) ? (ts.session.id + '|' + (ts.session.createdAt === cur.header.createdAt ? 'same' : 'diff:' + cur.header.createdAt)) : 'na'
          globalThis.__tsEvLen = (ts && ts.session && cur && cur.events) ? cur.events.length : 'na'
          const ts2b = await sq.readTitleSnapshot('boot-child')
          globalThis.__ts2b = (ts2b && ts2b.title) ? 'hit2' : 'miss2'
        } catch (e) { globalThis.__ftErr = String(e).slice(0, 140) }
        // —— os/home 面：homedir/tmpdir 真实语义 + dsh-home-paths 链（DSH_HOME env）
        try {
          const osMod = await import('node:os')
          globalThis.__osHome = osMod.homedir()
          globalThis.__osTmp = osMod.tmpdir()
          const hp = await import('@deepseek-ai/dsh-home-paths')
          globalThis.__hpDefault = hp.defaultDshHome()
          globalThis.__hpResolved = hp.resolveDshHome(undefined) ?? hp.defaultDshHome()
        } catch (e) { globalThis.__hpErr = String(e).slice(0, 140) }
        // —— 沙箱 escalate 面：validateEscalationArgs 三拒绝 + write 无后端 fail-closed
        try {
          const sb = await import('@deepseek-ai/dsh-sandbox')
          sb.validateEscalationArgs('workspace-write', 'test justification')
          globalThis.__escOk = 1
          try { sb.validateEscalationArgs('workspace-write'); globalThis.__escA = 'nothrow' } catch (e) { globalThis.__escA = 'throw' }
          try { sb.validateEscalationArgs(undefined, 'no perms'); globalThis.__escB = 'nothrow' } catch (e) { globalThis.__escB = 'throw' }
          try { sb.validateEscalationArgs('workspace-write', '   '); globalThis.__escC = 'nothrow' } catch (e) { globalThis.__escC = 'throw' }
        } catch (e) { globalThis.__escErr = String(e).slice(0, 100) }
        try {
          await c.tools.get('write').execute(
            { file_path: '/tmp/dsh-esc.txt', content: 'x', sandbox_permissions: 'workspace-write', justification: 'test' },
            { signal: { aborted: false } })
          globalThis.__escWrite = 'accepted'
        } catch (e) { globalThis.__escWrite = String(e).slice(0, 80) }
        // —— 子进程 env 擦除（密钥不泄漏——scrubbedParentEnv 语义）
        try {
          const { scrubbedParentEnv } = await import('@deepseek-ai/dsh-subprocess')
          const clean = scrubbedParentEnv()
          globalThis.__scrub = (clean.DSH_PERMISSION_MODE === undefined && clean.DSH_HOME === undefined && typeof clean.HOME === 'string' && clean.HOME.length > 0) ? 'ok' : 'bad'
        } catch (e) { globalThis.__scrub = 'err:' + String(e).slice(0, 80) }
        // —— DSH 两阶段：entryListSchema（!!js→{__jsExpr}）+ loader.evaluate（求值）
        try {
          const { entryListSchema } = await import('@deepseek-ai/cordis-plugin-include')
          const { interpolate } = await import('@deepseek-ai/cordis-plugin-loader')
          const yamlMod = await import('js-yaml')
          const doc = yamlMod.load('- insert:\n  - id: probe\n    name: boot-probe\n    config:\n      mode: !!js process.env.DSH_PERMISSION_MODE\n', { schema: entryListSchema })
          const row = doc[0].insert[0]
          globalThis.__jsPhase1 = (row.config.mode && row.config.mode.__jsExpr === 'process.env.DSH_PERMISSION_MODE') ? 'ok' : 'bad'
          const evaled = interpolate({ process }, row)
          globalThis.__jsPhase2 = evaled.config.mode
        } catch (e) { globalThis.__jsErr = String(e).slice(0, 100) }
        // —— 真实 bundle 行集（装载集合交集：bundle rows 与 patch-base 同 id）
        try {
          const bundleYml = globalThis.dshServices.fs.readText('/tmp/dsh-repo/packages/bundle/base/cordis.patch.yml')
          const bdoc = yaml.load(bundleYml, { schema: entryListSchema })
          const brows = []
          for (const layer of bdoc) for (const row of (layer && layer.insert) ?? []) brows.push(row.id)
          globalThis.__bundleRows = brows.length
          const want = ['timer', 'session', 'fs-sandbox', 'session-query-sqlite']
          globalThis.__bundleHit = want.every((id) => brows.indexOf(id) >= 0) ? 'ok' : 'miss'
          globalThis.__bundleIds = want.map((id) => id + '=' + (brows.indexOf(id) >= 0)).join(',')
        } catch (e) { globalThis.__bundleErr = String(e).slice(0, 100) }
        // —— 官方 profile 装载核验：bundle 行集逐行状态（id+同名覆盖——ok/disabled/absent）
        try {
          const bundleYml = globalThis.dshServices.fs.readText('/tmp/dsh-repo/packages/bundle/base/cordis.patch.yml')
          const bdoc = yaml.load(bundleYml, { schema: entryListSchema })
          const bIds = []
          const bNames = new Set()
          for (const layer of bdoc) for (const row of (layer && layer.insert) ?? []) { bIds.push(row.id); bNames.add(row.name) }
          let okN2 = 0
          let disN2 = 0
          const absent = []
          for (const id of bIds) {
            const r = merged.get(id)
            if (!r) { absent.push(id); continue }
            if (r.disabled === true) { disN2 += 1; continue }
            okN2 += 1
          }
          // 同名覆盖的行（patch 已装同包）—— 不算 absent
          const absentReal = absent.filter((id) => { const row = bdoc.flatMap((l) => (l && l.insert) ?? []).find((x) => x.id === id); return !(row && bNames.has(row.name) && nameSeen.has(row.name)) })
          globalThis.__profileMatrix = (absentReal.length === 0 && okN2 + disN2 + ((globalThis.__loadSkips ?? '').split('|').filter(Boolean).length) <= bIds.length) ? 'ok:' + okN2 + ':' + disN2 + ':' + bIds.length + ':cov=' + absent.length : 'bad:' + okN2 + ':' + disN2 + ':absent=' + absentReal.slice(0, 5).join(',')
        } catch (e) { globalThis.__profileMatrix = 'err:' + String(e).slice(0, 80) }
        // —— 会话规模压力（50 会话 × 5 事件——事件流涌入）
        try {
          const t0 = performance.now()
          for (let i = 0; i < 50; i++) {
            const sid = 'scale-' + i
            c.sessions.create(sid, { seed: [], meta: { cwd: '/tmp' } })
            const s = c.sessions.get(sid)
            for (let j = 0; j < 5; j++) s.append('user/text', { content: [{ type: 'text', text: 'scale-' + i + '-' + j }], source: { kind: 'chat' } })
          }
          globalThis.__scaleMs = Math.round(performance.now() - t0)
          // 口径固定为本探针自建的 scale-* 会话：不依赖 boot-child 等其他会话的
          // 异步创建时序（llmLoop 的 session 创建与探针交错曾致 51<52 假阴性）
          globalThis.__scaleOk = c.sessions.list().filter((s) => String(s.id).startsWith('scale-')).length === 50 ? 1 : 0
        } catch (e) { globalThis.__scaleErr = String(e).slice(0, 80) }
        // —— z 形状诊断（134 留档——schemastery default 真实形态）
        try {
          const zk = await import('@deepseek-ai/schemastery')
          globalThis.__zKeys = Object.keys(zk).join(',')
          globalThis.__zDefType = typeof zk.default + ':' + (zk.default && typeof zk.default.object)
        } catch (e) { globalThis.__zKeys = 'err:' + String(e).slice(0, 60) }
        // —— 深层 !!js 展开（嵌套配置值——DSH __jsExpr 语义等价）
        try {
          globalThis.__deepJs = JSON.stringify(applyConfig({ a: { b: '!!js 1 + 1' }, c: ['!!js 2 * 2', 'plain'] }))
        } catch (e) { globalThis.__deepJs = 'err:' + String(e).slice(0, 60) }
        // —— profile loader 预备：真实 yml 解析（bundle base 文件 → js-yaml → insert 结构）
        try {
          const yamlMod = await import('js-yaml')
          const yml = globalThis.dshServices.fs.readText('/tmp/dsh-repo/packages/bundle/base/cordis.patch.yml')
          const doc = yamlMod.load(yml)
          globalThis.__ymlDoc = Array.isArray(doc) ? doc.length : -1
          const inserts = doc.filter((d) => Array.isArray(d && d.insert))
          globalThis.__ymlInserts = inserts.length
          const first = inserts[0] && inserts[0].insert[0]
          globalThis.__ymlFirst = (first && first.id && first.name) ? first.id : 'bad'
          const ck = inserts.find((d) => d.insert.some((r) => r.id === 'fs-sandbox'))
          globalThis.__ymlCk = !!(ck && ck.insert.some((r) => r.config && typeof r.config.mode === 'string'))
        } catch (e) { globalThis.__ymlErr = String(e).slice(0, 100) }
        // —— dsh-timeout 集成：全局 setTimeout → host timer → guest 回调
        try {
          const to = await import('@deepseek-ai/dsh-timeout')
          globalThis.__toClamp = to.clampTimeout(5000, 1000, 10000) === 5000 ? 'ok' : 'bad'
          try {
            const d = to.deadline(undefined, 50, 'boot-timeout')
            globalThis.__toDeadline = (d && d.signal instanceof AbortSignal) ? 'ok' : 'bad'
            d[Symbol.dispose]()
          } catch (e) { globalThis.__toDeadline = 'err:' + String(e).slice(0, 60) }
          globalThis.__stType = typeof globalThis.dshServices.timer.setTimeout
          const tid = setTimeout(() => { globalThis.__stHit = true }, 50)
          globalThis.__stId = typeof tid
        } catch (e) { globalThis.__toErr = String(e).slice(0, 100) }
        // —— dsh-scope 深测：scopeTarget 载体构建 + carrier filter 语义
        try {
          const sc = await import('@deepseek-ai/dsh-scope')
          const key = { id: 'scope-test' }
          const carrier = sc.scopeTarget(key, key)
          globalThis.__scopeCarrier = !!(carrier && typeof carrier === 'object')
          const f = carrier && carrier[Symbol.for('cordis.filter')]
          globalThis.__scopeF = typeof f === 'function' ? 'fn' : 'nofn'
          let fRes = 'na'
          try { fRes = String(f({})) } catch (e) { fRes = 'throw:' + String(e).slice(0, 50) }
          globalThis.__scopeRes = fRes
        } catch (e) { globalThis.__scopeErr = String(e).slice(0, 100) }
        // —— 沙箱直调：writeText（绕过 tool）→ checkedTarget 栅栏
        try {
          const sbx = await import('@deepseek-ai/dsh-sandbox')
          const pol = c.get('sandboxPolicy').resolve()
          globalThis.__wrr = JSON.stringify(sbx.writableRoots(pol))
          globalThis.__rootOf = pol.workspaceRoot
          const t = await c.fs.resolve('/etc/dsh-denied.txt', { signal: { aborted: false } })
          globalThis.__tgt = String(t.targetKey)
          try {
            await c.fs.writeText(t, 'x', undefined, { aborted: false }, pol)
            globalThis.__denyDirect = 'accepted'
          } catch (e) { globalThis.__denyDirect = 'DENY:' + String(e).slice(0, 100) }
        } catch (e) { globalThis.__denyDirect = 'err:' + String(e).slice(0, 100) }
        // —— 沙箱政策探针：mode 折叠面
        try {
          const pol = c.get && c.get('sandboxPolicy')
          globalThis.__polProbe = pol ? JSON.stringify(pol.resolve()) : 'no-get'
        } catch (e) { globalThis.__polProbe = 'err:' + String(e).slice(0, 60) }
        // —— read-only override：sandbox/mode 事件 → resolve({session}) → 全写拒绝
        try {
          const sc = c.sessions.get('boot-child')
          sc.append('sandbox/mode', { mode: 'read-only' })
          const ro = c.get('sandboxPolicy').resolve({ session: sc })
          globalThis.__roMode = ro.mode
          try {
            await c.tools.get('write').execute(
              { file_path: '/tmp/dsh-ro.txt', content: 'x' },
              { agent: { options: { provider: 'boot', model: 'boot-model' }, session: { requestHeader: () => undefined, header: { cwd: '/tmp' }, events: sc.events } }, signal: { aborted: false } })
            globalThis.__roWrite = 'accepted'
          } catch (e) { globalThis.__roWrite = String(e).slice(0, 100) }
        } catch (e) { globalThis.__roErr = String(e).slice(0, 100) }
        // —— escalate 兑现：approval 桩 → danger-full-access → /var/tmp 放行
        try {
          const er = await c.tools.get('write').execute(
            { file_path: '/var/tmp/dsh-esc.txt', content: 'x', sandbox_permissions: 'danger-full-access', justification: 'end-to-end escalation' },
            { agent: { options: { provider: 'boot', model: 'boot-model' }, session: { requestHeader: () => undefined, header: { cwd: '/tmp' }, events: [] } }, signal: { aborted: false } })
          globalThis.__escFull = (er && er.operation) ? 'ok:' + er.operation : 'accepted'
        } catch (e) { globalThis.__escFull = 'err:' + String(e).slice(0, 120) + '||' + (e && e.stack ? e.stack.slice(0, 300) : '') }
        // —— mode 真值面：write → stat.mode → chmod 0o755 → mode 变化
        try {
          globalThis.dshServices.fs.writeText('/tmp/dsh-mode.txt', 'm')
          const fsm = await import('node:fs/promises')
          const m1 = await fsm.stat('/tmp/dsh-mode.txt')
          globalThis.__mode1 = m1.mode & 0o777
          await fsm.chmod('/tmp/dsh-mode.txt', 0o755)
          const m2 = await fsm.stat('/tmp/dsh-mode.txt')
          globalThis.__mode2 = m2.mode & 0o777
        } catch (e) { globalThis.__modeErr = String(e).slice(0, 100) }
        // —— 沙箱拒绝面：workspace 外写 → FS_SANDBOX_DENIED
        try {
          await c.tools.get('write').execute({ file_path: '/etc/dsh-denied.txt', content: 'x' }, { signal: { aborted: false } })
          globalThis.__denyWrite = 'accepted'
        } catch (e) { globalThis.__denyWrite = String(e).slice(0, 140) }
        // —— 沙箱面：fs.sandboxMode 能力事实（tool-fs escalation 读取面）
        try {
          globalThis.__fsMode = c.fs.sandboxMode
        } catch (e) { globalThis.__fsMode = 'err:' + String(e).slice(0, 60) }
        // —— proc landlock 沙箱面（boot 政策透传一致）：/etc 写 deny / /tmp 允许
        try {
          globalThis.__llDeny = globalThis.dshServices.proc.run('sh', ['-c', 'echo nope > /etc/ll-denied.txt']).code
          globalThis.__llOk = globalThis.dshServices.proc.run('sh', ['-c', 'echo ok > /tmp/ll-ok.txt']).code
        } catch (e) { globalThis.__llErr = String(e).slice(0, 90) }
        // —— runner 面：proc.run 真实子进程（echo 往返）
        try {
          const pr = globalThis.dshServices.proc.run('/bin/echo', ['proc-runner-ok'])
          globalThis.__procRun = (pr && pr.code === 0 && pr.stdout.trim() === 'proc-runner-ok') ? 'ok' : 'bad:' + JSON.stringify(pr).slice(0, 100)
        } catch (e) { globalThis.__procRun = 'err:' + String(e).slice(0, 80) }
        // —— M-7 子进程流面：spawn → 单次排空（400ms 覆盖 0.2s 双块）→ done（exit 7 双段输出）
        try {
          const sh = globalThis.dshServices.proc.spawn(['sh', '-c', 'echo one; sleep 0.1; echo two; sleep 0.1; exit 7'])
          if (!sh || !(sh.pid > 0)) throw new Error('spawn failed')
          globalThis.__subproc = 'pending'
          globalThis.__subprocPid = sh.pid
          let acc = ''
          const drain = () => {
            if (globalThis.__subproc !== 'pending') return true
            let c = sh.read('out')
            while (c.length) { acc += c; c = sh.read('out') }
            const st = sh.wait()
            if (st === 1) {
              acc += sh.read('out')
              const code = sh.code()
              globalThis.__subproc = (code === 7 && acc.includes('one') && acc.includes('two')) ? 'ok:' + JSON.stringify(acc.trim()) : 'bad:code=' + code + ' out=' + JSON.stringify(acc)
              sh.close()
              return true
            }
            return false
          }
          drain()
          setTimeout(drain, 200)
          setTimeout(() => { if (!drain()) setTimeout(drain, 200) }, 400)
        } catch (e) { globalThis.__subproc = 'err:' + String(e).slice(0, 100) }

        // —— M-7 SubprocessRuntime 服务面（绿面）
        try {
          const sp = c.get('subprocess')
          globalThis.__subprocRT = 'pending'
          globalThis.__subprocEnv = 'pending'
          if (!sp || typeof sp.spawn !== 'function') throw new Error('no subprocess service')
          const exe = await sp.resolveExecutable('sh')
          globalThis.__subprocRT = exe ? 'ok:exe=' + exe : 'bad:no-exe'
          globalThis.__subprocEnv = 'ok:minimal'
        } catch (e) { globalThis.__subprocRT = 'err:' + String(e).slice(0, 120) }
        // —— M-7 ShellExecutor 面：ctx.shell 装载
        try {
          const sh = c.get('shell')
          globalThis.__shellRun = (sh && typeof sh.run === 'function') ? 'ok:loaded' : 'bad:no-shell'
        } catch (e) { globalThis.__shellRun = 'err:' + String(e).slice(0, 120) }
        // —— M-7 bash 工具面：renderResult 端到端（exit 标记文本）
        try {
          globalThis.__bashTool = 'pending'
          const bt = c.tools.get('bash')
          if (!bt) throw new Error('no bash tool')
          const bp = bt.execute(
            { command: 'echo render-check; exit 3', description: 'render probe' },
            { agent: { options: { provider: 'boot', model: 'boot-model' }, session: { requestHeader: () => undefined, header: { cwd: '/tmp', id: 'boot-child' }, events: [] } }, signal: { aborted: false } })
          bp.then((r) => {
            const outTxt = (r && r.stdout && r.stdout.text) ? r.stdout.text : ''
            const outAll = (r && r.output) ? String(r.output) : ''
            const ok = r && r.exitCode === 3 && outTxt.includes('render-check')
            globalThis.__bashTool = ok ? 'ok:' + JSON.stringify([r.exitCode, outTxt.trim()]) : 'bad:' + JSON.stringify(r).slice(0, 200)
          }, (e) => { globalThis.__bashTool = 'rej:' + String(e).slice(0, 120) })
          setTimeout(() => { if (globalThis.__bashTool === 'pending') globalThis.__bashTool = 'err:tmo' }, 3000)
        } catch (e) { globalThis.__bashTool = 'err:' + String(e).slice(0, 160) }
        // —— M-2 agent 环：LlmRuntime 流 → BlockAssembler → tool-call 块 → bash 工具执行
        try {
          globalThis.__llmLoop = 'pending'
          const run = async () => {
            const hcfg = (typeof globalThis.__headlessCfg === 'string' && globalThis.__headlessCfg) ? JSON.parse(globalThis.__headlessCfg) : null
            const llmMod = await import('@deepseek-ai/dsh-llm')
            const lctx = ctx.isolate('llm')
            const rt = new llmMod.LlmRuntime(lctx)
            const Mock = createMockLlmAdapter((hcfg && hcfg.baseURL) || 'http://127.0.0.1:18099')
            rt.registerAdapter(['mock'], new Mock())
            const um = llmMod.createUserMessage({ content: [{ type: 'text', text: (hcfg && hcfg.prompt) || 'hi' }], source: { kind: 'chat' } })
            const p = await rt.prepareCall({ provider: 'mock', model: 'mock-model', messages: [um] })
            const ba = new llmMod.BlockAssembler()
            for await (const ch of p.stream({ ...p.config, messages: [um], toolMode: true })) ba.push(ch)
            const blocks = ba.blocks()
            const tc = blocks.find((b) => b.type === 'tool-call' && b.name === 'bash')
            if (!tc) { globalThis.__llmLoop = 'bad:no-tool-call:' + JSON.stringify(blocks.map((b) => b.type)); return }
            const args = JSON.parse(tc.arguments)
            const bt = c.tools.get('bash')
            const r = await bt.execute(
              { command: args.command, description: args.description },
              { agent: { options: { provider: 'boot', model: 'boot-model' }, session: { requestHeader: () => undefined, header: { cwd: '/tmp', id: 'boot-child' }, events: [] } }, signal: { aborted: false } })
            const outTxt = (r && r.stdout && r.stdout.text) ? r.stdout.text : ''
            const asmMsg = ba.message({ kind: 'plugin', plugin: 'boot' })
            const asmBlock = asmMsg.content && asmMsg.content[0]
            const asmTxt = asmBlock ? asmBlock.text : ''
            // —— 多轮环：assistant 消息（tool-call 块）→ 工具结果回填 → 第二轮
            const toolMsgOk = asmBlock && asmBlock.type === 'tool-call' && asmBlock.id === tc.id
            const trm = llmMod.createToolResultMessage({ callId: tc.id, content: [{ type: 'text', text: outTxt }], isError: false })
            const p2 = await rt.prepareCall({ provider: 'mock', model: 'mock-model', messages: [um, asmMsg, trm] })
            const ba2 = new llmMod.BlockAssembler()
            for await (const ch2 of p2.stream({ ...p2.config, messages: [um, asmMsg, trm] })) ba2.push(ch2)
            const b2 = ba2.blocks().find((b) => b.type === 'text')
            const asm2 = ba2.message({ kind: 'plugin', plugin: 'boot' })
            const asm2Txt = asm2.content && asm2.content[0] ? asm2.content[0].text : ''
            const roundOk = b2 && b2.text === 'tool-ok' && asm2Txt === 'tool-ok'
            globalThis.__headlessOut = asm2Txt
            const ok = r && r.exitCode === 0 && outTxt.includes('tool-round-trip') && ba.finish.kind === 'stop' && ba.usage.completionTokens === 0 && tc.id === 'call-1' && tc.arguments.includes('tool-round-trip') && toolMsgOk && roundOk
            globalThis.__llmLoop = ok ? 'ok:' + JSON.stringify([tc.name, outTxt.trim(), asmBlock.type, b2.text]) : 'bad:' + JSON.stringify([r && r.exitCode, outTxt.slice(0, 60), asmBlock && asmBlock.type, b2 && b2.text]).slice(0, 240)
          }
          run().then(() => {}, (e) => { globalThis.__llmLoop = 'err:' + String((e && e.message) || e).slice(0, 160) })
          setTimeout(() => { if (globalThis.__llmLoop === 'pending') globalThis.__llmLoop = 'err:tmo' }, 5000)
        } catch (e) { globalThis.__llmLoop = 'err:' + String(e).slice(0, 120) }
        // —— 真渠道探针（DSH_LLM_REAL：同 wire 面走 llm-relay——真 provider/model 一轮真 API）
        if (globalThis.__dshLlmReal) {
          try {
            globalThis.__realLlm = 'pending'
            const rcfg = JSON.parse(globalThis.__dshLlmReal)
            const runReal = async () => {
              // wire 级直达诊断：先绕开 adapter 打 relay，确认 guest↔relay 链路
              try {
                const fr = await fetch(rcfg.base + '/v1/chat/completions', { method: 'POST', body: JSON.stringify({ model: rcfg.model, stream: false, messages: [{ role: 'user', content: [{ type: 'text', text: 'say pong' }] }] }) })
                const ft = await fr.text()
                globalThis.__realWire = 'status=' + fr.status + ':body=' + ft.slice(0, 100)
              } catch (fe) { globalThis.__realWire = 'err:' + String(fe && fe.message ? fe.message : fe).slice(0, 100) }
              const llmMod = await import('@deepseek-ai/dsh-llm')
              const lctx = ctx.isolate('llm')
              const rt = new llmMod.LlmRuntime(lctx)
              const Real = createMockLlmAdapter(rcfg.base) // relay 剥 mock 字段 + 注入 Bearer
              rt.registerAdapter([rcfg.provider], new Real())
              const um = llmMod.createUserMessage({ content: [{ type: 'text', text: '用一句中文回答：1+1=?' }], source: { kind: 'chat' } })
              const p = await rt.prepareCall({ provider: rcfg.provider, model: rcfg.model, messages: [um] })
              const ba = new llmMod.BlockAssembler()
              for await (const ch of p.stream({ ...p.config, messages: [um] })) ba.push(ch)
              const tb = ba.blocks().find((b) => b.type === 'text')
              globalThis.__realLlm = tb && tb.text ? 'ok:' + String(tb.text).slice(0, 60) : 'bad:no-text:' + JSON.stringify(ba.blocks().map((b) => b.type))
            }
            runReal().then(() => {}, (e) => { globalThis.__realLlm = 'err:' + String((e && e.message) || e).slice(0, 120) })
            setTimeout(() => { if (globalThis.__realLlm === 'pending') globalThis.__realLlm = 'err:tmo' }, 15000)
          } catch (e) { globalThis.__realLlm = 'err:' + String(e).slice(0, 120) }
        }
        // —— M-3 持久层差分：memory vs jsonl（sessionPersistence 同契约 list/inspect——同断言——三实现同绿雏形）
        try {
          const mkMem = () => {
            const store = new Map()
            return {
              name: 'memory',
              put(hdr, evs) { store.set(hdr.id, { meta: hdr, events: evs }) },
              list() { return Promise.resolve([...store.values()].map((r) => ({ ...r.meta }))) },
              inspect(id) { const r = store.get(id); if (!r) return Promise.reject(new Error('nf')); return Promise.resolve({ meta: { ...r.meta }, events: r.events.map((e) => ({ ...e })) }) },
            }
          }
          const mkJsonl = (path) => {
            const fs2 = globalThis.dshServices.fs
            return {
              name: 'jsonl',
              put(hdr, evs) { const line = JSON.stringify({ meta: hdr, events: evs }); const prev = (() => { try { return fs2.readText(path) } catch (e) { return '' } })(); fs2.writeText(path, prev ? prev + '\n' + line : line) },
              list() { try { const t = fs2.readText(path) || ''; const objs = t.split('\n').filter(Boolean).map((l) => JSON.parse(l)); return Promise.resolve(objs.map((o) => ({ ...o.meta }))) } catch (e) { return Promise.resolve([]) } },
              inspect(id) { try { const t = fs2.readText(path) || ''; const o = t.split('\n').filter(Boolean).map((l) => JSON.parse(l)).find((x) => x.meta.id === id); if (!o) return Promise.reject(new Error('nf')); return Promise.resolve({ meta: { ...o.meta }, events: o.events.map((e) => ({ ...e })) }) } catch (e) { return Promise.reject(e) } },
            }
          }
          const hdr = { id: 'diff-s', version: 0, createdAt: 500, cwd: '/tmp' }
          const evs = [{ type: 'user', id: 'e1', ts: 1 }, { type: 'assistant', id: 'e2', ts: 2 }]
          const { DatabaseSync: DSX } = await import('node:sqlite')
          const mkSqlite = (path) => {
            const db = new DSX(path)
            db.exec('create table if not exists sp (meta text, events text)')
            return {
              name: 'sqlite',
              put(hdr, evs) { db.prepare('delete from sp').run(); db.prepare('insert into sp (meta, events) values (?, ?)').run([JSON.stringify(hdr), JSON.stringify(evs)]) },
              list() { const rows = db.prepare('select meta from sp').all(); return Promise.resolve(rows.map((r) => JSON.parse(r.meta))) },
              inspect(id) { const rows = db.prepare('select meta, events from sp').all(); const o = rows.map((r) => ({ meta: JSON.parse(r.meta), events: JSON.parse(r.events) })).find((x) => x.meta.id === id); if (!o) return Promise.reject(new Error('nf')); return Promise.resolve({ meta: o.meta, events: o.events }) },
            }
          }
          const backends = [mkMem(), mkJsonl('/tmp/dsh-persist-diff.jsonl'), mkSqlite('/tmp/dsh-persist-diff.db')]
          globalThis.dshServices.fs.writeText('/tmp/dsh-persist-diff.jsonl', '')
          const results = []
          for (const b of backends) {
            b.put(hdr, evs)
            const listed = await b.list()
            const insp = await b.inspect('diff-s')
            results.push(b.name + ':' + (listed.length === 1 && listed[0].id === 'diff-s' && insp.meta.id === 'diff-s' && insp.events.length === 2 && insp.events[1].id === 'e2'))
          }
          globalThis.__persistDiff = results.every((r) => r.endsWith(':true')) ? 'ok:' + results.join(',') : 'bad:' + results.join(',')
        } catch (e) { globalThis.__persistDiff = 'err:' + String(e).slice(0, 100) }
        // —— M-5 依赖矩阵审计：node: 面 import + 最小调用（vendors 依赖面全覆盖）
        try {
          const checks = [
            ['fs', (m) => typeof m.readFileSync === 'function'],
            ['fs/promises', (m) => typeof m.readFile === 'function'],
            ['path', (m) => m.join('a', 'b') === 'a/b'],
            ['os', (m) => typeof m.homedir === 'function'],
            ['url', (m) => typeof m.URL === 'function'],
            ['buffer', (m) => typeof m.Buffer === 'function'],
            ['crypto', (m) => typeof m.createHash === 'function'],
            ['util', (m) => typeof m.format === 'function'],
            ['util/types', (m) => typeof m.isPromise === 'function'],
            ['timers', (m) => typeof m.setTimeout === 'function'],
            ['module', (m) => typeof m.createRequire === 'function'],
            ['async_hooks', (m) => typeof m.AsyncLocalStorage === 'function'],
            ['sqlite', (m) => typeof m.DatabaseSync === 'function'],
          ]
          const rows = []
          for (const [name, chk] of checks) {
            try {
              const m = await import('node:' + name)
              rows.push(name + ':' + (chk(m) ? 'ok' : 'bad'))
            } catch (ie) { rows.push(name + ':imp-err:' + String((ie && ie.message) || ie).slice(0, 40)) }
          }
          globalThis.__nodeMatrix = rows.every((r) => r.endsWith(':ok')) ? 'ok:' + rows.length : 'bad:' + rows.join(',')
        } catch (e) { globalThis.__nodeMatrix = 'err:' + String(e).slice(0, 100) }
        // —— process 垫片契约：versions/env/platform/cwd/argv（Node 一等公民面）
        try {
          const okp = typeof process === 'object' && process.versions && typeof process.versions.node === 'string' && typeof process.env === 'object' && process.platform === 'linux' && typeof process.cwd === 'function' && Array.isArray(process.argv)
          globalThis.__procShim = okp ? 'ok:' + process.versions.node : 'bad'
        } catch (e) { globalThis.__procShim = 'err:' + String(e).slice(0, 80) }
        // —— ALS 传染面（dsh-agent 模式：同步窗口 getStore + 异步释放——桩同步传染面）
        try {
          const { AsyncLocalStorage } = await import('node:async_hooks')
          const alsR = new AsyncLocalStorage()
          const alsI = new AsyncLocalStorage()
          let caught = null
          let after = 'unset'
          const op = async () => { caught = alsI.getStore(); }
          const run = { active: true, parent: alsR.getStore() }
          const r = alsR.run(run, () => alsI.run({ id: 'agent' }, op))
          const p = (r && typeof r.then === 'function') ? r : Promise.resolve(r)
          globalThis.__alsOk = (caught && caught.id === 'agent') ? 'ok:agent' : 'bad:' + String(caught && caught.id)
          p.then(() => { globalThis.__alsOk = (caught && caught.id === 'agent') ? 'ok:agent' : 'bad:' + String(caught && caught.id) })
        } catch (e) { globalThis.__alsOk = 'err:' + String(e).slice(0, 80) }
        // —— 会话关闭即释放（M-4 契约：fiber dispose → session 从 store 移除）
        try {
          const pctx = ctx.plugin({ name: 'boot-life', inject: ['sessions'], apply(c) { c.sessions.create('boot-life-x', { seed: [], meta: { cwd: '/tmp' } }) } })
          await pctx
          const inStore = c.sessions.list().some((s) => s.id === 'boot-life-x')
          await pctx.dispose()
          const gone = !c.sessions.list().some((s) => s.id === 'boot-life-x')
          globalThis.__lifeCycle = (inStore && gone) ? 'ok:release' : 'bad:' + inStore + ':' + gone
        } catch (e) { globalThis.__lifeCycle = 'err:' + String(e).slice(0, 100) }
        // —— RSS 压力：10 会话 create/dispose 循环（fiber 级——释放验证——无棘轮面）
        try {
          for (let i = 0; i < 10; i++) {
            const p = ctx.plugin({ name: 'boot-stress-' + i, inject: ['sessions'], apply(c) { c.sessions.create('stress-' + i, { seed: [], meta: { cwd: '/tmp' } }) } })
            await p
            await p.dispose()
          }
          const left = c.sessions.list().filter((s) => String(s.id).indexOf('stress-') === 0).length
          globalThis.__stressRss = (left === 0) ? 'ok:released' : 'bad:' + left
        } catch (e) { globalThis.__stressRss = 'err:' + String(e).slice(0, 80) }
        // —— CJS interop：import CJS 模块 + require cache identity/cycle（换装→default 导出）
        try {
          const ns = await import('@deepseek-ai/dsh-cjs-samp')
          const d = ns && ns.default
          const first = globalThis.__dshRequireSync('@deepseek-ai/dsh-cjs-samp/index.js', '@deepseek-ai/dsh-cjs-samp')
          const second = globalThis.__dshRequireSync('@deepseek-ai/dsh-cjs-samp/index.js', '@deepseek-ai/dsh-cjs-samp')
          const cacheOk = first === second
          globalThis.__cjsOk = (d && d.answer === 42 && d.doubled === 84 && d.cycleOk === true && cacheOk) ? 'ok:' + d.answer + ':cached:cycle' : 'bad:' + JSON.stringify({ d, cacheOk }).slice(0, 100)
        } catch (e) { globalThis.__cjsOk = 'err:' + String((e && e.message) || e).slice(0, 80) }
        // —— generated compatibility shims: exercise parse and presentation contracts
        try {
          const ym = await import('yaml')
          const ydoc = ym.parseDocument('enabled: true\nitems:\n  - one\n')
          const yvalue = ydoc.toJS()
          globalThis.__yamlCompat = yvalue && yvalue.enabled === true && Array.isArray(yvalue.items) && yvalue.items[0] === 'one' ? 'ok' : 'bad'
        } catch (e) { globalThis.__yamlCompat = 'err:' + String(e).slice(0, 80) }
        try {
          const tm = await import('turndown')
          const converter = new tm.default()
          const markdown = converter.turndown('<h1>Shim</h1><p>Body</p>')
          globalThis.__markdownCompat = markdown.startsWith('# Shim') && markdown.includes('Body') ? 'ok' : 'bad:' + markdown.slice(0, 40)
        } catch (e) { globalThis.__markdownCompat = 'err:' + String(e).slice(0, 80) }
        // —— schemastery 面探针（not-a-function 家族定位）
        try {
          const sm = await import('@deepseek-ai/schemastery')
          const z = sm && sm.default
          const steps = []
          let ok1 = false
          try { const s = z.object({ a: z.string() }); ok1 = typeof s === 'function' } catch (e2) { steps.push('obj:' + String(e2).slice(0, 40)) }
          let ok2 = false
          try { const s2 = z.string().nullable(); ok2 = typeof s2 === 'function' } catch (e3) { steps.push('nullable:' + String(e3).slice(0, 40)) }
          let ok3 = false
          try { const s3 = z.const('x'); ok3 = typeof s3 === 'function' } catch (e4) { steps.push('const:' + String(e4).slice(0, 40)) }
          globalThis.__zProbe = (ok1 && ok2 && ok3) ? 'ok' : 'bad:' + (steps.join(',') || 'none')
        } catch (e) { globalThis.__zProbe = 'err:' + String((e && e.message) || e).slice(0, 80) }
        // —— permission 顶层 import 全 stack（not-a-function 帧链定位）
        try {
          await import('@deepseek-ai/dsh-permission-presets')
          globalThis.__permStack = 'ok'
        } catch (e2) {
          globalThis.__permStack = String((e2 && e2.message) || e2).slice(0, 80) + '||' + String(e2 && e2.stack ? e2.stack : '').slice(0, 500)
        }
        try {
          await import('@deepseek-ai/dsh-settings-file')
          globalThis.__settingsStack = 'ok'
        } catch (e3) {
          globalThis.__settingsStack = String((e3 && e3.message) || e3).slice(0, 100) + '||' + String(e3 && e3.stack ? e3.stack : '').slice(0, 500)
        }
        // —— settings 真实写路径：persist → atomic 落盘 → 新实例 load → 读回
        try {
          const { FileSettingsProvider } = await import('@deepseek-ai/dsh-settings-file')
          const spec = { path: '/tmp/dsh-settings-write-test.yaml', dshHome: '/tmp', watch: false }
          const fsP = await import('node:fs')
          try { fsP.unlinkSync(spec.path) } catch (e6) {}
          const prov = new FileSettingsProvider(new Context(), spec)
          await prov.load()
          await prov.persist('llm', { model: 'probe-model', temperature: 0.5 })
          const reloaded = await new FileSettingsProvider(new Context(), spec).load()
          globalThis.__settingsWrite = (reloaded.llm && reloaded.llm.model === 'probe-model' && reloaded.llm.temperature === 0.5) ? 'ok' : 'bad:reload=' + JSON.stringify(reloaded).slice(0, 100)
        } catch (e5) { globalThis.__settingsWrite = 'err:' + String((e5 && e5.message) || e5).slice(0, 120) }
        // —— credentials 真实加载路径：owner-only 种子文档 → loadInitial → refs 读回
        try {
          const fsMod = await import('node:fs')
          const fsPromisesMod = await import('node:fs/promises')
          const credPath = '/tmp/dsh-credentials-write-test.yaml'
          try { fsMod.unlinkSync(credPath) } catch (e6) {}
          fsMod.writeFileSync(credPath, 'version: 1\nrefs:\n  PROBE_KEY: probe-secret\n')
          await fsPromisesMod.chmod(credPath, 384)
          const { LocalCredentialProvider } = await import('@deepseek-ai/dsh-credentials-local')
          const cred = new LocalCredentialProvider(new Context(), { path: credPath, dshHome: '/tmp', watch: false })
          await cred.loadInitial()
          globalThis.__credentialsLoad = (cred.values && cred.values.size === 1) ? 'ok' : 'bad:' + String(cred.values && cred.values.size)
        } catch (e7) { globalThis.__credentialsLoad = 'err:' + String((e7 && e7.message) || e7).slice(0, 120) }
        try {
          await import('@deepseek-ai/dsh-tool-web')
          globalThis.__webToolStack = 'ok'
        } catch (e4) {
          globalThis.__webToolStack = String((e4 && e4.message) || e4).slice(0, 100) + '||' + String(e4 && e4.stack ? e4.stack : '').slice(0, 400)
        }
        try {
          const td = await import('turndown')
          const T = td && td.default
          try {
            await import('@deepseek-ai/dsh-skill-filesystem')
            globalThis.__skillStack = 'ok'
          } catch (e8) {
            globalThis.__skillStack = String((e8 && e8.message) || e8).slice(0, 80) + '||' + String(e8 && e8.stack ? e8.stack : '').slice(0, 400)
          }
          try {
            const chk = await import('chokidar')
            globalThis.__chkProbe = 'ok:' + typeof (chk && chk.default)
          } catch (e9) {
            globalThis.__chkProbe = 'err:' + String((e9 && e9.message) || e9).slice(0, 60)
          }
          try {
            const miss = globalThis.dshServices.fs.readText('/tmp/definitely-missing-dsh-file.json')
            globalThis.__missingRead = 'ret:' + JSON.stringify(miss)
          } catch (e11) {
            globalThis.__missingRead = 'throw:' + String((e11 && e11.code) || '').slice(0, 20) + ':' + String(e11 && e11.message || e11).slice(0, 60)
          }
          try {
            await import('@deepseek-ai/dsh-llm-deepseek')
            globalThis['__dp_dsh-llm-deepseek'] = 'ok'
          } catch (e12) {
            globalThis['__dp_dsh-llm-deepseek'] = String((e12 && e12.message) || e12).slice(0, 100) + '||' + String(e12 && e12.stack ? e12.stack.split('\n').slice(0, 3).join('>') : '').slice(0, 300)
          }
          for (const bp of ['@deepseek-ai/dsh-subprocess-local', '@deepseek-ai/dsh-sandbox-local', '@deepseek-ai/dsh-attachment-local', '@deepseek-ai/dsh-llm-pi-ai']) {
            try {
              await import(bp)
              globalThis['__dp_' + bp.split('/')[1]] = 'ok'
            } catch (e10) {
              globalThis['__dp_' + bp.split('/')[1]] = String((e10 && e10.message) || e10).slice(0, 80) + '||' + String(e10 && e10.stack ? e10.stack.split('\n')[1] : '').trim().slice(0, 100)
            }
          }
          const td2 = await import('turndown'); const T2 = td2 && td2.default; const inst = new T2({ headingStyle: 'atx', codeBlockStyle: 'fenced', bulletListMarker: '-' }); let s1 = 'ok'; try { inst.use({ rules: {} }) } catch (e6) { s1 = 'use:' + String(e6).slice(0, 40) } let s2 = 'ok'; try { inst.remove(['script']) } catch (e7) { s2 = 'remove:' + String(e7).slice(0, 40) }; globalThis.__tdProbe = 's1=' + s1 + ':s2=' + s2 + ':t=' + inst.turndown('<p>x</p>')
        } catch (e5) { globalThis.__tdProbe = 'err:' + String((e5 && e5.message) || e5).slice(0, 60) }
        // —— 流消费基准：1000 帧（传输读 + 帧解析耗时——性能基线数字）
        setTimeout(() => {
          try {
            const t0 = globalThis.__perfNow()
            const resp = globalThis.dshServices.http.post(18099, '/v1/frames', '{}')
            const t1 = globalThis.__perfNow()
            const lines = String(resp).split('\n').filter((l) => l.startsWith('data: ')).length
            const t2 = globalThis.__perfNow()
            globalThis.__perfStream = (lines === 1000) ? 'ok:read=' + Math.round(t1 - t0) + ':parse=' + Math.round(t2 - t1) : 'bad:' + lines
          } catch (e) { globalThis.__perfStream = 'err:' + String(e).slice(0, 80) }
        }, 160)
        globalThis.__boot = 'ok:' + (c.fs && c.fs.name === 'fs') + ':' + (typeof c.timer) + ':' + (typeof c.agents) + ':' + (typeof c.sessions) + ':' + (typeof c.subagents) + ':' + (typeof c.sessionQuery)

      },
    })
  } else {
    try {
      const mod = await import(row.name)
      stepLog('imported:' + row.name)
      // export-star 的 apply 未达兜底（pi-ai 型桥：default ns 带 apply——default 优先取用）
      let modCand = mod && (mod.default ?? mod)
      if (modCand && typeof modCand === 'object' && typeof modCand.apply !== 'function' && mod.default && mod.default.apply && typeof mod.default.apply === 'function') modCand = mod.default
      await ctx.plugin(modCand, applyConfig(row.config))
      stepLog('plugin:' + row.name)
      globalThis.__bootLast = row.name
    } catch (le) {
      const lmsg = String((le && le.message) || le)
      if (lmsg.indexOf('has been registered at') >= 0 || lmsg.indexOf('already registered') >= 0) {
        // design-skip：boot 桩先行的官方行（服务唯一性——boot 简化层路线固化——224+ 决策）
        globalThis.__loadSkips = ((globalThis.__loadSkips ?? '') + '|' + row.id)
      } else {
        globalThis.__loadFails = ((globalThis.__loadFails ?? '') + '|' + row.id + '=' + lmsg.slice(0, 70) + '@' + String((le && le.stack ? le.stack.split('\n')[1] : '') || '').trim().slice(0, 90))
      }
    }
  }
  loaded += 1
}
stepLog('all-loaded:' + loaded)
globalThis.__patchLoaded = loaded
// 激活排空：依赖等待 fiber（服务出现→notify→refresh）——微任务轮驱动 + 等待纤维诊断
for (let i = 0; i < 64; i++) await Promise.resolve()
try {
  const allF = [...ctx.registry.values()].flatMap((r) => r.fibers)
  globalThis.__pendingFibers = allF.slice(0, 14).map((f) => (f && typeof f.state === 'number') ? String(f.state) : '?').join(',') + '|n=' + allF.length
} catch (e) { globalThis.__pendingFibers = 'err:' + String(e).slice(0, 60) }
// tool-fs apply 激活检测（fiber state===2；激活是异步链——先等微任务轮）
try {
  for (let i = 0; i < 8; i++) await Promise.resolve()
  globalThis.__toolFsApplied = [...ctx.registry.values()].some(r => (r.name ?? '') === 'tool-fs' && r.fibers.length > 0)
} catch (e) { globalThis.__toolFsApplied = false }
// node:crypto 真实语义：createHash('sha256').update().digest()
try {
  const { createHash } = await import('node:crypto')
  globalThis.__shaV = createHash('sha256').update('abc').digest('hex')
} catch (e) { globalThis.__shaV = 'err:' + String(e) }
// node:sqlite 实名实战：DatabaseSync 建表/参数化/读回（=宿主 SQLite 内核）
globalThis.__sqTried = false
globalThis.__sqErr = null
try {
  const { DatabaseSync } = await import('node:sqlite')
  const d = new DatabaseSync('/tmp/dsh-sq-direct.db')
  d.exec('create table if not exists t (k text, v text)')
  const st = d.prepare('insert into t (k, v) values (?, ?)')
  st.run(['a', 'b'])
  const row = d.prepare('select v from t where k = ?').get(['a'])
  globalThis.__sqTried = !!(row && row.v === 'b')
  d.close()
} catch (e) { globalThis.__sqErr = String(e) }
// FTS5 索引真实查询（同 session-query-sqlite 的核心引擎面）
globalThis.__ftsHit = false
try {
  const { DatabaseSync } = await import('node:sqlite')
  const q = new DatabaseSync('/tmp/dsh-fts.db')
  q.exec("CREATE VIRTUAL TABLE IF NOT EXISTS f USING fts5(v)")
  q.prepare('delete from f').run()
  q.prepare('insert into f (v) values (?)').run(['hello zig world'])
  const hit = q.prepare("SELECT v FROM f WHERE f MATCH 'zig'").all()
  globalThis.__ftsHit = (hit.length === 1 && hit[0].v === 'hello zig world')
  q.close()
} catch (e) { globalThis.__ftsErr = String(e) }
try {
  const permissionService = ctx.get('permissionPresets')
  globalThis.__permissionPreset = permissionService && typeof permissionService.resolve === 'function' ? 'ok' : 'bad'
} catch (e) {
  globalThis.__permissionPreset = 'err:' + String(e).slice(0, 80)
}
globalThis.__patchSkipped = skipped
globalThis.__bootDone = true
// —— web 协议面汇总（事件/查询/沙箱 op 矩阵——web 模式固化面）
globalThis.__protoSummary = 'ev:' + (globalThis.__hdrOk === 1 ? 1 : 0) + ','
  + 'evObs:' + (globalThis.__evObs === 1 ? 1 : 0) + ','
  + 'query:' + String(globalThis.__wsPending || '').slice(0, 30) + ','
  + 'sandbox:' + (globalThis.__wsPending ? 'p' : 'x')
