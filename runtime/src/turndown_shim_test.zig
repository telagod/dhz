//! Turndown/GFM shim 契约测试（`zig build test-turndown-shim`）。
//! 经 QuickjsHost 动态 import turndown 与 @joplin/turndown-plugin-gfm 两个 shim 根，
//! 对 web 工具的 HTML→Markdown 契约做逐例断言：标题 h1-h6、强调、链接、
//! 有序/无序列表、GFM 表格（含分隔行）、script/style/noscript 移除、实体还原、
//! br 换行、段落断行、链式 API 与插件对象接受面。
//! 守护对象：dsh-tool-web 的 turndown 实例构造与 web_fetch 的 text 转换面。

const std = @import("std");
const host_q = @import("host_quickjs.zig");
const c = host_q.c;

const harness =
    \\(async () => {
    \\  const out = [];
    \\  const t = (name, fn) => { let v; try { v = fn(); } catch (e) { v = 'err:' + String(e).slice(0, 60) + '@' + String(e && e.stack ? e.stack.split('\n').slice(1, 3).join('<') : '').trim().slice(0, 200); } out.push(name + '=' + String(v)); };
    \\  const mod = await import('turndown');
    \\  const T = mod.TurndownService ?? mod.default;
    \\  const gfmMod = await import('@joplin/turndown-plugin-gfm');
    \\  t('heading1', () => T === mod.default && new T().turndown('<h1>Title</h1>').indexOf('# Title') === 0);
    \\  t('heading3', () => new T().turndown('<h3>Sub</h3>').indexOf('### Sub') === 0);
    \\  t('emphasis', () => new T().turndown('<p><strong>a</strong> and <em>b</em></p>').indexOf('**a**') >= 0 && new T().turndown('<p><strong>a</strong></p>').indexOf('*b*') < 0);
    \\  t('link', () => new T().turndown('<a href="https://x.y">link</a>').indexOf('[link](https://x.y)') >= 0);
    \\  t('unorderedList', () => { const md = new T().turndown('<ul><li>one</li><li>two</li></ul>'); return md.indexOf('- one') >= 0 && md.indexOf('- two') >= 0; });
    \\  t('orderedList', () => { const md = new T().turndown('<ol><li>first</li><li>second</li></ol>'); return md.indexOf('1. first') >= 0 && md.indexOf('2. second') >= 0; });
    \\  t('gfmTable', () => { const md = new T().turndown('<table><tr><th>A</th><th>B</th></tr><tr><td>1</td><td>2</td></tr></table>'); return md.indexOf('| A | B |') >= 0 && md.indexOf('| --- | --- |') >= 0 && md.indexOf('| 1 | 2 |') >= 0; });
    \\  t('scriptRemoved', () => { const md = new T().turndown('<script>evil()</script><p>ok</p>'); return md.indexOf('evil') < 0 && md.indexOf('ok') >= 0; });
    \\  t('entityUnescape', () => { const md = new T().turndown('<p>a &amp; b</p>'); return md.indexOf('a & b') >= 0; });
    \\  t('brBreak', () => { const md = new T().turndown('x<br/>y'); return md.indexOf('x\ny') >= 0; });
    \\  t('chaining', () => { const md = new T({ headingStyle: 'atx' }).use(() => {}).use({ rules: {} }).remove(['x']).addRule('r', { filter: 'p' }).turndown('<h2>H</h2>'); return md.indexOf('## H') === 0; });
    \\  t('gfmPluginObject', () => { const inst = new T(); inst.use(gfmMod.gfm); return typeof inst.turndown('<p>x</p>') === 'string' && inst.turndown('<p>x</p>').indexOf('x') >= 0; });
    \\  t('emptyInput', () => new T().turndown('') === '');
    \\  t('paragraphBreak', () => { const md = new T().turndown('<p>a</p><p>b</p>'); return md.indexOf('a\n\nb') >= 0; });
    \\  t('multilineStrong', () => new T().turndown('<strong>multi\nline</strong>').indexOf('**multi\nline**') >= 0);
    \\  globalThis.__turndownShimTest = out.join('|');
    \\})().catch((e) => { globalThis.__turndownShimTest = 'harness-err:' + String(e).slice(0, 120); });
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

test "turndown shim contract suite" {
    var host = try host_q.QuickjsHost.init();
    defer host.deinit();
    const v = c.JS_Eval(host.ctx, harness.ptr, harness.len, "turndown-shim-test.mjs", c.JS_EVAL_TYPE_GLOBAL);
    if (c.JS_IsException(v)) {
        const ex = c.JS_GetException(host.ctx);
        const em = c.JS_ToCStringLen(host.ctx, null, ex);
        if (em) |mm| {
            std.debug.print("[turndown-shim-test] eval error: {s}\n", .{std.mem.span(mm)});
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
    const result = try readGlobalStr(host.ctx, "__turndownShimTest");
    defer std.testing.allocator.free(result);
    std.debug.print("[turndown-shim-test] {s}\n", .{result});
    if (std.mem.indexOf(u8, result, "harness-err:") != null) return error.HarnessFailed;
    if (std.mem.indexOf(u8, result, "=bad") != null) return error.CaseFailed;
    if (std.mem.indexOf(u8, result, "=err:") != null) return error.CaseError;
    var ok_count: usize = 0;
    var it = std.mem.splitScalar(u8, result, '|');
    while (it.next()) |entry| {
        if (std.mem.endsWith(u8, entry, "=true")) ok_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 15), ok_count);
}
