// Small deterministic HTML-to-Markdown adapter for the embedded web tool.
// Covers the DSH-used surface: headings h1-h6, emphasis, links, br, paragraph
// breaks, ordered/unordered lists, GFM tables, script/style/noscript removal,
// entity unescaping, and the chaining API (use/remove/addRule).
function escapeText(value) {
    return String(value).replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"');
}
function inline(value) {
    return escapeText(value).replace(/<strong[^>]*>([\s\S]*?)<\/strong>/gis, '**$1**').replace(/<b[^>]*>([\s\S]*?)<\/b>/gis, '**$1**').replace(/<em[^>]*>([\s\S]*?)<\/em>/gis, '*$1*').replace(/<i[^>]*>([\s\S]*?)<\/i>/gis, '*$1*').replace(/<a[^>]*href=["']([^"']+)["'][^>]*>([\s\S]*?)<\/a>/gis, '[$2]($1)').replace(/<[^>]+>/g, '');
}
export default class TurndownService {
    constructor(options = {}) { this.options = options; this.removed = new Set(); this.rules = new Map(); }
    use(plugin) {
        if (typeof plugin === 'function') { plugin(this); return this; }
        if (plugin && typeof plugin === 'object' && plugin.rules && typeof plugin.rules === 'object') {
            for (const name of Object.keys(plugin.rules)) this.rules.set(name, plugin.rules[name]);
        }
        return this;
    }
    remove(selectors) { for (const selector of (Array.isArray(selectors) ? selectors : [selectors])) this.removed.add(String(selector)); return this; }
    addRule(name, rule) { this.rules.set(name, rule); return this; }
    turndown(html) {
        let source = String(html ?? '');
        source = source.replace(/<script[^>]*>[\s\S]*?<\/script>/gis, '').replace(/<style[^>]*>[\s\S]*?<\/style>/gis, '').replace(/<noscript[^>]*>[\s\S]*?<\/noscript>/gis, '');
        for (let level = 1; level <= 6; level++) {
            const tag = 'h' + level;
            const re = new RegExp('<' + tag + '[^>]*>([\\s\\S]*?)<\\/' + tag + '>', 'gi');
            source = source.replace(re, '#'.repeat(level) + ' $1\n\n');
        }
        source = source.replace(/<ol[^>]*>([\s\S]*?)<\/ol>/gis, (match, body) => {
            let n = 0;
            return body.replace(/<li[^>]*>([\s\S]*?)<\/li>/gis, (m2, item) => {
                n += 1;
                return n + '. ' + item + '\n';
            });
        });
        source = source.replace(/<li[^>]*>([\s\S]*?)<\/li>/gis, '- $1\n');
        source = source.replace(/<table[^>]*>([\s\S]*?)<\/table>/gis, (match, body) => this.renderTable(body));
        source = source.replace(/<br\s*\/?>/gi, '\n');
        source = source.replace(/<\/(p|div|section|article|blockquote|ul|ol|table|tr)>/gi, '\n\n');
        // inline() 最后执行：先替换 strong/em/a，再兜底剥离残余标签——
        // 若先剥离，强调/链接标记会在替换前丢失（契约测试实抓）。
        source = inline(source);
        return source.trim();
    }
    renderTable(body) {
        const rows = [];
        const rowRe = /<tr[^>]*>([\s\S]*?)<\/tr>/gi;
        let row;
        while ((row = rowRe.exec(body)) !== null) {
            const cellRe = /<t([hd])[^>]*>([\s\S]*?)<\/t\1>/gi;
            const cells = [];
            let cell;
            while ((cell = cellRe.exec(row[1])) !== null) cells.push(inline(cell[2]).replace(/\|/g, '\\|').replace(/\s+/g, ' ').trim());
            if (cells.length > 0) rows.push('| ' + cells.join(' | ') + ' |');
        }
        if (rows.length === 0) return '';
        const head = rows[0];
        const width = Math.max((head.match(/\|/g) || []).length - 1, 1);
        const border = '| ' + Array.from({ length: width }, () => '---').join(' | ') + ' |';
        return head + '\n' + border + (rows.length > 1 ? '\n' + rows.slice(1).join('\n') : '') + '\n\n';
    }
}
export { TurndownService };
