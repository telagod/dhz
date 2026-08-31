//! YAML shim 契约测试（`zig build test-yaml-shim`）。
//! 经 QuickjsHost 动态 import 两个 shim 根（js-yaml / yaml），对重写解析器的
//! 关键面做逐例断言：紧凑块序列、同缩进序列、流式 []/{}、!!js 引号/裸表达式、
//! 行内注释、单引号转义、文档标记、Document API 与 dump 往返。
//! 守护对象：entry 两阶段探针、bundle 78 行解析、settings/credentials Document 面。

const std = @import("std");
const host_q = @import("host_quickjs.zig");
const c = host_q.c;

const harness =
    \\(async () => {
    \\  const out = [];
    \\  const t = (name, fn) => { let v; try { v = fn(); } catch (e) { v = 'err:' + String(e).slice(0, 60) + '@' + String(e && e.stack ? e.stack.split('\n').slice(1, 4).join('<') : '').trim().slice(0, 220); } out.push(name + '=' + String(v)); };
    \\  const m = await import('js-yaml');
    \\  const y = await import('yaml');
    \\  t('compactBlock', () => { const d = m.load('- insert:\n  - id: probe\n    name: boot-probe\n    config:\n      mode: !!js process.env.X\n'); return d[0].insert[0].config.mode.__jsExpr === 'process.env.X'; });
    \\  t('sameIndentSeq', () => { const d = m.load('- insert:\n  - id: a\n  - id: b\n'); return d[0].insert.length === 2 && d[0].insert[1].id === 'b'; });
    \\  t('deeperSeq', () => { const d = m.load('- insert:\n    - id: timer\n      name: \'@x/y\'\n'); return d[0].insert[0].name === '@x/y'; });
    \\  t('flowSeq', () => { const d = m.load('config:\n  root: [\'.\']\n'); return Array.isArray(d.config.root) && d.config.root[0] === '.'; });
    \\  t('flowMap', () => { const d = m.load('a: { b: 1, c: [2, 3] }'); return d.a.b === 1 && d.a.c[1] === 3; });
    \\  t('jsExprQuoted', () => { const d = m.load('policy: !!js "(process.env.M ?? \'ask\') === \'never\'"\n'); return d.policy.__jsExpr === "(process.env.M ?? 'ask') === 'never'"; });
    \\  t('jsExprBare', () => { const d = m.load('disabled: !!js process.platform === \'win32\'\n'); return d.disabled.__jsExpr === "process.platform === 'win32'"; });
    \\  t('inlineComment', () => { const d = m.load('a: 1 # note\nb: "# keep"\n'); return d.a === 1 && d.b === '# keep'; });
    \\  t('scalars', () => { const d = m.load('n: 5\nf: 1.5\nb: true\nz: null\n'); return d.n === 5 && d.f === 1.5 && d.b === true && d.z === null; });
    \\  t('singleQuoteEscape', () => { const d = m.load("k: 'it''s'\n"); return d.k === "it's"; });
    \\  t('docMarkers', () => { const d = m.load('---\na: 1\n...\n'); return d.a === 1; });
    \\  t('dumpScalarNode', () => { return m.dump({ mode: { __jsExpr: 'x' } }).indexOf('mode: !!js x') >= 0; });
    \\  t('dumpRow', () => { return typeof m.dump({ id: 'a', config: { mode: { __jsExpr: 'x' } } }) === 'string'; });
    \\  t('dumpArr1', () => { return typeof m.dump({ a: [{ b: 1 }] }) === 'string'; });
    \\  t('dumpArr2', () => { return typeof m.dump({ a: [{ b: [{ c: 1 }] }] }) === 'string'; });
    \\  t('dumpArrText', () => { return JSON.stringify(m.dump({ a: [{ b: 1 }] })); });
    \\  t('dumpFull', () => { const src = { layers: [{ insert: [{ id: 'a', config: { mode: { __jsExpr: 'x' } } }] }] }; globalThis.__dumped = m.dump(src); return typeof globalThis.__dumped === 'string'; });
    \\  t('loadFull', () => { const re = m.load(globalThis.__dumped); return JSON.stringify(re) === JSON.stringify({ layers: [{ insert: [{ id: 'a', config: { mode: { __jsExpr: 'x' } } }] }] }); });
    \\  t('documentApi', () => { const d = y.parseDocument('enabled: true\nitems:\n  - one\n'); const v = d.toJS(); return v.enabled === true && v.items[0] === 'one' && y.isMap(d.contents); });
    \\  t('documentSetIn', () => { const d = y.parseDocument('a: {}\n'); d.setIn(['a', 'b'], 7); return d.toJS().a.b === 7; });
    \\  t('stringifyRoundtrip', () => { const src = { a: [1, 2], b: { c: 'x' } }; return JSON.stringify(y.parse(y.stringify(src))) === JSON.stringify(src); });
    \\  globalThis.__yamlShimTest = out.join('|');
    \\})().catch((e) => { globalThis.__yamlShimTest = 'harness-err:' + String(e).slice(0, 120); });
;

fn readGlobalStr(ctx: ?*c.JSContext, name: [*c]const u8) ![]const u8 {
    const global = c.JS_GetGlobalObject(ctx);
    defer c.JS_FreeValue(ctx, global);
    const v = c.JS_GetPropertyStr(ctx, global, name);
    defer c.JS_FreeValue(ctx, v);
    const s = c.JS_ToCStringLen(ctx, null, v) orelse return error.NoText;
    defer c.JS_FreeCString(ctx, s);
    return std.testing.allocator.dupe(u8, std.mem.span(s));
}

test "yaml shim contract suite" {
    var host = try host_q.QuickjsHost.init();
    defer host.deinit();
    const v = c.JS_Eval(host.ctx, harness.ptr, harness.len, "yaml-shim-test.mjs", c.JS_EVAL_TYPE_GLOBAL);
    if (c.JS_IsException(v)) {
        const ex = c.JS_GetException(host.ctx);
        const em = c.JS_ToCStringLen(host.ctx, null, ex);
        if (em) |mm| {
            std.debug.print("[yaml-shim-test] eval error: {s}\n", .{std.mem.span(mm)});
            c.JS_FreeCString(host.ctx, mm);
        }
        c.JS_FreeValue(host.ctx, ex);
        return error.HarnessEval;
    }
    c.JS_FreeValue(host.ctx, v);
    var pending: c_int = 1;
    while (pending > 0) {
        var ctxp: ?*c.JSContext = null;
        pending = c.JS_ExecutePendingJob(host.rt, &ctxp);
    }
    const result = try readGlobalStr(host.ctx, "__yamlShimTest");
    defer std.testing.allocator.free(result);
    std.debug.print("[yaml-shim-test] {s}\n", .{result});
    if (std.mem.indexOf(u8, result, "harness-err:") != null) return error.HarnessFailed;
    if (std.mem.indexOf(u8, result, "=bad") != null) return error.CaseFailed;
    if (std.mem.indexOf(u8, result, "=err:") != null) return error.CaseError;
    var ok_count: usize = 0;
    var it = std.mem.splitScalar(u8, result, '|');
    while (it.next()) |entry| {
        if (std.mem.endsWith(u8, entry, "=true")) ok_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 20), ok_count);
}
