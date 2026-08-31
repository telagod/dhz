//! OTEL shim 契约测试（`zig build test-otel-shim`）。
//! 经 QuickjsHost 动态 import 三个嵌入 OTEL shim 根（sdk-logs/resources/exporter；
//! 嵌入闭包不含 @opentelemetry/api——sdk-logs shim 自含 api 面，boot 消费方
//! dsh-session-telemetry-otel 仅 import sdk-logs 与 exporter）。逐例断言：日志
//! emit→processor→exporter 链、批量 forceFlush、provider shutdown 丢批语义、
//! resource 属性与合并、OTLP exporter payload 构造 / 无 url 失败回调 /
//! shutdown 后失败回调。
//! 守护对象：session telemetry 的 OpenTelemetry 兼容层。

const std = @import("std");
const host_q = @import("host_quickjs.zig");
const c = host_q.c;

const harness =
    \\(async () => {
    \\  const out = [];
    \\  const t = async (name, fn) => { let v; try { v = await fn(); } catch (e) { v = 'err:' + String(e).slice(0, 60) + '@' + String(e && e.stack ? e.stack.split('\n').slice(1, 3).join('<') : '').trim().slice(0, 200); } out.push(name + '=' + String(v)); };
    \\  const imp = async (name, slot) => { try { return await import(name); } catch (e) { out.push('import-' + slot + '=err:' + String(e).slice(0, 90) + '@' + String(e && e.stack ? e.stack.split('\n')[1] : '').trim().slice(0, 120)); return null; } };
    \\  const logs = await imp('@opentelemetry/sdk-logs', 'sdk-logs');
    \\  const res = await imp('@opentelemetry/resources', 'resources');
    \\  const exp = await imp('@opentelemetry/exporter-logs-otlp-http', 'exporter');
    \\  if (!logs || !res || !exp) { globalThis.__otelShimTest = out.join('|'); return; }
    \\  await t('logEmitSimple', async () => { const mem = new logs.InMemoryLogRecordExporter(); const provider = new logs.LoggerProvider({ processors: [new logs.SimpleLogRecordProcessor(mem)] }); provider.getLogger('svc').emit({ body: 'x', severityText: 'INFO' }); return mem.getFinishedLogRecords().length === 1 && mem.getFinishedLogRecords()[0].body === 'x'; });
    \\  await t('batchForceFlush', async () => { const mem = new logs.InMemoryLogRecordExporter(); const provider = new logs.LoggerProvider({ processors: [new logs.BatchLogRecordProcessor({ exporter: mem, maxExportBatchSize: 512 })] }); const logger = provider.getLogger('svc'); logger.emit({ body: 'a' }); logger.emit({ body: 'b' }); logger.emit({ body: 'c' }); const before = mem.getFinishedLogRecords().length; await provider.forceFlush(); return before === 0 && mem.getFinishedLogRecords().length === 3; });
    \\  await t('providerShutdownDrops', async () => { const mem = new logs.InMemoryLogRecordExporter(); const provider = new logs.LoggerProvider({ processors: [new logs.SimpleLogRecordProcessor(mem)] }); await provider.shutdown(); provider.getLogger('svc').emit({ body: 'late' }); return mem.getFinishedLogRecords().length === 0; });
    \\  await t('resourceAttrs', async () => res.resourceFromAttributes({ 'service.name': 'svc' }).attributes['service.name'] === 'svc');
    \\  await t('resourceMerge', async () => { const base = res.resourceFromAttributes({ a: '1' }); const other = res.resourceFromAttributes({ b: '2', a: 'override' }); const merged = base.merge(other); return merged.attributes.a === 'override' && merged.attributes.b === '2'; });
    \\  await t('exporterNoUrlFailed', async () => { let result = null; new exp.OTLPLogExporter({}).export([{ body: 'x' }], (r) => { result = r; }); return result !== null && result.code === 1; });
    \\  await t('exporterPayload', async () => { const captured = {}; const orig = globalThis.fetch; globalThis.fetch = (url, options) => { captured.url = url; captured.payload = JSON.parse(options.body); return Promise.resolve({ ok: true }); }; try { const exporter = new exp.OTLPLogExporter({ url: 'http://127.0.0.1:4318/v1/logs' }); let result = null; exporter.export([{ body: 'hi', severityText: 'INFO', attributes: { k: 'v' } }], (r) => { result = r; }); for (let i = 0; i < 5; i++) await Promise.resolve(); const record = captured.payload.resourceLogs[0].scopeLogs[0].logRecords[0]; return result !== null && result.code === 0 && captured.url === 'http://127.0.0.1:4318/v1/logs' && record.body === 'hi' && record.severityText === 'INFO'; } finally { globalThis.fetch = orig; } });
    \\  await t('exporterShutdown', async () => { const exporter = new exp.OTLPLogExporter({ url: 'http://127.0.0.1:4318/v1/logs' }); await exporter.shutdown(); let result = null; exporter.export([{ body: 'x' }], (r) => { result = r; }); return result !== null && result.code === 1; });
    \\  globalThis.__otelShimTest = out.join('|');
    \\})().catch((e) => { globalThis.__otelShimTest = 'harness-err:' + String(e).slice(0, 120); });
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

test "otel shim contract suite" {
    var host = try host_q.QuickjsHost.init();
    defer host.deinit();
    const v = c.JS_Eval(host.ctx, harness.ptr, harness.len, "otel-shim-test.mjs", c.JS_EVAL_TYPE_GLOBAL);
    if (c.JS_IsException(v)) {
        const ex = c.JS_GetException(host.ctx);
        const em = c.JS_ToCStringLen(host.ctx, null, ex);
        if (em) |mm| {
            std.debug.print("[otel-shim-test] eval error: {s}\n", .{std.mem.span(mm)});
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
    const result = try readGlobalStr(host.ctx, "__otelShimTest");
    defer std.testing.allocator.free(result);
    std.debug.print("[otel-shim-test] {s}\n", .{result});
    if (std.mem.indexOf(u8, result, "harness-err:") != null) return error.HarnessFailed;
    if (std.mem.indexOf(u8, result, "=bad") != null) return error.CaseFailed;
    if (std.mem.indexOf(u8, result, "=err:") != null) return error.CaseError;
    var ok_count: usize = 0;
    var it = std.mem.splitScalar(u8, result, '|');
    while (it.next()) |entry| {
        if (std.mem.endsWith(u8, entry, "=true")) ok_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 8), ok_count);
}
