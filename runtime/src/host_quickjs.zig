//! QuickjsHost —— 「HostModuleLoader」契约（seam.zig）的 quickjs-ng 后端。
//! 职责：持有 engine 上下文；resolve（表+package-main）/ evaluate（引擎模块编译）/
//!       释放；并注册引擎级 loader+normalizer，使模块图依赖经同一套解析。
//! 注意：本文件依赖引擎 C 源，测试须走 `zig build test-quickjs`（链接 quickjs.c）。

const std = @import("std");
const seam = @import("seam.zig");
const app = @import("app_modules.zig");
const package_exports = @import("package_exports.zig");

pub const c = @import("engine_c.zig").c;

pub const Error = error{ NewRuntimeFailed, NewContextFailed, ResolveFailed, CompileFailed, RunFailed, NamespaceMissing };

/// quickjs 背书的 HostModuleLoader 实现。
pub const QuickjsHost = struct {
    rt: *c.JSRuntime,
    ctx: *c.JSContext,
    import_helper: c.JSValue,
    web_globals_tag: i32 = -99,

    /// import() 产出的显式句柄：seam.ModuleNamespace 为 `*anyopaque`，
    /// JSValue 是 16 字节结构（union+tag），不能直接塞指针——句柄保存在
    /// 宿主侧，dispose 时读回值并 JS_FreeValue（§6.2 规则 1 配对）。
    pub const NamespaceHandle = struct {
        value: c.JSValue,
    };

    pub fn init() Error!QuickjsHost {
        const rt = c.JS_NewRuntime() orelse return error.NewRuntimeFailed;
        _ = c.JS_SetDumpFlags(rt, c.JS_DUMP_LEAKS | c.JS_DUMP_ATOM_LEAKS);
        // M-4 安全边界（不受信代码——code-runtime/workflow/动态插件面）：JS 堆内存上限。
        // 256MB（boot 全链峰值 RSS ~60MB/goJS 堆远低——上限仅挡异常分配；interrupt 由
        // 调用方按预算设 handler——见 boot_smoke 的 jsInterruptCb 自测）。
        // Public guest heap budget; RSS is kept below it by the module-graph GC policy.
        _ = c.JS_SetMemoryLimit(rt, 256 * 1024 * 1024);
        // Collect earlier during the large module graph bootstrap to cap transient heap.
        c.JS_SetGCThreshold(rt, 64 * 1024 * 1024);
        const ctx = c.JS_NewContext(rt) orelse {
            c.JS_FreeRuntime(rt);
            return error.NewContextFailed;
        };
        var host = QuickjsHost{ .rt = rt, .ctx = ctx, .import_helper = jsUndefConst() };
        host.installEngineLoader();
        // 首个 JS_Eval 必须发生在模块系统活动之前（引擎实测：之后的
        // 任何 JS_Eval 解析都报 invalid UTF-8）—— 辅助脚本预编译为函数，
        // import() 只 JS_Call（零解析）。
        // Web 全局引导（字面量；init 期 eval——模块系统活动前的安全窗）
        // Web 全局引导（字面量；init 期 eval——模块系统活动前的安全窗）。
        // 兼容补丁（quickjs 原生函数 toString 多行格式 vs V8 单行——dsh-session 的
        // hasIntrinsicConstructor 精确匹配单行 → 不归一则 snapshot 恒 undefined（定案））：
        // 全局 performance 桩（__perfNow 宿主单调时钟；Web/Node 通用）
        {
            const g0 = c.JS_GetGlobalObject(ctx);
            defer c.JS_FreeValue(ctx, g0);
            _ = c.JS_SetPropertyStr(ctx, g0, "__perfNow", c.JS_NewCFunction(ctx, jsPerfNow, "__perfNow", 0));
        }
        {
            // CJS require 同步面（换装 header 的 require → 工厂 eval 链）
            const g1 = c.JS_GetGlobalObject(ctx);
            defer c.JS_FreeValue(ctx, g1);
            _ = c.JS_SetPropertyStr(ctx, g1, "__dshRequireSync", c.JS_NewCFunction(ctx, jsRequireSync, "__dshRequireSync", 2));
            // CJS cache lives in the context so require() shares identity and cycles.
            _ = c.JS_SetPropertyStr(ctx, g1, "__dshCjsCache", c.JS_NewObject(ctx));
        }
        const web_globals = "const __origT = Function.prototype.toString; Function.prototype.toString = function () { const s = __origT.call(this); if (s.indexOf('[native code]') < 0) return s; return 'function ' + this.name + '() { [native code] }'; }; globalThis.TextEncoder = class { encode(s) { const t = String(s); const b = new Uint8Array(t.length); for (let i = 0; i < t.length; i++) { const c = t.charCodeAt(i); b[i] = c < 256 ? c : 63; } return b; } }; globalThis.TextDecoder = class { decode(u8) { let out = ''; if (u8 === undefined) return out; for (const x of u8) out += String.fromCharCode(x); return out; } }; globalThis.Buffer = class { static byteLength(s, enc) { return typeof s === 'string' ? new TextEncoder().encode(s).length : (s && s.length ? s.length : 0); } static from(x) { if (typeof x === 'string') return new TextEncoder().encode(x); return new Uint8Array(x); } static alloc(n) { return new Uint8Array(n); } static allocUnsafe(n) { return new Uint8Array(n); } static isBuffer(v) { return v instanceof Uint8Array; } static concat(list, n) { const out = new Uint8Array(n != null ? n : list.reduce((a, c) => a + c.length, 0)); let o = 0; for (const c of list) { out.set(c, o); o += c.length; } return out; } }; globalThis.URL = class { constructor(v, base) { let s = String(v); if (base && s.indexOf('://') < 0) s = String(base).replace(/[^/]*$/, '') + s; this.href = s; let rest = s, proto = ''; const pidx = s.indexOf('://'); if (pidx >= 0) { proto = s.slice(0, pidx + 1); rest = s.slice(pidx + 3); } let hEnd = rest.length; for (const chh of ['/', '?', '#']) { const ii = rest.indexOf(chh); if (ii >= 0 && ii < hEnd) hEnd = ii; } const hostReal = rest.slice(0, hEnd); this.protocol = proto; this.host = hostReal; const cp = hostReal.includes(':') ? hostReal.split(':') : [hostReal, '']; this.hostname = cp[0]; this.port = cp[1] || ''; const tail = rest.slice(hostReal.length); const qI = tail.indexOf('?'); const hI = tail.indexOf('#'); this.pathname = qI >= 0 ? tail.slice(0, qI) : (hI >= 0 ? tail.slice(0, hI) : tail); if (this.pathname === '') this.pathname = '/'; this.search = qI >= 0 ? tail.slice(qI, hI >= 0 && hI > qI ? hI : tail.length) : ''; this.hash = hI >= 0 ? tail.slice(hI) : ''; this.origin = proto + hostReal; } toString() { return this.href } }; globalThis.ReadableStream = class { constructor(under) { this._under = under || {} } getReader() { const u = this._under; let done = false; return { read() { if (done) return Promise.resolve({ done: true }); done = true; if (u.start) { let r; u.start((c) => { r = c }); if (r !== undefined) return Promise.resolve({ done: false, value: r }); } return Promise.resolve({ done: false, value: undefined }); }, cancel() { return Promise.resolve() } }; } pipeThrough(t) { return t.readable ? t.readable : this } }; globalThis.TransformStream = class { constructor(transformer) { this._tr = transformer || {}; this.readable = new globalThis.ReadableStream({ start: (c) => { this._c = c } }); this.writable = { getWriter() { return { write: (chunk) => { if (this._tr && this._tr.transform) this._tr.transform(chunk, this._c); return Promise.resolve() }, close: () => { if (this._tr && this._tr.flush) this._tr.flush(this._c); return Promise.resolve() }, abort: () => Promise.resolve() } } }; } }; globalThis.TextDecoderStream = class { constructor() { this.readable = new globalThis.ReadableStream({ start: (c) => { this._c = c } }); this.writable = { getWriter() { return { write: (chunk) => { this._c.enqueue(''); return Promise.resolve() }, close: () => Promise.resolve(), abort: () => Promise.resolve() } } }; } }; globalThis.URLSearchParams = class { constructor(init) { this._m = new Map(); if (typeof init === 'string') { for (const kv of init.split('&')) { const [k, v] = kv.split('='); if (k) this._m.set(decodeURIComponent(k), decodeURIComponent(v || '')); } } } get(k) { return this._m.get(k) ?? null } set(k, v) { this._m.set(k, String(v)) } append(k, v) { this._m.set(k, String(v)) } toString() { return [...this._m].map(([k, v]) => encodeURIComponent(k) + '=' + encodeURIComponent(v)).join('&') } }; globalThis.structuredClone = (v) => JSON.parse(JSON.stringify(v)); globalThis.AbortController = class { constructor() { this.signal = { aborted: false, listeners: [], addEventListener(t, f) { this.listeners.push(f); }, throwIfAborted() { if (this.aborted) throw new Error('Aborted'); } }; } abort(reason) { if (this.signal.aborted) return; this.signal.aborted = true; this.signal.reason = reason; for (const f of [...this.signal.listeners]) { try { f({ type: 'abort' }) } catch (e) {} } } }; globalThis.AbortSignal = class { static timeout() { return new AbortController().signal; } static abort() { return { aborted: true, listeners: [], addEventListener() {}, throwIfAborted() { throw new Error('Aborted'); } }; } static any(list) { const s = { aborted: false, listeners: [], addEventListener(t, f) { this.listeners.push(f); }, throwIfAborted() { if (this.aborted) throw new Error('Aborted'); } }; const check = (sig) => { if (sig && sig.aborted && !s.aborted) { s.aborted = true; for (const f of [...s.listeners]) { try { f({ type: 'abort' }) } catch (e) {} } } }; for (const sig of list) { check(sig); if (sig && sig.listeners && typeof sig.listeners.push === 'function') sig.listeners.push(() => check(sig)); } return s; } }; globalThis.btoa = function (s) { const t = String(s); const tab = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'; let out = ''; for (let i = 0; i < t.length; i += 3) { const a = t.charCodeAt(i); const b = t.charCodeAt(i + 1); const c = t.charCodeAt(i + 2); out += tab[a >> 2] + tab[((a & 3) << 4) | (isNaN(b) ? 0 : b >> 4)] + (isNaN(b) ? '=' : tab[((b & 15) << 2) | (isNaN(c) ? 0 : c >> 6)]) + (isNaN(c) ? '=' : tab[c & 63]); } return out; }; globalThis.atob = function (s) { const tab = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'; const t = String(s).replace(/[^A-Za-z0-9+/=]/g, ''); let out = ''; for (let i = 0; i < t.length; i += 4) { const a = tab.indexOf(t[i]); const b = tab.indexOf(t[i + 1]); const c = tab.indexOf(t[i + 2]); const d = tab.indexOf(t[i + 3]); out += String.fromCharCode((a << 2) | (b >> 4)) + (c < 0 ? '' : String.fromCharCode(((b & 15) << 4) | (c >> 2))) + (d < 0 ? '' : String.fromCharCode(((c & 3) << 6) | d)); } return out; }; globalThis.performance = { now: () => globalThis.__perfNow(), timeOrigin: globalThis.__perfNow() }; globalThis.setTimeout = (fn, ms) => globalThis.dshServices.timer.setTimeout(fn, ms); globalThis.clearTimeout = (id) => globalThis.dshServices.timer.clearTimer(id); globalThis.setInterval = (fn, ms) => globalThis.dshServices.timer.setInterval(fn, ms); globalThis.clearInterval = (id) => globalThis.dshServices.timer.clearTimer(id); globalThis.fetch = async (url, opts) => { const u = String(url); const sp = u.indexOf('://'); const hb = sp < 0 ? -1 : u.indexOf('/', sp + 3); const port = sp < 0 || hb < 0 ? (Number.isFinite(Number(u)) ? Number(u) : 0) : Number(u.slice(sp + 3, hb).split(':')[1]); if (!port) throw new Error('fetch: unsupported url ' + u); const path = hb < 0 ? '/' : u.slice(hb); const o = opts || {}; const body = typeof o.body === 'string' ? o.body : (o.body ? JSON.stringify(o.body) : ''); const resp = globalThis.dshServices.http.post(port, path, body); return { ok: true, status: 200, text: async () => resp, json: async () => JSON.parse(resp), headers: { get: () => null } }; }; globalThis.crypto = { randomUUID: () => globalThis.dshServices.crypto.randomUUID(), subtle: { digest: (alg, data) => { const bytes = data instanceof Uint8Array ? data : new Uint8Array(data); const hex = globalThis.dshServices.crypto.sha256(new TextDecoder().decode(bytes)); const out = new Uint8Array(hex.length >> 1); for (let i = 0; i < out.length; i++) out[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16); return Promise.resolve(out.buffer); } } };";
        const wg = c.JS_Eval(ctx, web_globals.ptr, web_globals.len, "web-globals.js", c.JS_EVAL_TYPE_GLOBAL);
        if (c.JS_IsException(wg)) {
            const ex = c.JS_GetException(ctx);
            const m = c.JS_ToCStringLen(ctx, null, ex);
            if (m) |mm| std.debug.print("[quickjs-host] web-globals failed: {s}\n", .{std.mem.span(mm)});
            c.JS_FreeRuntime(rt);
            return error.NewRuntimeFailed;
        }
        c.JS_FreeValue(ctx, wg);
        const helper_src = "(spec) => import(spec).then(ns => { globalThis['__dsh_capture__'] = ns; return true; }).catch(e => { globalThis['__dsh_capture__'] = null; globalThis['__dsh_capture_err__'] = (typeof e) + ':' + (e && e.message) + ':' + String(e) + ' | ' + (e && e.stack ? e.stack : 'nostack'); throw e; })";
        const hv = c.JS_Eval(ctx, helper_src.ptr, helper_src.len, "import-helper.js", c.JS_EVAL_TYPE_GLOBAL);
        if (c.JS_IsException(hv)) {
            const ex = c.JS_GetException(ctx);
            const m = c.JS_ToCStringLen(ctx, null, ex);
            if (m) |mm| std.debug.print("[quickjs-host] helper failed: {s}\n", .{std.mem.span(mm)});
            c.JS_FreeRuntime(rt);
            return error.NewRuntimeFailed;
        }
        host.import_helper = hv;
        return host;
    }

    pub fn deinit(self: *QuickjsHost) void {
        c.JS_FreeValue(self.ctx, self.import_helper);
        c.JS_FreeContext(self.ctx);
        c.JS_FreeRuntime(self.rt);
    }

    /// seam 契约入口：import(specifier) -> ModuleNamespace。
    /// 实现：引擎内动态 `import()`（gdb 实证：C 侧构造 module 值后取 namespace
    /// 的路径在 var_refs 绑定上是坑；动态 import 是引擎自洽路径，spike 已验证），
    /// 命名空间对象经全局槽捕获并 dup 持有（dispose 配对释放）。
    pub fn import(self: *QuickjsHost, specifier: []const u8, base: seam.BaseUrl, attrs: seam.ImportAttributes) !seam.ModuleNamespace {
        _ = base;
        _ = attrs;
        const import_t0 = monoNs();
        const spec_val = c.JS_NewStringLen(self.ctx, specifier.ptr, specifier.len);
        if (c.JS_IsException(spec_val)) return error.ResolveFailed;
        const undefv = jsUndefConst();
        var spec_arg = spec_val; // 可变副本（模拟 C 的 JSValueConst* argv）
        const task = c.JS_Call(self.ctx, self.import_helper, undefv, 1, &spec_arg);
        if (c.JS_IsException(task)) {
            c.JS_FreeValue(self.ctx, spec_val);
            self.consumeException(self.ctx, "import-call");
            return error.ResolveFailed;
        }

        c.JS_FreeValue(self.ctx, task);

        // 驱动 job 队列直到 promise 落定（动态 import 经 engine 模块系统）
        var job_ctx: ?*c.JSContext = self.ctx;
        var guard: usize = 0;
        while (c.JS_ExecutePendingJob(self.rt, &job_ctx) > 0) : (guard += 1) {
            if (guard > 8192) {
                c.JS_FreeValue(self.ctx, spec_val);
                return error.ResolveFailed;
            }
        }

        if (std.c.getenv("DSH_LOAD_TRACE") != null) {
            const ims = @as(f64, @floatFromInt(monoNs() - import_t0)) / 1e6;
            const cms = @as(f64, @floatFromInt(load_compile_ns)) / 1e6;
            std.debug.print("[load:stats] import '{s}' total={d:.1}ms | compile_cum={d:.1}ms compiles={d}\n", .{ specifier, ims, cms, load_compile_count });
        }

        // spec 字符串的生命周期须覆盖 job 队列（异步 import 可能后取引用）
        c.JS_FreeValue(self.ctx, spec_val);

        const g = c.JS_GetGlobalObject(self.ctx);
        defer c.JS_FreeValue(self.ctx, g);
        const ns = c.JS_GetPropertyStr(self.ctx, g, "__dsh_capture__");
        if (c.JS_IsException(ns) or c.JS_IsUndefined(ns) or c.JS_IsNull(ns)) {
            const err_v = c.JS_GetPropertyStr(self.ctx, g, "__dsh_capture_err__");
            defer c.JS_FreeValue(self.ctx, err_v);
            if (!c.JS_IsUndefined(err_v)) {
                const m = c.JS_ToCStringLen(self.ctx, null, err_v) orelse return error.NamespaceMissing;
                defer c.JS_FreeCString(self.ctx, m);
                std.debug.print("[quickjs-host] import {s} failed: {s}\n", .{ specifier, std.mem.span(m) });
            } else {
                self.consumeException(self.ctx, "capture");
            }
            return error.NamespaceMissing;
        }
        // 所有权：ns 是 GetPropertyStr 的 dup（属性自身仍持一份）。
        // 清掉属性引用（SetPropertyStr 自动释放旧值），my dup 成为剩余唯一持有者。
        _ = c.JS_SetPropertyStr(self.ctx, g, "__dsh_capture__", jsUndefConst());
        const handle = std.heap.page_allocator.create(NamespaceHandle) catch return error.ResolveFailed;
        handle.* = .{ .value = ns };
        return @ptrCast(handle);
    }

    /// 释放 import() 产出的 namespace（QuickJS dup 计数配对）。
    pub fn dispose(self: *QuickjsHost, ns: seam.ModuleNamespace) void {
        const handle: *NamespaceHandle = @ptrCast(@alignCast(ns));
        c.JS_FreeValue(self.ctx, handle.value);
        std.heap.page_allocator.destroy(handle);
    }

    // ---- 引擎装载链 ----

    fn installEngineLoader(self: *QuickjsHost) void {
        c.JS_SetModuleLoaderFunc2(self.rt, null, engineModuleLoader, null, self);
        c.JS_SetModuleNormalizeFunc2(self.rt, engineNormalizer);
    }

    fn moduleValue(self: *QuickjsHost, m: *c.JSModuleDef) c.JSValue {
        _ = self;
        return .{ .u = .{ .ptr = m }, .tag = c.JS_TAG_MODULE };
    }

    fn looksCjs(src: []const u8) bool {
        // ESM 判定（import/export 语句——bundle 内 CJS interop 残留（exports.=…）不算 CJS）
        if (std.mem.startsWith(u8, src, "import ") or std.mem.startsWith(u8, src, "export ")) return false;
        if (std.mem.indexOf(u8, src, "\nimport ") != null or std.mem.indexOf(u8, src, "\nexport ") != null) return false;
        // Some TypeScript CJS output only uses require() and __exportStar(),
        // without a direct exports.NAME assignment.
        if (std.mem.indexOf(u8, src, "__exportStar(") != null or std.mem.indexOf(u8, src, "Object.defineProperty(exports") != null) return true;
        var i: usize = 0;
        while (std.mem.indexOfPos(u8, src, i, "module.exports") orelse std.mem.indexOfPos(u8, src, i, "exports.")) |at| {
            var line_start = at;
            while (line_start > 0 and src[line_start - 1] != '\n') line_start -= 1;
            var ls = line_start;
            while (ls < at and (src[ls] == ' ' or src[ls] == '\t')) ls += 1;
            if (ls + 1 < src.len and src[ls] == '/' and src[ls + 1] == '/') {
                i = at + 1;
                continue;
            }
            return true;
        }
        return false;
    }

    fn loadModule(self: *QuickjsHost, ctx: ?*c.JSContext, raw_name: []const u8) ?*c.JSModuleDef {
        const internal = std.mem.startsWith(u8, raw_name, INTERNAL_SPEC_PREFIX);
        const name = if (internal) raw_name[INTERNAL_SPEC_PREFIX.len..] else raw_name;
        // 解析：表直查 -> <pkg>/index.js；内部相对 import 已带标记，跳过外部 exports 封锁。
        var cand_buf: [256]u8 = undefined;
        const cand = if (std.mem.endsWith(u8, name, "/index.js"))
            name
        else
            std.fmt.bufPrint(&cand_buf, "{s}/index.js", .{name}) catch name;
        var lib_buf: [256]u8 = undefined;
        const cand2 = std.fmt.bufPrint(&lib_buf, "{s}/lib/index.js", .{name}) catch cand;
        var mjs_buf: [256]u8 = undefined;
        const cand3 = std.fmt.bufPrint(&mjs_buf, "{s}/lib/index.mjs", .{name}) catch cand;
        var dist_buf: [256]u8 = undefined;
        const cand4 = std.fmt.bufPrint(&dist_buf, "{s}/dist/index.js", .{name}) catch cand;
        var distm_buf: [256]u8 = undefined;
        const cand5 = std.fmt.bufPrint(&distm_buf, "{s}/dist/index.mjs", .{name}) catch cand;
        var ext_buf: [256]u8 = undefined;
        const cand6 = std.fmt.bufPrint(&ext_buf, "{s}.js", .{name}) catch cand;
        var extm_buf: [256]u8 = undefined;
        const cand7 = std.fmt.bufPrint(&extm_buf, "{s}.mjs", .{name}) catch cand;
        var export_buf: [768]u8 = undefined;
        const package_result: package_exports.Result = if (internal)
            .{ .declared = false, .target = null }
        else
            resolvePackageExport(name, &export_buf, true);
        const canonical_raw: []const u8 = if (std.mem.startsWith(u8, name, "node:"))
            name
        else if (package_result.declared)
            package_result.target orelse {
                std.debug.print("[loader] exports blocked or unresolved: {s}\n", .{name});
                return null;
            }
        else blk: {
            const r = normalizeBuiltin(name) orelse resolveSpec(name) orelse resolveSpec(cand) orelse resolveSpec(cand2) orelse resolveSpec(cand3) orelse resolveSpec(cand4) orelse resolveSpec(cand5) orelse resolveSpec(cand6) orelse resolveSpec(cand7) orelse resolveLibSubpath(name) orelse {
                std.debug.print("[loader] resolve failed: {s} (cands: {s} {s} {s})\n", .{ name, cand, cand2, cand3 });
                return null;
            };
            break :blk r;
        };
        var canonical_buf: [768]u8 = undefined;
        const canonical = std.fmt.bufPrintZ(&canonical_buf, "{s}", .{canonical_raw}) catch return null;
        // 以引擎查找名（规范化 specifier）注册模块：引擎模块缓存按请求名比对
        // （js_find_loaded_module），用 canonical 注册会导致缓存键恒不匹配，
        // 每条 import 边都重复编译整份模块（实测 4041 次编译 / 311 个去重名）。
        var raw_buf: [800]u8 = undefined;
        const raw_z = std.fmt.bufPrintZ(&raw_buf, "{s}", .{raw_name}) catch return null;
        if (!raw_to_canonical.contains(name)) {
            const k = std.heap.page_allocator.dupe(u8, name) catch return null;
            const v = std.heap.page_allocator.dupe(u8, canonical) catch return null;
            raw_to_canonical.put(std.heap.page_allocator, k, v) catch return null;
        }
        const src = moduleSource(canonical) orelse {
            std.debug.print("[loader] no source for: {s}\n", .{canonical});
            return null;
        };
        if (std.c.getenv("DSH_LOAD_TRACE") != null) std.debug.print("[load:esm] {s} -> {s}\n", .{ raw_name, canonical });
        // JSON 模块（`import x from "pkg/package.json"`——对象字面量换装）
        if (std.mem.indexOfScalar(u8, canonical, '.') != null and std.mem.lastIndexOfScalar(u8, canonical, '.') != null and std.mem.eql(u8, canonical[std.mem.lastIndexOfScalar(u8, canonical, '.').?..], ".json")) {
            // JSON 模块：对象字面量换装（export default）
            const jsrc = std.fmt.allocPrint(std.heap.page_allocator, "const __j = {s}; export default __j;", .{src}) catch return null;
            defer std.heap.page_allocator.free(jsrc);
            const jt0 = monoNs();
            const jval = c.JS_Eval(ctx, jsrc.ptr, jsrc.len, raw_z.ptr, c.JS_EVAL_TYPE_MODULE | c.JS_EVAL_FLAG_COMPILE_ONLY);
            load_compile_ns += @intCast(monoNs() - jt0);
            load_compile_count += 1;
            if (c.JS_IsException(jval)) {
                self.consumeException(ctx, "json-compile");
                return null;
            }
            const jm: *c.JSModuleDef = @ptrCast(jval.u.ptr);
            c.JS_FreeValue(ctx, jval);
            return jm;
        }

        // CJS interop uses the same synchronous executor as require().  The ESM
        // module is only a bridge, so a CJS file cannot be evaluated a second time
        // in a separate lexical scope (which breaks exports reassignment and cycles).
        var cjs_buf: ?[]u8 = null;
        defer if (cjs_buf) |cb| std.heap.page_allocator.free(cb);
        const eval_src: []const u8 = blk: {
            if (!looksCjs(src)) break :blk src;
            var bridge_buf: [8192]u8 = undefined;
            var bridge_len: usize = 0;
            const prefix = std.fmt.bufPrint(
                bridge_buf[bridge_len..],
                "const __dsh_cjs = globalThis.__dshRequireSync('{s}', '{s}'); export default __dsh_cjs;\n",
                .{ canonical, canonical },
            ) catch return null;
            bridge_len += prefix.len;
            var named = collectCjsNamedExports(src);
            // TypeScript __exportStar is dynamic. Add stable names consumed by
            // OpenTelemetry ESM clients when its CJS root is selected.
            if (std.mem.startsWith(u8, canonical, "@opentelemetry/semantic-conventions/")) {
                const otel_names = [_][]const u8{
                    "ATTR_TELEMETRY_SDK_NAME",
                    "ATTR_TELEMETRY_SDK_LANGUAGE",
                    "ATTR_TELEMETRY_SDK_VERSION",
                    "ATTR_SERVICE_NAME",
                    "ATTR_SERVICE_INSTANCE_ID",
                    "ATTR_EXCEPTION_MESSAGE",
                    "ATTR_EXCEPTION_STACKTRACE",
                    "ATTR_EXCEPTION_TYPE",
                    "ATTR_OS_TYPE",
                    "ATTR_OS_VERSION",
                    "ATTR_HOST_ARCH",
                    "ATTR_HOST_ID",
                    "ATTR_HOST_NAME",
                    "ATTR_PROCESS_COMMAND",
                    "ATTR_PROCESS_COMMAND_ARGS",
                    "ATTR_PROCESS_EXECUTABLE_NAME",
                    "ATTR_PROCESS_EXECUTABLE_PATH",
                    "ATTR_PROCESS_OWNER",
                    "ATTR_PROCESS_PID",
                    "ATTR_PROCESS_RUNTIME_DESCRIPTION",
                    "ATTR_PROCESS_RUNTIME_NAME",
                    "ATTR_PROCESS_RUNTIME_VERSION",
                    "TELEMETRY_SDK_LANGUAGE_VALUE_NODEJS",
                    "TELEMETRY_SDK_LANGUAGE_VALUE_WEBJS",
                };
                for (otel_names) |extra| {
                    var duplicate = false;
                    for (named.items[0..named.len]) |existing| {
                        if (std.mem.eql(u8, existing, extra)) duplicate = true;
                    }
                    if (!duplicate and named.len < named.items.len) {
                        named.items[named.len] = extra;
                        named.len += 1;
                    }
                }
            }
            for (named.items[0..named.len]) |export_name| {
                const line = std.fmt.bufPrint(
                    bridge_buf[bridge_len..],
                    "export const {s} = __dsh_cjs.{s};\n",
                    .{ export_name, export_name },
                ) catch break;
                bridge_len += line.len;
            }
            const bridge = std.heap.page_allocator.alloc(u8, bridge_len) catch return null;
            @memcpy(bridge, bridge_buf[0..bridge_len]);
            cjs_buf = bridge;
            break :blk bridge;
        };
        const t0 = monoNs();
        const val = c.JS_Eval(ctx, eval_src.ptr, eval_src.len, raw_z.ptr, c.JS_EVAL_TYPE_MODULE | c.JS_EVAL_FLAG_COMPILE_ONLY);
        load_compile_ns += @intCast(monoNs() - t0);
        load_compile_count += 1;
        if (c.JS_IsException(val)) {
            std.debug.print("[quickjs-host] compile failed: {s}\n", .{canonical});
            self.consumeException(ctx, "compile");
            return null;
        }
        const m: *c.JSModuleDef = @ptrCast(val.u.ptr);
        const meta = c.JS_GetImportMeta(ctx, m);
        if (!c.JS_IsException(meta) and c.JS_IsObject(meta)) {
            _ = c.JS_SetPropertyStr(ctx, meta, "url", c.JS_NewString(ctx, canonical.ptr));
            c.JS_FreeValue(ctx, meta);
        }
        c.JS_FreeValue(ctx, val);
        return m;
    }

    fn consumeException(self: *QuickjsHost, ctx: ?*c.JSContext, tag: []const u8) void {
        _ = self;
        const ex = c.JS_GetException(ctx);
        const msg = c.JS_ToCStringLen(ctx, null, ex);
        if (msg) |m| {
            std.debug.print("[quickjs-host] {s} failed: {s}\n", .{ tag, std.mem.span(m) });
            c.JS_FreeCString(ctx, m);
        }
        c.JS_FreeValue(ctx, ex);
    }
};

// ---- 解析与源表（与 spike 相同的规则，保持一处语义） ----

/// 裸内置名映射（node 生态惯用 `fs`/`path`... → node: 面——resolver 前置）
fn normalizeBuiltin(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "fs")) return "node:fs";
    if (std.mem.eql(u8, name, "fs/promises")) return "node:fs/promises";
    if (std.mem.eql(u8, name, "path")) return "node:path";
    if (std.mem.eql(u8, name, "os")) return "node:os";
    if (std.mem.eql(u8, name, "url")) return "node:url";
    if (std.mem.eql(u8, name, "buffer")) return "node:buffer";
    if (std.mem.eql(u8, name, "util")) return "node:util";
    if (std.mem.eql(u8, name, "timers")) return "node:timers";
    if (std.mem.eql(u8, name, "crypto")) return "node:crypto";
    if (std.mem.eql(u8, name, "stream")) return "node:stream";
    if (std.mem.eql(u8, name, "zlib")) return "node:zlib";
    if (std.mem.eql(u8, name, "events")) return "node:events";
    if (std.mem.eql(u8, name, "assert")) return "node:assert";
    if (std.mem.eql(u8, name, "child_process")) return "node:child_process";
    if (std.mem.eql(u8, name, "worker_threads")) return "node:worker_threads";
    if (std.mem.eql(u8, name, "vm")) return "node:vm";
    if (std.mem.eql(u8, name, "perf_hooks")) return "node:perf_hooks";
    if (std.mem.eql(u8, name, "process")) return "node:process";
    if (std.mem.eql(u8, name, "querystring")) return "node:querystring";
    if (std.mem.eql(u8, name, "string_decoder")) return "node:string_decoder";
    if (std.mem.eql(u8, name, "constants")) return "node:constants";
    return null;
}

/// 子路径前缀解析（`pkg/deep/path`——表内前缀匹配——gen 闭包的深层文件面）
fn resolveSubpath(name: []const u8) ?[]const u8 {
    for (app.modules) |m| {
        if (std.mem.eql(u8, m.name, name)) return m.name;
        if (std.mem.startsWith(u8, m.name, name) and m.name.len > name.len and m.name[name.len] == '/') return m.name;
        // 无扩展子路径（`pkg/x.lazy` → 表名 `pkg/x.lazy.js`）
        if (m.name.len == name.len + 3 and std.mem.startsWith(u8, m.name, name) and std.mem.endsWith(u8, m.name, ".js")) return m.name;
        // exports 布局后缀（`pkg/sub/path` → `.../dist/sub/path.js` / `.../lib/sub/path.js`——任何目录前缀）
        var njs: [768]u8 = undefined;
        var nmjs: [768]u8 = undefined;
        if (std.fmt.bufPrint(&njs, "{s}.js", .{name}) catch null) |njsn| {
            if (m.name.len > njsn.len and std.mem.endsWith(u8, m.name, njsn)) return m.name;
        }
        if (std.fmt.bufPrint(&nmjs, "{s}.mjs", .{name}) catch null) |nmjsn| {
            if (m.name.len > nmjsn.len and std.mem.endsWith(u8, m.name, nmjsn)) return m.name;
        }
    }
    return null;
}

/// lib 子路径启发（`pkg/subpath` → `pkg/lib/subpath.js`/`pkg/lib/types/subpath.js`——exports 场布局）
fn resolveLibSubpath(name: []const u8) ?[]const u8 {
    // 包名分离：@scope/name 两段——第一段后为 sub（保持多段 sub——dist/providers/all 型）
    var pkg_end: usize = 0;
    if (std.mem.startsWith(u8, name, "@")) {
        const slash1 = std.mem.indexOfScalar(u8, name, '/') orelse return null;
        const slash2 = std.mem.indexOfScalarPos(u8, name, slash1 + 1, '/') orelse return null;
        pkg_end = slash2;
    } else {
        const slash1 = std.mem.indexOfScalar(u8, name, '/') orelse return null;
        pkg_end = slash1;
    }
    const pkg = name[0..pkg_end];
    const sub = name[pkg_end + 1 ..];
    var b1: [512]u8 = undefined;
    var b2: [512]u8 = undefined;
    if (std.fmt.bufPrint(&b1, "{s}/lib/{s}.js", .{ pkg, sub }) catch null) |c1| {
        if (resolveSpec(c1)) |hit| return hit;
    }
    if (std.fmt.bufPrint(&b2, "{s}/lib/types/{s}.js", .{ pkg, sub }) catch null) |c2| {
        if (resolveSpec(c2)) |hit| return hit;
    }
    var b3: [512]u8 = undefined;
    if (std.fmt.bufPrint(&b3, "{s}/dist/{s}.js", .{ pkg, sub }) catch null) |c3| {
        if (resolveSpec(c3)) |hit| return hit;
    }
    return null;
}

fn resolvePackageExport(name: []const u8, out: []u8, prefer_esm: bool) package_exports.Result {
    if (std.mem.startsWith(u8, name, ".") or std.mem.startsWith(u8, name, "node:")) {
        return .{ .declared = false, .target = null };
    }

    const pkg_end = if (std.mem.startsWith(u8, name, "@")) blk: {
        const first = std.mem.indexOfScalar(u8, name, '/') orelse return .{ .declared = false, .target = null };
        break :blk std.mem.indexOfScalarPos(u8, name, first + 1, '/') orelse name.len;
    } else std.mem.indexOfScalar(u8, name, '/') orelse name.len;
    const package_name = name[0..pkg_end];

    var package_json_buf: [768]u8 = undefined;
    const package_json_name = std.fmt.bufPrint(&package_json_buf, "{s}/package.json", .{package_name}) catch
        return .{ .declared = false, .target = null };
    const package_json_key = resolveSpec(package_json_name) orelse
        return .{ .declared = false, .target = null };
    const package_json = moduleSource(package_json_key) orelse
        return .{ .declared = false, .target = null };

    var target_buf: [768]u8 = undefined;
    // ESM package consumers may opt into the non-standard module condition.
    // CJS require keeps Node's import/node/default ordering and remains fail-closed.
    const result = if (prefer_esm and std.mem.startsWith(u8, package_name, "@opentelemetry/"))
        package_exports.resolveWithModule(package_name, name, package_json, &target_buf)
    else
        package_exports.resolve(package_name, name, package_json, &target_buf);
    if (!result.declared) return result;
    const target = result.target orelse return .{ .declared = true, .target = null };
    if (!std.mem.startsWith(u8, target, "./")) return .{ .declared = true, .target = null };
    const canonical = std.fmt.bufPrint(out, "{s}/{s}", .{ package_name, target[2..] }) catch
        return .{ .declared = true, .target = null };
    return .{ .declared = true, .target = canonical };
}

fn findAppModule(name: []const u8) ?*const app.Module {
    var lo: usize = 0;
    var hi: usize = app.modules.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const item = &app.modules[mid];
        switch (std.mem.order(u8, item.name, name)) {
            .lt => lo = mid + 1,
            .eq => return item,
            .gt => hi = mid,
        }
    }
    return null;
}

fn resolveSpec(name: []const u8) ?[]const u8 {
    const item = findAppModule(name) orelse return null;
    return item.name;
}

// builtin 面由闭包依赖扫描自动生成（tools/gen-app-esm.py -> builtin_stubs.zig）
const bs = @import("builtin_stubs.zig");
const INTERNAL_SPEC_PREFIX = "dsh-internal:";

/// 查找名（去前缀）→ canonical：模块以引擎查找名注册后，裸名（'diff'）注册的模块
/// 内部的相对导入无法从模块名推导真实目录，normalizer 经此表还原 canonical 再拼路径。
var raw_to_canonical: std.StringHashMapUnmanaged([]const u8) = .{};

// 装载计时探针（打印由 DSH_LOAD_TRACE 门控）：累计模块编译耗时/次数，
// 供启动构成分析（编译 vs 顶层求值 vs 宿主开销）。
var load_compile_ns: u64 = 0;
var load_compile_count: u32 = 0;

fn monoNs() i128 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(i128, ts.sec) * 1_000_000_000 + @as(i128, ts.nsec);
}

fn moduleSource(name: []const u8) ?[]const u8 {
    // Builtins are a short table; the application closure is kept sorted and queried logarithmically.
    for (bs.builtins) |b| {
        if (std.mem.eql(u8, b.name, name)) return b.src;
    }
    const item = findAppModule(name) orelse return null;
    return item.src;
}

fn engineNormalizer(
    ctx: ?*c.JSContext,
    module_base_name: [*c]const u8,
    module_name: [*c]const u8,
    attributes: c.JSValueConst,
    userdata: ?*anyopaque,
) callconv(.c) ?[*:0]u8 {
    _ = attributes;
    _ = userdata;
    const raw_base = std.mem.span(module_base_name);
    const base_marked = std.mem.startsWith(u8, raw_base, INTERNAL_SPEC_PREFIX);
    const base = if (base_marked) raw_base[INTERNAL_SPEC_PREFIX.len..] else raw_base;
    // 裸名注册的模块按 canonical 还原目录（'diff' -> 'diff/libesm/index.js'）。
    const base_real = raw_to_canonical.get(base) orelse base;
    const name = std.mem.span(module_name);
    if (!std.mem.startsWith(u8, name, "./") and !std.mem.startsWith(u8, name, "../")) {
        return dupCString(ctx, name);
    }
    // 相对名解析：base 目录 + './..' 段合并（../ 上退、./ 折叠）
    const rel = if (std.mem.startsWith(u8, name, "./")) name[2..] else name;
    const base_dir = if (std.mem.lastIndexOfScalar(u8, base_real, '/')) |idx| base_real[0..idx] else "";
    // 统一栈：base_dir 各段 + rel 段，`..` 逐级上退（**base_dir 也退**——75 轮修复只退 rel 段的 bug）
    var stack: std.ArrayList([]const u8) = .{ .items = &.{}, .capacity = 0 };
    defer stack.deinit(std.heap.page_allocator);
    if (base_dir.len > 0) {
        var bd = std.mem.tokenizeScalar(u8, base_dir, '/');
        while (bd.next()) |seg| {
            if (seg.len == 0) continue;
            stack.append(std.heap.page_allocator, seg) catch return null;
        }
    }
    var it = std.mem.tokenizeScalar(u8, rel, '/');
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, ".") or seg.len == 0) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (stack.items.len > 0) {
                _ = stack.pop();
            }
            continue;
        }
        stack.append(std.heap.page_allocator, seg) catch return null;
    }
    var total: usize = 0;
    for (stack.items) |p| total += p.len + 1;
    // Every relative import is an internal package edge; bare imports remain external
    // and continue through package exports enforcement in loadModule().
    const prefix = INTERNAL_SPEC_PREFIX;
    const out = jsMalloc(ctx, total + prefix.len + 1) orelse return null;
    var w: usize = 0;
    if (prefix.len > 0) {
        @memcpy(out[0..prefix.len], prefix);
        w = prefix.len;
    }
    for (stack.items, 0..) |p, i| {
        @memcpy(out[w..][0..p.len], p);
        w += p.len;
        if (i + 1 < stack.items.len) {
            out[w] = '/';
            w += 1;
        }
    }
    out[w] = 0;
    return @ptrCast(out);
}

fn dupCString(ctx: ?*c.JSContext, name: []const u8) ?[*:0]u8 {
    const out = jsMalloc(ctx, name.len + 1) orelse return null;
    @memcpy(out[0..name.len], name);
    out[name.len] = 0;
    return @ptrCast(out);
}

fn jsUndefConst() c.JSValue {
    return .{ .u = .{ .int32 = 0 }, .tag = c.JS_TAG_UNDEFINED };
}

fn jsMalloc(ctx: ?*c.JSContext, size: usize) ?[*]u8 {
    const p = c.js_malloc(ctx, size) orelse return null;
    return @ptrCast(p);
}

fn engineModuleLoader(
    ctx: ?*c.JSContext,
    module_name: [*c]const u8,
    userdata: ?*anyopaque,
    attributes: c.JSValueConst,
) callconv(.c) ?*c.JSModuleDef {
    _ = attributes;
    const host: *QuickjsHost = @ptrCast(@alignCast(userdata orelse return null));
    return host.loadModule(ctx, std.mem.span(module_name));
}

const CjsNamedExports = struct {
    items: [48][]const u8 = undefined,
    len: usize = 0,
};

fn isCjsIdentChar(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or
        (ch >= '0' and ch <= '9') or ch == '_' or ch == '$';
}

fn collectCjsNamedExports(src: []const u8) CjsNamedExports {
    var result = CjsNamedExports{};
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, src, pos, "exports.")) |at| {
        const start = at + "exports.".len;
        var end = start;
        while (end < src.len and isCjsIdentChar(src[end])) : (end += 1) {}
        if (end > start and !std.mem.eql(u8, src[start..end], "default")) {
            var duplicate = false;
            for (result.items[0..result.len]) |item| {
                if (std.mem.eql(u8, item, src[start..end])) {
                    duplicate = true;
                    break;
                }
            }
            if (!duplicate and result.len < result.items.len) {
                result.items[result.len] = src[start..end];
                result.len += 1;
            }
        }
        pos = if (end > at) end else at + 1;
    }
    return result;
}

/// CJS require 同步面：canonical(调用模块)+spec → 表解析 → 工厂 eval（GLOBAL）→ exports 值。
fn jsRequireSync(
    ctx: ?*c.JSContext,
    this_val: c.JSValueConst,
    argc: c_int,
    argv: [*c]const c.JSValueConst,
) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 2) return c.JS_ThrowTypeError(ctx, "require(canonical, spec)", @as(c_int, 0));
    const c_canon = c.JS_ToCStringLen(ctx, null, argv[0]) orelse return c.JS_ThrowTypeError(ctx, "canonical", @as(c_int, 0));
    defer c.JS_FreeCString(ctx, c_canon);
    const c_spec = c.JS_ToCStringLen(ctx, null, argv[1]) orelse return c.JS_ThrowTypeError(ctx, "spec", @as(c_int, 0));
    defer c.JS_FreeCString(ctx, c_spec);
    const canonical = std.mem.span(c_canon);
    const spec = std.mem.span(c_spec);

    // Resolve relative CJS requests against the caller, including ../ traversal.
    var rel_buf: [512]u8 = undefined;
    var joined_buf: [768]u8 = undefined;
    const relative_spec = std.mem.startsWith(u8, spec, "./") or std.mem.startsWith(u8, spec, "../");
    const rel_cand = blk: {
        if (!relative_spec) break :blk spec;
        const slash = std.mem.lastIndexOfScalar(u8, canonical, '/') orelse 0;
        const dir = canonical[0..slash];
        const joined = std.fmt.bufPrint(&joined_buf, "{s}/{s}", .{ dir, spec }) catch break :blk spec;
        var parts: [64][]const u8 = undefined;
        var count: usize = 0;
        var it = std.mem.tokenizeScalar(u8, joined, '/');
        while (it.next()) |part| {
            if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
            if (std.mem.eql(u8, part, "..")) {
                if (count > 0) count -= 1;
                continue;
            }
            if (count == parts.len) break :blk spec;
            parts[count] = part;
            count += 1;
        }
        var w: usize = 0;
        for (parts[0..count], 0..) |part, i| {
            if (i > 0) {
                rel_buf[w] = '/';
                w += 1;
            }
            @memcpy(rel_buf[w .. w + part.len], part);
            w += part.len;
        }
        break :blk rel_buf[0..w];
    };

    var js_buf: [512]u8 = undefined;
    var mjs_buf: [512]u8 = undefined;
    const js_cand = std.fmt.bufPrint(&js_buf, "{s}.js", .{rel_cand}) catch null;
    const mjs_cand = std.fmt.bufPrint(&mjs_buf, "{s}.mjs", .{rel_cand}) catch null;
    var export_buf: [768]u8 = undefined;
    const package_result: package_exports.Result = if (relative_spec)
        .{ .declared = false, .target = null }
    else
        resolvePackageExport(rel_cand, &export_buf, false);
    var root_buf: [512]u8 = undefined;
    const root_cand = std.fmt.bufPrint(&root_buf, "{s}/index.js", .{rel_cand}) catch null;
    const target = normalizeBuiltin(rel_cand) orelse
        resolveSpec(rel_cand) orelse
        (if (js_cand) |jc| resolveSpec(jc) else null) orelse
        (if (mjs_cand) |mc| resolveSpec(mc) else null) orelse
        (if (package_result.declared) package_result.target else null) orelse
        (if (root_cand) |rc| resolveSpec(rc) else null) orelse {
        return c.JS_ThrowReferenceError(ctx, "cjs require: module not found", @as(c_int, 0));
    };
    const tsrc = moduleSource(target) orelse return c.JS_ThrowReferenceError(ctx, "cjs require: no source", @as(c_int, 0));
    if (std.c.getenv("DSH_LOAD_TRACE") != null) std.debug.print("[load:cjs] {s}\n", .{target});

    var target_key_buf: [768]u8 = undefined;
    const target_key = std.fmt.bufPrintZ(&target_key_buf, "{s}", .{target}) catch
        return c.JS_ThrowInternalError(ctx, "cjs require: target too long", @as(c_int, 0));
    const global = c.JS_GetGlobalObject(ctx);
    defer c.JS_FreeValue(ctx, global);
    const cache = c.JS_GetPropertyStr(ctx, global, "__dshCjsCache");
    defer c.JS_FreeValue(ctx, cache);
    if (!c.JS_IsObject(cache)) return c.JS_ThrowInternalError(ctx, "cjs require: cache unavailable", @as(c_int, 0));
    const cached = c.JS_GetPropertyStr(ctx, cache, target_key.ptr);
    if (!c.JS_IsUndefined(cached)) return cached;
    c.JS_FreeValue(ctx, cached);

    // ESM builtin stubs cannot be evaluated through the CJS source wrapper.
    // Provide common namespaces directly for legacy CJS packages.
    if (std.mem.eql(u8, target, "node:process")) {
        const process_src = "({ versions: { node: '0.0.0-embedded', dsh: '0.0.0-zig' }, platform: 'linux', env: {}, cwd: () => '/' })";
        const builtin = c.JS_Eval(ctx, process_src.ptr, process_src.len, "builtin-process.js", c.JS_EVAL_TYPE_GLOBAL);
        if (c.JS_IsException(builtin)) return builtin;
        _ = c.JS_SetPropertyStr(ctx, cache, target_key.ptr, c.JS_DupValue(ctx, builtin));
        return builtin;
    }
    if (std.mem.eql(u8, target, "node:buffer")) {
        const buffer_src = "({ Buffer: globalThis.Buffer })";
        const builtin = c.JS_Eval(ctx, buffer_src.ptr, buffer_src.len, "builtin-buffer.js", c.JS_EVAL_TYPE_GLOBAL);
        if (c.JS_IsException(builtin)) return builtin;
        _ = c.JS_SetPropertyStr(ctx, cache, target_key.ptr, c.JS_DupValue(ctx, builtin));
        return builtin;
    }

    const placeholder = c.JS_NewObject(ctx);
    if (c.JS_IsException(placeholder)) return placeholder;
    _ = c.JS_SetPropertyStr(ctx, cache, target_key.ptr, placeholder);
    // Keep module state inside an IIFE: nested require() must not overwrite it.
    const body = std.fmt.allocPrint(std.heap.page_allocator, "(function(){{var __dsh_module={{exports:globalThis.__dshCjsCache['{s}']}};(function(module,exports,require){{", .{target}) catch return c.JS_ThrowInternalError(ctx, "oom", @as(c_int, 0));
    defer std.heap.page_allocator.free(body);
    const tail = std.fmt.allocPrint(std.heap.page_allocator, "}})(__dsh_module,__dsh_module.exports,(s)=>globalThis.__dshRequireSync('{s}', s)); globalThis.__dshCjsCache['{s}']=__dsh_module.exports; return __dsh_module.exports;}})();", .{ target, target }) catch return c.JS_ThrowInternalError(ctx, "oom", @as(c_int, 0));
    defer std.heap.page_allocator.free(tail);
    const full = std.heap.page_allocator.alloc(u8, body.len + tsrc.len + tail.len) catch return c.JS_ThrowInternalError(ctx, "oom", @as(c_int, 0));
    defer std.heap.page_allocator.free(full);
    @memcpy(full[0..body.len], body);
    @memcpy(full[body.len .. body.len + tsrc.len], tsrc);
    @memcpy(full[body.len + tsrc.len ..], tail);
    const val = c.JS_Eval(ctx, full.ptr, full.len, "cjs-require.js", c.JS_EVAL_TYPE_GLOBAL);
    if (c.JS_IsException(val)) {
        const ex = c.JS_GetException(ctx);
        c.JS_FreeValue(ctx, ex);
        _ = c.JS_SetPropertyStr(ctx, cache, target_key.ptr, jsUndefConst());
        return val;
    }
    return val;
}

/// 宿主单调时钟（性能面）：nanoTimestamp → 毫秒浮点（性能.now 语义）。
fn jsPerfNow(
    ctx: ?*c.JSContext,
    this_val: c.JSValueConst,
    argc: c_int,
    argv: [*c]const c.JSValueConst,
) callconv(.c) c.JSValue {
    _ = this_val;
    _ = argc;
    _ = argv;
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    const ns = @as(f64, @floatFromInt(ts.sec)) * 1_000_000_000.0 + @as(f64, @floatFromInt(ts.nsec));
    return c.JS_NewFloat64(ctx, ns / 1_000_000.0);
}
