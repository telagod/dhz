#!/usr/bin/env python3
"""生成 runtime/src/app_modules.zig：真实插件闭包 -> 内嵌模块表（@embedFile 形态）。

v2（DAG 闭包管线）：
  - 种子包（默认现有 5 + --seed 追加）→ 递归遍历其 `from "@deepseek-ai/..."` 依赖
    （node: 跳过；第三方包按 main 解析；上限 32 包防失控）
  - 每包拷贝 <pkg>/lib/index.js → app-esm/<pkg>/index.js；`lib/` 下其余 .js 一并
    拷贝（相对导入 './lib/xxx.js' → 模块名 '<pkg>/lib/xxx.js'）
  - 表 = 拷贝的所有文件（canonical file path 作为模块名）
用法: tools/gen-app-esm.py [--seed @deepseek-ai/dsh-fs]
"""
import os, re, sys, shutil

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, "src", "app-esm")
OUT = os.path.join(ROOT, "src", "app_modules.zig")
# DSH 安装（npx 部署）的 node_modules——打包产物 lib/ 即真实闭包源
NM = os.environ.get("DSH_NODE_MODULES") or os.path.expanduser(
    "~/.npm/_npx/1e7f6d9597241db0/node_modules")

BASE_MODULES = [
    "@deepseek-ai/dsh-anonymous-user-id",
    "@deepseek-ai/dsh-home-paths",
    "@deepseek-ai/cordis",
    "@deepseek-ai/cosmokit",
    "@deepseek-ai/cordis-plugin-timer",
    "@deepseek-ai/dsh-sandbox-policy",
    "@deepseek-ai/dsh-fs-sandbox",
    "js-yaml",
    "@deepseek-ai/cordis-plugin-include",
    "@deepseek-ai/cordis-plugin-loader",
    "@deepseek-ai/dsh-subprocess",
    "@deepseek-ai/dsh-cjs-samp",
]

MAX_PACKAGES = 256
# 第三方启动种子（chokidar 型深依赖——gen 仅 main 递归的局限面——显式入集）
THIRD_PARTY_SEEDS = ["picomatch", "detect-libc", "eventsource-parser", "readdirp", "typebox", "semver", "partial-json"]


# 原生绑定/不可闭包依赖（node-ffi 等）：DAG 排除（其消费方未激活时无碍）
EXCLUDE = {"koffi", "sharp"}

# shim 覆盖：包名 -> 仿制源码（闭包真实包不值得（zod 全树 135 模块）；消费面极小——
# 按 DSH 实链用到的 API 子集仿制；落 app-esm/<pkg>/index.js（resolver 候选链天然命中））
SHIM_OVERRIDES = {
    "@opentelemetry/exporter-logs-otlp-http": '''// Embedded OTLP/HTTP exporter: keep the SDK exporter contract without Node socket transport.
const SUCCESS = 0;
const FAILED = 1;
function toJsonRecord(record) {
    return {
        timeUnixNano: record && (record.timestamp ?? record.observedTimestamp),
        severityNumber: record && record.severityNumber,
        severityText: record && record.severityText,
        body: record && record.body,
        attributes: record && record.attributes,
        droppedAttributesCount: record && record.droppedAttributesCount,
    };
}
export class OTLPLogExporter {
    constructor(config = {}) { this.url = config.url; this.headers = config.headers || {}; this._shutdown = false; }
    export(records, callback) {
        if (this._shutdown) { callback({ code: FAILED, error: new Error('OTLPLogExporter is shut down') }); return; }
        const payload = { resourceLogs: [{ resource: {}, scopeLogs: [{ scope: {}, logRecords: (records || []).map(toJsonRecord) }] }] };
        if (!this.url || typeof globalThis.fetch !== 'function') { callback({ code: FAILED, error: new Error('OTLPLogExporter: fetch or url unavailable') }); return; }
        Promise.resolve(globalThis.fetch(this.url, { method: 'POST', headers: Object.assign({ 'Content-Type': 'application/json' }, this.headers), body: JSON.stringify(payload) }))
            .then((response) => { if (!response || response.ok === false) throw new Error('OTLPLogExporter: HTTP export failed'); callback({ code: SUCCESS }); })
            .catch((error) => callback({ code: FAILED, error }));
    }
    forceFlush() { return Promise.resolve(); }
    shutdown() { this._shutdown = true; return Promise.resolve(); }
}
export default OTLPLogExporter;''',

    "zod": '''// zod compatibility subset used by the embedded DSH graph.
class ZodStr { parse(v) { if (typeof v !== 'string') throw new Error('zod: expected string'); return v } optional() { return this } nullable() { return this } refine() { return this } catch() { return this } min() { return this } max() { return this } regex() { return this } trim() { return this } email() { return this } url() { return this } uuid() { return this } startsWith() { return this } endsWith() { return this } transform(fn) { const s = this; return { parse(v) { return fn(s.parse(v)); } }; } default(d) { const s = this; return { parse(v) { return v ?? d } } } }
class ZodNull { parse(v) { if (v !== null) throw new Error('zod: expected null'); return null } nullable() { return this } }
class ZodUnion { constructor(ss) { this.ss = ss } parse(v) { for (const s of this.ss) { try { return s.parse(v) } catch {} } throw new Error('zod: union failed') } strict() { return this } nullable() { return this } optional() { return this } catch() { return this } refine() { return this } passthrough() { return this } transform(fn) { const s = this; return { parse(v) { return fn(s.parse(v)); } }; } }
class ZodObj { constructor(shape) { this.shape = shape } parse(v) { const o = {}; for (const k of Object.keys(this.shape)) o[k] = this.shape[k].parse(v?.[k]); return { ...o, ...v }; } strict() { return this } optional() { return this } nullable() { return this } transform(fn) { const s = this; return { parse(v) { return fn(s.parse(v)); } }; } refine() { return this } catch(fn) { const s = this; return { parse(v) { try { return s.parse(v); } catch (e) { return fn(e); } } }; } passthrough() { return this } }
class ZodLit { constructor(v) { this.v = v } parse(v) { if (v !== this.v) throw new Error('zod: literal mismatch'); return v } optional() { return this } nullable() { return this } }
class ZodDiscriminated { constructor(tag, variants) { this.tag = tag; this.variants = Array.isArray(variants) ? variants : Object.values(variants) } parse(v) { for (const r of this.variants) { try { return r.parse(v); } catch {} } throw new Error('zod: bad discriminator'); } optional() { return this } nullable() { return this } }
const chain = (fn) => Object.assign(fn, { int: () => fn, nonnegative: () => fn, positive: () => fn, min: () => fn, max: () => fn, optional: () => fn, nullable: () => fn, default: (d) => ({ parse(v) { return v ?? d; } }), parse: (v) => fn.parse(v) });
class ZodNum { parse(v) { if (typeof v !== 'number') throw new Error('zod: expected number'); return v } int() { return this } nonnegative() { return this } positive() { return this } min() { return this } max() { return this } optional() { return this } nullable() { return this } default(d) { const s = this; return { parse(v) { return v ?? d; } } } }
class ZodBool { parse(v) { if (typeof v !== 'boolean') throw new Error('zod: expected boolean'); return v } optional() { return this } nullable() { return this } }
class ZodArr { constructor(inner) { this.inner = inner } parse(v) { if (!Array.isArray(v)) throw new Error('zod: expected array'); return v.map((x) => this.inner ? this.inner.parse(x) : x); } optional() { return this } nullable() { return this } }
export const z = { string: () => new ZodStr(), null: () => new ZodNull(), number: () => new ZodNum(), boolean: () => new ZodBool(), array: (inner) => new ZodArr(inner), union: (...ss) => new ZodUnion(ss), object: (shape) => new ZodObj(shape), literal: (v) => new ZodLit(v), discriminatedUnion: (tag, variants) => new ZodDiscriminated(tag, variants) };
export default z;''',
}

# builtin 词典：node:<name> -> stub 源码（闭包依赖扫描自动装箱；未知名构建期报错）
STUBS = {
    "node:crypto": "export function randomUUID() { return globalThis.dshServices.crypto.randomUUID(); } export function createHash() { const _d = []; return { update(d) { _d.push(String(d)); return this; }, digest() { const h = globalThis.dshServices.crypto.sha256(_d.join('')); return h; } }; } export function randomBytes(n) { const u = new Uint8Array(n || 16); for (let i = 0; i < u.length; i++) u[i] = Math.floor(Math.random() * 256); return u; }",
    "node:fs": "export function readFileSync(p) { return globalThis.dshServices.fs.readText(p); } export function accessSync(p) { globalThis.dshServices.fs.size(p); } export function statSync(p) { const s = globalThis.dshServices.fs.size(p); return { size: s, isFile: () => true, isDirectory: () => false, isSymbolicLink: () => false }; } export function realpathSync(p) { return globalThis.dshServices.fs.realpath(p); } export const constants = { F_OK: 0, R_OK: 4, W_OK: 2, X_OK: 1, R_OK: 4 }; export function writeFileSync(p, d) { return globalThis.dshServices.fs.writeText(p, String(d)); } export function mkdirSync(p) { return globalThis.dshServices.fs.mkdir(p); } export function existsSync(p) { try { globalThis.dshServices.fs.size(p); return true; } catch (e) { return false; } } export function createReadStream(p, opts) { const t = globalThis.dshServices.fs.readText(p); const bytes = new TextEncoder().encode(t); const end = opts && typeof opts.end === 'number' ? Math.min(opts.end, bytes.length) : bytes.length; return { on() { return this; }, pause() { return this; }, resume() { return this; }, [Symbol.asyncIterator]() { let pos = 0; return { next() { if (pos >= end) return Promise.resolve({ done: true }); const n = Math.min(pos + 65536, end); const slice = bytes.subarray(pos, n); pos = n; return Promise.resolve({ done: false, value: slice }); }, [Symbol.asyncIterator]() { return this; } }; } }; } export function readdirSync(p) { return globalThis.dshServices.fs.list(p); } export function lstatSync(p) { return statSync(p); } export function watch() { return { close() {} }; } export function stat(p) { return statSync(p); } export function readFileSync2() {} export function mkdtempSync(prefix) { const d = String(prefix || '/tmp/') + 'dsh-' + Math.random().toString(36).slice(2, 8); globalThis.dshServices.fs.mkdir(d); return d; } export function watchFile() {} export function unwatchFile() {}",
    "node:fs/promises": "export async function access(p, mode) { try { globalThis.dshServices.fs.size(p); return undefined; } catch (e) { const err = new Error('no such file or directory'); err.code = 'ENOENT'; throw err; } } export const constants = { F_OK: 0, R_OK: 4, W_OK: 2, X_OK: 1 }; export async function readFile(p, opts) { const t = globalThis.dshServices.fs.readText(p); const enc = typeof opts === 'string' ? opts : (opts && opts.encoding); if (enc) return t; return new TextEncoder().encode(t); } export async function writeFile(p, d) { return globalThis.dshServices.fs.writeText(p, String(d)); } export async function mkdir(p) { return globalThis.dshServices.fs.mkdir(p); } export async function stat(p, opts) { const st = globalThis.dshServices.fs.stat(p); const big = opts && opts.bigint; return { dev: big ? 1n : 1, ino: big ? BigInt(st.inode) : st.inode, size: big ? BigInt(st.size) : st.size, mode: big ? BigInt(st.mode) : st.mode, mtimeNs: big ? 0n : 0, ctimeNs: big ? 0n : 0, isFile: () => st.kind === 'file', isDirectory: () => st.kind === 'directory', isSymbolicLink: () => false }; } export async function lstat(p) { return stat(p); } export async function readdir(p) { return globalThis.dshServices.fs.list(p); } export async function realpath(p) { return globalThis.dshServices.fs.realpath(p); } export async function rename(a, b) { return globalThis.dshServices.fs.rename(a, b); } export async function rm(p) { return globalThis.dshServices.fs.remove(p); } export async function unlink(p) { return globalThis.dshServices.fs.remove(p); } export async function chmod(p, m) { return globalThis.dshServices.fs.chmod(p, m); } export async function link() {} export async function opendir(p) { return { close: async () => {}, [Symbol.asyncIterator]() { let done = false; return { next() { if (done) return Promise.resolve({ done: true }); done = true; try { globalThis.dshServices.fs.list(p); return Promise.resolve({ done: false, value: { name: '.', isDirectory: () => true } }); } catch (e) { return Promise.resolve({ done: true }); } }, [Symbol.asyncIterator]() { return this; } }; } }; } export async function open(p, flags, mode) { const isWrite = typeof flags === 'string' && flags.indexOf('w') >= 0; const t = isWrite ? '' : globalThis.dshServices.fs.readText(p); const bytes = new TextEncoder().encode(t); const st = { size: bytes.length, isFile: () => true, isDirectory: () => false, isSymbolicLink: () => false }; let pos = 0; return { stat() { return st; }, read(buf, offset, length, position) { if (position != null && position >= 0) pos = position; const n = Math.min(length, bytes.length - pos); for (let i = 0; i < n; i++) buf[offset + i] = bytes[pos + i]; pos += n; return { bytesRead: n }; }, writeFile(d, o) { globalThis.dshServices.fs.writeText(p, String(d === undefined ? o : d)); }, sync() {}, chmod() {}, close() {} }; } export async function mkdtemp(prefix) { const d = String(prefix || '/tmp/') + 'dsh-' + Math.random().toString(36).slice(2, 8); globalThis.dshServices.fs.mkdir(d); return d; } export async function truncate(p, len) { const t = globalThis.dshServices.fs.readText(p); globalThis.dshServices.fs.writeText(p, t.slice(0, len != null ? len : t.length)); }",
    "node:buffer": "export const constants = { F_OK: 0, R_OK: 4, W_OK: 2, X_OK: 1 }; export class Buffer extends Uint8Array { static from(x) { return new Uint8Array(x); } static alloc(n) { return new Uint8Array(n); } static isBuffer() { return false; } }",
    "node:os": "export function homedir() { return process.env.HOME ?? '.'; } export function tmpdir() { return process.env.TMPDIR ?? '/tmp'; } export function platform() { return 'linux'; } export function availableParallelism() { return 1; } export function type() { return 'Linux'; } export function arch() { return 'x64'; } export function hostname() { return 'localhost'; } export function release() { return 'embedded'; } export function endianness() { return 'LE'; }",
    "node:path": "export const sep = '/'; export function dirname(p) { const i = p.lastIndexOf('/'); return i < 0 ? '.' : (i === 0 ? '/' : p.slice(0, i)); } export function basename(p, ext) { const i = p.lastIndexOf('/'); let b = i < 0 ? p : p.slice(i + 1); if (ext && b.endsWith(ext)) b = b.slice(0, -ext.length); return b; } export function extname(p) { const b = basename(p); const i = b.lastIndexOf('.'); return i <= 0 ? '' : b.slice(i); } export function join() { let out = ''; for (const a of arguments) { if (!a) continue; out = out ? out + '/' + String(a).replace(/^\/+|\/+$/g, '') : String(a); } return out; } export function resolve(...parts) { const seg = []; for (const r of parts) { const rs = String(r); if (rs.startsWith('/')) seg.length = 0; for (const s of rs.split('/')) { if (!s || s === '.') continue; if (s === '..') { seg.pop(); continue; } seg.push(s); } } return '/' + seg.join('/'); } export function isAbsolute(p) { return String(p).startsWith('/'); } export function relative(from, to) { const a = resolve(from).split('/').filter(Boolean); const b = resolve(to).split('/').filter(Boolean); let i = 0; while (i < a.length && i < b.length && a[i] === b[i]) i++; return [ ...Array(a.length - i).fill('..'), ...b.slice(i) ].join('/'); } export function normalize(p) { return resolve(p); } export function toNamespacedPath(p) { return p; } export function cwd() { return '/'; } export function parse(p) { const s = String(p); const li = s.lastIndexOf('/'); const root = s.startsWith('/') ? '/' : ''; const dir = li < 0 ? '.' : (li === 0 ? root : s.slice(0, li)); const base = li < 0 ? s : s.slice(li + 1); const dot = base.lastIndexOf('.'); return { root, dir, base, ext: dot <= 0 ? '' : base.slice(dot), name: dot <= 0 ? base : base.slice(0, dot) }; } export default { sep, dirname, basename, extname, join, resolve, isAbsolute, relative, normalize, toNamespacedPath, cwd, parse }",
    "node:module": "export function createRequire() { return (spec) => ({ name: 'embedded', version: '0.0.0-embedded' }); }",
    "node:url": "export function fileURLToPath(u) { const s = String(u && u.href !== undefined ? u.href : u); return s.startsWith('file://') ? s.slice(7) : s; } export function pathToFileURL(p) { return { href: 'file://' + p, toString() { return 'file://' + p; } }; } export const URL = globalThis.URL; export const URLSearchParams = globalThis.URLSearchParams;",
    "node:util": "export function parseEnv() { return {}; } export function inspect(v) { return String(v); } export function TextDecoder(v) { const d = globalThis.TextDecoder; if (d) return new d(v); return { decode: (x) => new String(x) }; } export function TextEncoder() { const e = globalThis.TextEncoder; if (e) return new e(); return { encode: (s) => s }; } export function format(f, ...a) { let i = 0; return String(f).replace(/%[sdj]/g, (m) => (i < a.length ? String(a[i++]) : m)); } export function isDeepStrictEqual(a, b) { return JSON.stringify(a) === JSON.stringify(b); } export function promisify(fn) { return (...args) => { return new Promise((res, rej) => { try { const r = fn(...args, (e, v) => e ? rej(e) : res(v)); if (r && typeof r.then === 'function') r.then(res, rej); } catch (e) { rej(e) } }); }; } export default { parseEnv, inspect, TextDecoder, TextEncoder, format, isDeepStrictEqual, promisify };",
    "node:sqlite": "export const constants = {}; export class DatabaseSync { constructor(path, opts) { this._id = globalThis.dshServices.sqlite.open(String(path)); } exec(sql) { return globalThis.dshServices.sqlite.exec(this._id, sql); } prepare(sql) { const id = this._id; const stmt = { run(...args) { const p = args.length && Array.isArray(args[0]) ? args[0] : args; return { changes: globalThis.dshServices.sqlite.run(id, sql, p) }; }, all(...args) { const p = args.length && Array.isArray(args[0]) ? args[0] : args; return globalThis.dshServices.sqlite.all(id, sql, p); }, get(...args) { const rows = this.all(...args); return rows.length ? rows[0] : undefined; } }; return stmt; } close() { if (this._id) { globalThis.dshServices.sqlite.close(this._id); this._id = 0; } } }",
    "node:async_hooks": "export class AsyncLocalStorage { constructor() { this._store = undefined; } run(store, cb) { const prev = this._store; this._store = store; try { return cb(); } finally { this._store = prev; } } getStore() { return this._store; } enterWith(store) { this._store = store; } disable() { this._store = undefined; } }",
    "node:util/types": "export function isPromise(v) { return typeof v === \'object\' && v !== null && typeof v.then === \'function\'; }",
    "node:child_process": "export function execSync(cmd, opts) { const r = globalThis.dshServices && globalThis.dshServices.proc ? globalThis.dshServices.proc.exec(cmd) : null; return (r && r.out !== undefined) ? r.out : '\\n'; } export function spawnSync(cmd, args, opts) { try { const r = globalThis.dshServices.proc.run(cmd, args || [], opts || {}); return { status: r.code, stdout: r.out, stderr: r.err }; } catch (e) { return { error: e } } }",
    "node:perf_hooks": "export const performance = globalThis.performance || { now: () => Date.now() };",
    "node:stream": "export class Readable { constructor(opts) { this._opts = opts || {} } on() { return this } pipe() { return this } [Symbol.asyncIterator]() { let done = false; return { next() { if (done) return Promise.resolve({ done: true }); done = true; return Promise.resolve({ done: false, value: Buffer.alloc(0) }); }, [Symbol.asyncIterator]() { return this; } }; } } export class Writable { on() { return this } write(cb) { return true } end(cb) { if (typeof cb === 'function') cb(); } } export class Duplex extends Readable {} export class Transform extends Readable {} export default { Readable, Writable, Duplex, Transform }",
    "node:vm": "export function runInThisContext(code, opts) { return (0, eval)(code); } export function createContext() { return {} } export function runInContext(code) { return (0, eval)(code); }",
    "node:worker_threads": "export class Worker { constructor() { throw new Error('dsh: worker_threads not supported') } } export function isMainThread() { return true }",
    "node:zlib": "export function gzipSync(input) { return Buffer.from(String(input)); } export function gunzipSync(input) { return Buffer.from(String(input)); } export function deflateSync(input) { return Buffer.from(String(input)); } export const constants = { Z_OK: 0, Z_BEST_SPEED: 1, Z_BEST_COMPRESSION: 9 }; export function createZstdDecompress() { return { on() { return this }, resume() { return this } }; } export function createGunzip() { return { on() { return this }, resume() { return this } }; } export function zstdCompress(){ return Buffer.from(''); } export function zstdDecompress(){ return Buffer.from(''); } export function zstdCompressSync(){ return Buffer.from(''); } export function zstdDecompressSync(){ return Buffer.from(''); }",
    "node:querystring": "export function escape(s) { return encodeURIComponent(s); } export function unescape(s) { return decodeURIComponent(s); } export function stringify(o) { return Object.entries(o || {}).map(([k, v]) => encodeURIComponent(k) + '=' + encodeURIComponent(v)).join('&'); } export function parse(s) { const o = {}; for (const kv of String(s || '').split('&')) { const [k, v] = kv.split('='); if (k) o[decodeURIComponent(k)] = decodeURIComponent(v || ''); } return o; }",
    "node:string_decoder": "export class StringDecoder { constructor(enc) { this.enc = enc || 'utf8' } write(buf) { return new TextDecoder(this.enc).decode(buf) } end() { return '' } }",
    "node:events": "export class EventEmitter { constructor() { this._l = new Map() } on(t, f) { const a = this._l.get(t) || []; a.push(f); this._l.set(t, a); return this } once(t, f) { const g = (...x) => { this.off(t, g); f(...x) }; return this.on(t, g) } off(t, f) { const a = this._l.get(t) || []; this._l.set(t, a.filter((x) => x !== f)); return this } emit(t, ...x) { for (const f of [...(this._l.get(t) || [])]) f(...x); return this } } export default { EventEmitter }",
    "node:assert": "export function ok(v, m) { if (!v) throw new Error(m || 'assertion failed') } export function equal(a, b, m) { if (a !== b) throw new Error(m || 'not equal') } export function deepEqual(a, b, m) { if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(m || 'not deep equal') }",
    "node:constants": "export default { F_OK: 0, R_OK: 4, W_OK: 2, X_OK: 1 };",
    "node:process": "export const versions = { node: '0.0.0-embedded', dsh: '0.0.0-zig' }; export const platform = 'linux'; export const env = {}; export function cwd() { return '/'; }",
    "node:timers": "export const setTimeout = globalThis.setTimeout; export const clearTimeout = globalThis.clearTimeout; export const setInterval = globalThis.setInterval; export const clearInterval = globalThis.clearInterval;",
    "node:timers/promises": "export function setTimeout(ms, value, opts) { return new Promise((res) => globalThis.setTimeout(() => res(value), ms)); } export function setImmediate(value) { return new Promise((res) => globalThis.setTimeout(() => res(value), 0)); } export function scheduler() { return { wait: (ms, v) => new Promise((res) => globalThis.setTimeout(() => res(v), ms)) }; }",
    "node:assert": "export default function assert(c) { if (!c) throw new Error('assertion failed'); }",
    "node:events": "export class EventEmitter { constructor() { this.handlers = {}; } on(n, f) { (this.handlers[n] ??= []).push(f); return this; } emit(n, ...a) { for (const f of this.handlers[n] ?? []) f(...a); return true; } } export default { EventEmitter }",
}

# Keep the API shim outside this large generator literal so it can be tested directly.
SHIM_OVERRIDES["@opentelemetry/api"] = open(os.path.join(os.path.dirname(__file__), "otel-api-shim.js"), encoding="utf-8").read()
SHIM_OVERRIDES["@opentelemetry/sdk-logs"] = open(os.path.join(os.path.dirname(__file__), "otel-sdk-logs-shim.js"), encoding="utf-8").read()
SHIM_OVERRIDES["@opentelemetry/resources"] = open(os.path.join(os.path.dirname(__file__), "otel-resources-shim.js"), encoding="utf-8").read()
SHIM_OVERRIDES["turndown"] = open(os.path.join(os.path.dirname(__file__), "turndown-shim.js"), encoding="utf-8").read()
SHIM_OVERRIDES["@joplin/turndown-plugin-gfm"] = open(os.path.join(os.path.dirname(__file__), "turndown-gfm-shim.js"), encoding="utf-8").read()
SHIM_OVERRIDES["yaml"] = open(os.path.join(os.path.dirname(__file__), "yaml-shim.js"), encoding="utf-8").read()
# js-yaml is consumed only for the entry-list dialect; reuse the small parser with its compatibility surface.
SHIM_OVERRIDES["js-yaml"] = open(os.path.join(os.path.dirname(__file__), "yaml-shim.js"), encoding="utf-8").read()

def pkg_dir(pkg: str) -> str:
    # app-esm 宿主化 override（测试/仿制包——如 dsh-cjs-samp——不依赖 DSH 安装）
    esm = os.path.join(ROOT, "src", "app-esm", pkg)
    if os.path.isdir(esm):
        return esm
    return os.path.join(NM, pkg)


def pkg_json_path(pkg: str) -> str:
    """Prefer an app-esm metadata override, then fall back to installed metadata."""
    override = os.path.join(ROOT, "src", "app-esm", pkg, "package.json")
    return override if os.path.exists(override) else os.path.join(NM, pkg, "package.json")


def extract_imports(src: str):
    deps = set()
    for m in re.finditer(r'(?:from\s+|import\s*\()[\'"]([^\'"]+)[\'"]', src):
        s = m.group(1)
        if s.startswith("./") or s.startswith("../"):
            continue
        deps.add(s)
    return deps


def copy_pkg_with_bridge(pkg: str) -> list[str]:
    """exports-场包（diff 形）：拷贝主目录 + 生成 <pkg>/index.js re-export 桥（构建期静态）。"""
    rel = pkg_main(pkg)
    rel_clean = rel.lstrip("./") if rel else None
    if rel_clean is None or rel_clean.startswith("lib/"):
        return copy_pkg(pkg)
    if rel_clean.startswith("libesm/") or "/" in rel_clean:
        pass  # exports 场（diff 形）走桥
    else:
        return copy_pkg(pkg)
    main_rel_path = rel_clean
    base = pkg_dir(pkg)
    main_abs = os.path.join(base, main_rel_path)
    if not os.path.exists(main_abs):
        return copy_pkg(pkg)
    dir_base = os.path.dirname(main_abs)
    rel_to_pkg = os.path.relpath(dir_base, base)
    dest_base = os.path.join(APP, pkg, rel_to_pkg)
    names = []
    for root, _dirs, files in os.walk(dir_base):
        for relf in sorted(files):
            if not (relf.endswith(".js") or relf.endswith(".mjs") or relf.endswith(".cjs") or relf.endswith(".json")):
                continue
            src_file = os.path.join(root, relf)
            rel_dir = os.path.relpath(root, dir_base)
            dst_file = os.path.join(dest_base, rel_dir, relf)
            os.makedirs(os.path.dirname(dst_file), exist_ok=True)
            data = open(src_file, 'rb').read().decode('utf-8', errors='replace')
            open(dst_file, 'w', encoding='utf-8').write(maybe_transform(data, pkg))
            rel_key = os.path.normpath(os.path.join(rel_to_pkg, rel_dir, relf))
            names.append(f"{pkg}/{rel_key}")
    # providers 数据 json 强制清单（pi-ai 的 dist/providers/data——walk 未达面（排查中——显式补）
    data_dir2 = os.path.join(base, "dist", "providers", "data")
    if os.path.isdir(data_dir2):
        for relf in sorted(os.listdir(data_dir2)):
            if not relf.endswith(".json"):
                continue
            srcf2 = os.path.join(data_dir2, relf)
            dstf2 = os.path.join(APP, pkg, "dist", "providers", "data", relf)
            os.makedirs(os.path.dirname(dstf2), exist_ok=True)
            if os.path.abspath(srcf2) != os.path.abspath(dstf2):
                shutil.copyfile(srcf2, dstf2)
            names.append(f"{pkg}/dist/providers/data/{relf}")
    bridge_src = f"import * as __dshNs from './{main_rel_path}'; export default __dshNs; export * from './{main_rel_path}';"
    bridge_path = os.path.join(APP, pkg, "index.js")
    with open(bridge_path, "w") as f:
        f.write(bridge_src)
    names.append(f"{pkg}/index.js")
    # exports 场：包根 package.json（`import x from "pkg/package.json"`——JSON 模块面）
    pj_src2 = pkg_json_path(pkg)
    pj_dst2 = os.path.join(APP, pkg, "package.json")
    if os.path.exists(pj_src2) and os.path.abspath(pj_src2) != os.path.abspath(pj_dst2):
        shutil.copyfile(pj_src2, pj_dst2)
    if os.path.exists(pj_dst2):
        names.append(f"{pkg}/package.json")
    return names


def copy_pkg(pkg: str) -> list[str]:
    """拷贝包内 lib/*.js/.mjs（zmorph: 包根 flat）-> app-esm/<pkg>/...；返回模块名列表。"""
    lib = os.path.join(pkg_dir(pkg), "lib")
    flat = not os.path.isdir(lib)
    base = os.path.join(pkg_dir(pkg), "lib") if not flat else pkg_dir(pkg)
    if flat:
        # flat 包可能带 dist/（diff 形）
        dist = os.path.join(pkg_dir(pkg), "dist")
        if os.path.isdir(dist) and not os.path.exists(os.path.join(base, "index.js")):
            base = dist
        if not (os.path.exists(os.path.join(base, "index.js")) or os.path.exists(os.path.join(base, "index.mjs")) or os.path.exists(os.path.join(base, "index.cjs"))):
            raise SystemExit(f"missing package entry for flat pkg {pkg}")
    dest = os.path.join(APP, pkg, "lib") if not flat else os.path.join(APP, pkg)
    os.makedirs(dest, exist_ok=True)
    names = []
    if flat:
        # flat 包（zod 形）：递归拷全 .js/.mjs/.json（相对子模块 './v4/...'）
        for root, _dirs, files in os.walk(base):
            for rel in sorted(files):
                if not (rel.endswith(".js") or rel.endswith(".mjs") or rel.endswith(".cjs") or rel.endswith(".json")) or rel.endswith(".d.ts"):
                    continue
                src_file = os.path.join(root, rel)
                rel_dir = os.path.relpath(root, base)
                dst_file = os.path.join(dest, rel_dir, rel)
                if os.path.abspath(src_file) != os.path.abspath(dst_file):
                    os.makedirs(os.path.dirname(dst_file), exist_ok=True)
                    shutil.copyfile(src_file, dst_file)
                names.append(f"{pkg}/{os.path.relpath(dst_file, dest)}")
    else:
        for root, _dirs, files in os.walk(lib):
            for rel in sorted(files):
                if not (rel.endswith(".js") or rel.endswith(".mjs") or rel.endswith(".cjs") or rel.endswith(".json")) or rel.endswith(".d.ts"):
                    continue
                src_file = os.path.join(root, rel)
                rel_dir = os.path.relpath(root, lib)
                dst_file = os.path.join(dest, rel_dir, rel)
                if os.path.abspath(src_file) != os.path.abspath(dst_file):
                    os.makedirs(os.path.dirname(dst_file), exist_ok=True)
                    shutil.copyfile(src_file, dst_file)
                names.append(f"{pkg}/lib/{os.path.join(rel_dir, rel) if rel_dir != '.' else rel}")
    if not any(n.endswith("index.js") or n.endswith("index.mjs") or n.endswith("index.cjs") for n in names):
        print(f"[skipcopy] {pkg}: index.js|mjs missing")
        return []
    # 包根 package.json（JSON 模块面——`import x from "pkg/package.json"`）
    pj_src = pkg_json_path(pkg)
    pj_dst = os.path.join(dest, "package.json")
    if os.path.exists(pj_src) and os.path.abspath(pj_src) != os.path.abspath(pj_dst):
        os.makedirs(dest, exist_ok=True)
        shutil.copyfile(pj_src, pj_dst)
    if os.path.exists(pj_dst):
        names.append(f"{pkg}/lib/package.json" if not flat else f"{pkg}/package.json")
    return names


NODE_IMPORTS = set(["node:timers", "node:events", "node:assert", "node:process", "node:querystring", "node:string_decoder", "node:constants"])


def collect_node_imports():
    global NODE_IMPORTS
    return NODE_IMPORTS


def _scan_node(dep):
    if dep.startswith("node:"):
        NODE_IMPORTS.add(dep)


def pkg_main(pkg: str):
    """package.json 主文件解析：exports['.'].import.default（ESM 场）> module > main。"""
    import json as _json
    pj_path = pkg_json_path(pkg)
    if not os.path.exists(pj_path):
        return None
    try:
        pj = _json.load(open(pj_path))
    except Exception:
        return None
    rel = None
    exp = pj.get("exports")
    if isinstance(exp, dict):
        dot = exp.get(".")
        if isinstance(dot, dict):
            imp = dot.get("import")
            if isinstance(imp, dict):
                imp = imp.get("default")
            if isinstance(imp, str):
                rel = imp
            if rel is None:
                req = dot.get("require")
                if isinstance(req, dict):
                    req = req.get("default")
                if isinstance(req, str):
                    rel = req
            if rel is None and isinstance(dot.get("default"), str):
                rel = dot["default"]
    if rel is None and isinstance(pj.get("module"), str):
        rel = pj["module"]
    if rel is None and isinstance(pj.get("main"), str):
        rel = pj["main"]
    return rel


def build_closure():
    seeds = []
    for arg in sys.argv[1:]:
        if arg.startswith("--seed="):
            seeds.append(arg[len("--seed="):])
    # 启动集 = app-esm/@deepseek-ai 现有目录（宿主化自洽——目录即清单）+ BASE_MODULES
    esm_dir = os.path.join(ROOT, "src", "app-esm", "@deepseek-ai")
    host_pkgs = []
    if os.path.isdir(esm_dir):
        host_pkgs = [f"@deepseek-ai/{n}" for n in sorted(os.listdir(esm_dir))]
    pkgs = dict.fromkeys(host_pkgs + list(BASE_MODULES) + list(THIRD_PARTY_SEEDS) + seeds)  # 保序
    for s in seeds:
        pkgs[s] = None
    queue = list(pkgs.keys())
    while queue:
        pkg = queue.pop(0)
        if pkg not in pkgs:
            continue
        if len(pkgs) > MAX_PACKAGES:
            raise SystemExit(f"closure overflow at {pkg} (> {MAX_PACKAGES})")
        main = os.path.join(pkg_dir(pkg), "lib", "index.js")
        if not os.path.exists(main):
            main = os.path.join(pkg_dir(pkg), "lib", "index.mjs")
        if not os.path.exists(main):
            main = os.path.join(pkg_dir(pkg), "index.js")  # flat 包
        if not os.path.exists(main):
            main = os.path.join(pkg_dir(pkg), "dist", "index.js")  # dist 包
        if not os.path.exists(main):
            main = os.path.join(pkg_dir(pkg), "dist", "index.mjs")
        if not os.path.exists(main):
            main_rel = pkg_main(pkg)
            if main_rel:
                main = os.path.join(pkg_dir(pkg), main_rel.lstrip("./"))
        if not os.path.exists(main):
            print(f"[skip] {pkg}: no package entry")
            continue
        src = open(main, encoding="utf-8-sig", errors="replace").read()
        for dep in sorted(extract_imports(src)):
            if dep.startswith("node:"):
                NODE_IMPORTS.add(dep)
            if dep.startswith("@"):
                if dep not in pkgs:
                    pkgs[dep] = None
                    queue.append(dep)
            else:
                if dep in EXCLUDE:
                    continue
                # 第三方（js-yaml/diff 等）：exports 场解析（pkg_main）+ 常规探测
                third = pkg_dir(dep)  # app-esm override 优先（stub/仿制——如 diff）；否则 NM
                third_main = os.path.join(third, "index.js")
                third_lib = os.path.join(third, "lib", "index.js")
                main_rel = pkg_main(dep)
                main_abs = os.path.join(third, main_rel.lstrip("./")) if main_rel else ""
                if os.path.exists(third_main) or os.path.exists(third_lib) or (main_abs and os.path.exists(main_abs)):
                    if dep not in pkgs:
                        pkgs[dep] = None
                        queue.append(dep)
                else:
                    print(f"[warn] third-party dep not found: {dep} (needed by {pkg})")
    return [p for p in pkgs
            if os.path.exists(os.path.join(pkg_dir(p), "lib", "index.js"))
            or os.path.exists(os.path.join(pkg_dir(p), "lib", "index.mjs"))
            or os.path.exists(os.path.join(pkg_dir(p), "index.js"))
            or os.path.exists(os.path.join(pkg_dir(p), "dist", "index.js"))
            or os.path.exists(os.path.join(pkg_dir(p), "dist", "index.mjs"))
            or (pkg_main(p) is not None and os.path.exists(os.path.join(pkg_dir(p), pkg_main(p).lstrip("./"))))]  # exports 主（diff 形）


def bootstrap_modules():
    """手放入口目录（src/app-esm/bootstrap/）——自动入表（如启动 entry）。"""
    bs = os.path.join(APP, "bootstrap")
    if not os.path.isdir(bs):
        return []
    return sorted(f"bootstrap/{name}" for name in os.listdir(bs))


def split_top_commas(s: str):
    """顶层逗号拆分（括号/字符串/模板感知）"""
    parts, depth, cur = [], 0, ''
    i, n = 0, len(s)
    while i < n:
        ch = s[i]
        if ch in '([{':
            depth += 1
        elif ch in ')]}':
            depth -= 1
        elif ch in '\"' and (i == 0 or s[i-1] != '\\'):
            # 跳过字符串
            j = i + 1
            while j < n:
                if s[j] == '\\':
                    j += 2
                    continue
                if s[j] == '"':
                    break
                j += 1
            cur += s[i:j+1]
            i = j + 1
            continue
        elif ch == ',' and depth == 0:
            parts.append(cur)
            cur = ''
            i += 1
            continue
        cur += ch
        i += 1
    parts.append(cur)
    return parts


def split_declarations(src: str):
    """引擎复合声明 bug 绕行：const/let 单行多变量声明拆成多行（[uninitialized] 家族）。
    只处理顶层逗号（括号/字符串感知）——构建期文本变换，语义不变。"""
    out = []
    for ln in src.split('\n'):
        m = re.match(r'^(\s*)(const|let|var)\s+(.+?)\s*;?\s*$', ln)
        if m and ',' in m.group(3):
            parts = split_top_commas(m.group(3))
            if len(parts) > 1 and all(p.strip() for p in parts):
                indent, kw = m.group(1), m.group(2)
                out.append(indent + kw + ' ' + parts[0].strip() + ';')
                for p in parts[1:]:
                    out.append(indent + kw + ' ' + p.strip() + ';')
                continue
        out.append(ln)
    return '\n'.join(out)


TRANSFORM_PREFIXES = ('node_modules/',)  # 预留
APPLY_TRANSFORM = True


def maybe_transform(src_text: str, pkg: str) -> str:
    # 只对第三方（非 @deepseek-ai）与 bootstrap 应用（DSH 打包产物已 OK）
    if APPLY_TRANSFORM and (not pkg.startswith('@') or pkg.startswith('diff')):
        return split_declarations(src_text)
    return src_text


def main():
    pkgs = build_closure()
    # shim 覆盖：写 app-esm/<pkg>/index.js，并把名字从闭包列表角度跳过真实包体
    for name, code in SHIM_OVERRIDES.items():
        dest = os.path.join(APP, name)
        os.makedirs(dest, exist_ok=True)
        with open(os.path.join(dest, "index.js"), "w") as f:
            f.write(code)
    modules = []
    for pkg in pkgs:
        if pkg in SHIM_OVERRIDES:
            modules.append(f"{pkg}/index.js")
            continue
        modules.extend(copy_pkg_with_bridge(pkg))
    modules.extend(bootstrap_modules())
    modules = sorted(set(modules))

    lines = [
        "//! 由 tools/gen-app-esm.py 生成 —— 请勿手改。",
        "//! 真实插件闭包的内嵌模块表（@embedFile 形态；M-2/M-5 模块链接器消费）。",
        "//! 模块名 = canonical file path（'<pkg>/index.js'、'<pkg>/lib/xxx.js'），",
        "//! 相对导入由此推导 dirname。",
        "pub const Module = struct {",
        "    name: []const u8,",
        "    src: []const u8,",
        "};",
        "",
        "pub const modules = [_]Module{",
    ]
    for mod in modules:
        rel = os.path.join(APP, mod)
        if not os.path.exists(rel):
            raise SystemExit(f"missing {rel}")
        lines.append(f'    .{{ .name = "{mod}", .src = @embedFile("app-esm/{mod}") }},')
    lines.append("};")
    open(OUT, "w").write("\n".join(lines) + "\n")
    write_stubs()
    print(f"wrote {OUT} ({len(modules)} modules from {len(pkgs)} packages)")


def stub_file(name: str) -> str:
    """node:fs/promises -> n-fs_promises（文件系统安全形态）"""
    return name.replace("node:", "n-").replace("/", "_")


def write_stubs():
    unknown = [n for n in sorted(NODE_IMPORTS) if n not in STUBS]
    if unknown:
        raise SystemExit(f"builtin stubs missing: {unknown}")
    names = sorted(NODE_IMPORTS)
    lines = [
        "//! 由 tools/gen-app-esm.py 生成 —— 请勿手改。（M-5 builtin 面）",
        "//! 闭包依赖扫描出的 node: 模块 -> stub 源码（真实绑定在 M-3 服务层）。",
        "pub const Builtin = struct { name: []const u8, src: []const u8 };",
        "",
        "pub const builtins = [_]Builtin{",
    ]
    for name in names:
        lines.append(f'    .{{ .name = "{name}", .src = @embedFile("builtin-stubs/{stub_file(name)}") }},')
    lines.append("};")
    stub_out = os.path.join(ROOT, "src", "builtin_stubs.zig")
    open(stub_out, "w").write("\n".join(lines) + "\n")
    stub_dir = os.path.join(ROOT, "src", "builtin-stubs")
    os.makedirs(stub_dir, exist_ok=True)
    for name in names:
        with open(os.path.join(stub_dir, stub_file(name)), "w") as f:
            f.write(STUBS[name])
    print(f"wrote {stub_out} ({len(names)} builtins)")


if __name__ == "__main__":
    main()
