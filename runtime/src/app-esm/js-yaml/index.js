// Small YAML document compatibility layer for settings, credentials, skills,
// and the cordis entry-list dialect (compact block style + !!js scalars).
function scalar(value) {
    const text = value.trim();
    if (text === '' || text === '~' || text === 'null') return null;
    if (text === 'true') return true;
    if (text === 'false') return false;
    if (text.startsWith('"') && text.endsWith('"')) { try { return JSON.parse(text); } catch {} }
    if (text.startsWith("'") && text.endsWith("'")) return text.slice(1, -1).replace(/''/g, "'");
    if (/^-?(?:[0-9]+(?:\.[0-9]+)?)$/.test(text)) return Number(text);
    return text;
}
function taggedScalar(value) {
    const text = value.trim();
    if (text.startsWith('!!js ')) {
        let expr = text.slice(5).trim();
        if (expr.startsWith('"') && expr.endsWith('"')) { try { expr = JSON.parse(expr); } catch { expr = expr.slice(1, -1); } }
        else if (expr.startsWith("'") && expr.endsWith("'")) expr = expr.slice(1, -1).replace(/''/g, "'");
        return { __jsExpr: expr };
    }
    return scalar(value);
}
function stripComment(body) {
    let quote = null;
    for (let i = 0; i < body.length; i++) {
        const ch = body[i];
        if (quote) {
            if (ch === quote) { if (quote === "'" && body[i + 1] === "'") { i++; continue; } quote = null; }
            continue;
        }
        if (ch === '"' || ch === "'") { quote = ch; continue; }
        if (ch === '#' && (i === 0 || body[i - 1] === ' ' || body[i - 1] === '\t')) return body.slice(0, i).trim();
    }
    return body.trim();
}
function usefulLines(text) {
    return String(text ?? '').split('\n').map((raw) => ({ indent: raw.match(/^ */) [0].length, body: raw.trim() }))
        .filter((line) => line.body && line.body !== '---' && line.body !== '...')
        .map((line) => ({ indent: line.indent, body: stripComment(line.body) }))
        .filter((line) => line.body);
}
function splitKeyColon(body) {
    let quote = null;
    for (let i = 0; i < body.length; i++) {
        const ch = body[i];
        if (quote) {
            if (ch === quote) { if (quote === "'" && body[i + 1] === "'") { i++; continue; } quote = null; }
            continue;
        }
        if (ch === '"' || ch === "'") { quote = ch; continue; }
        if (ch === ':') {
            const next = body[i + 1];
            if (i === body.length - 1 || next === ' ' || next === '\t') {
                let key = body.slice(0, i).trim();
                if ((key.startsWith('"') && key.endsWith('"')) || (key.startsWith("'") && key.endsWith("'"))) key = key.slice(1, -1);
                return { isKey: true, key, rest: body.slice(i + 1).trim() };
            }
        }
    }
    return { isKey: false };
}
function skipFlowSpace(s, i) { while (i < s.length && (s[i] === ' ' || s[i] === '\t')) i++; return i; }
function parseQuoted(s, i) {
    const mark = s[i];
    if (mark === '"') {
        let j = i + 1;
        while (j < s.length) { if (s[j] === '\\') { j += 2; continue; } if (s[j] === '"') break; j++; }
        try { return [JSON.parse(s.slice(i, j + 1)), j + 1]; } catch { return [s.slice(i + 1, j), j + 1]; }
    }
    let j = i + 1;
    while (j < s.length) { if (s[j] === "'" && s[j + 1] === "'") { j += 2; continue; } if (s[j] === "'") break; j++; }
    return [s.slice(i + 1, j).replace(/''/g, "'"), j + 1];
}
function parseFlowValue(s, i) {
    i = skipFlowSpace(s, i);
    const ch = s[i];
    if (ch === '[') {
        const arr = []; i = skipFlowSpace(s, i + 1);
        if (s[i] === ']') return [arr, i + 1];
        for (;;) {
            const parsed = parseFlowValue(s, i); arr.push(parsed[0]); i = skipFlowSpace(s, parsed[1]);
            if (s[i] === ',') { i++; continue; }
            if (s[i] === ']') return [arr, i + 1];
            return [arr, i];
        }
    }
    if (ch === '{') {
        const obj = {}; i = skipFlowSpace(s, i + 1);
        if (s[i] === '}') return [obj, i + 1];
        for (;;) {
            i = skipFlowSpace(s, i);
            let key;
            if (s[i] === '"' || s[i] === "'") { const kv = parseQuoted(s, i); key = kv[0]; i = kv[1]; }
            else { let j = i; while (j < s.length && s[j] !== ':' && s[j] !== ',' && s[j] !== '}') j++; key = s.slice(i, j).trim(); i = j; }
            i = skipFlowSpace(s, i);
            if (s[i] === ':') { const vv = parseFlowValue(s, i + 1); obj[key] = vv[0]; i = skipFlowSpace(s, vv[1]); }
            else obj[key] = null;
            if (s[i] === ',') { i++; continue; }
            if (s[i] === '}') return [obj, i + 1];
            return [obj, i];
        }
    }
    if (ch === '"' || ch === "'") return parseQuoted(s, i);
    let j = i;
    while (j < s.length && s[j] !== ',' && s[j] !== ']' && s[j] !== '}') j++;
    return [taggedScalar(s.slice(i, j)), j];
}
function flowOrScalar(text) {
    const t = text.trim();
    if (t.startsWith('[') || t.startsWith('{')) return parseFlowValue(t, 0)[0];
    return taggedScalar(t);
}
function isDashLine(body) { return body === '-' || body.startsWith('- '); }
function parseBlock(lines, start, indent) {
    const sequence = !!lines[start] && lines[start].indent === indent && isDashLine(lines[start].body);
    const result = sequence ? [] : {};
    let i = start;
    while (i < lines.length && lines[i].indent === indent) {
        const line = lines[i].body;
        if (sequence) {
            if (!isDashLine(line)) break;
            const rest = line === '-' ? '' : line.slice(2).trim();
            if (rest === '') {
                if (i + 1 < lines.length && lines[i + 1].indent > indent) { const child = parseBlock(lines, i + 1, lines[i + 1].indent); result.push(child.value); i = child.next; continue; }
                result.push(null); i++; continue;
            }
            const split = splitKeyColon(rest);
            if (split.isKey) {
                const sub = [{ indent: indent + 2, body: rest }];
                let j = i + 1;
                while (j < lines.length && lines[j].indent > indent) { sub.push(lines[j]); j++; }
                const child = parseBlock(sub, 0, indent + 2);
                result.push(child.value); i = j; continue;
            }
            result.push(flowOrScalar(rest)); i++; continue;
        }
        const split = splitKeyColon(line);
        if (!split.isKey) { i++; continue; }
        if (split.rest !== '') { result[split.key] = flowOrScalar(split.rest); i++; continue; }
        if (i + 1 < lines.length && lines[i + 1].indent > indent) { const child = parseBlock(lines, i + 1, lines[i + 1].indent); result[split.key] = child.value; i = child.next; continue; }
        if (i + 1 < lines.length && lines[i + 1].indent === indent && isDashLine(lines[i + 1].body)) { const child = parseBlock(lines, i + 1, indent); result[split.key] = child.value; i = child.next; continue; }
        result[split.key] = null; i++;
    }
    return { value: result, next: i };
}
function parseValue(text) {
    const lines = usefulLines(text);
    if (!lines.length) return {};
    return parseBlock(lines, 0, lines[0].indent).value;
}
function makeNode(value) {
    if (Array.isArray(value)) return { type: 'SEQ', items: value.map(makeNode), value };
    if (value && typeof value === 'object') return { type: 'MAP', items: Object.entries(value).map(([key, entry]) => ({ key: { type: 'SCALAR', value: key }, value: makeNode(entry) })), value };
    return { type: 'SCALAR', value };
}
function isJsExprNode(value) {
    return !!value && typeof value === 'object' && typeof value.__jsExpr === 'string' && Object.keys(value).length === 1;
}
function writeYaml(value, indent = 0) {
    const pad = ' '.repeat(indent);
    if (isJsExprNode(value)) return pad + '!!js ' + value.__jsExpr;
    if (Array.isArray(value)) {
        const rows = [];
        for (const entry of value) {
            if (entry && typeof entry === 'object' && !isJsExprNode(entry)) rows.push(pad + '-\n' + writeYaml(entry, indent + 2));
            else rows.push(pad + '- ' + formatScalar(entry));
        }
        return rows.join('\n');
    }
    if (value && typeof value === 'object') {
        const rows = [];
        for (const pair of Object.entries(value)) {
            const key = pair[0];
            const entry = pair[1];
            if (entry && typeof entry === 'object' && !isJsExprNode(entry)) rows.push(pad + key + ':\n' + writeYaml(entry, indent + 2));
            else rows.push(pad + key + ': ' + formatScalar(entry));
        }
        return rows.join('\n');
    }
    return pad + formatScalar(value);
}
function formatScalar(value) {
    if (isJsExprNode(value)) return '!!js ' + value.__jsExpr;
    if (value === null || value === undefined) return 'null';
    if (typeof value === 'string') return JSON.stringify(value);
    return String(value);
}
export class Document {
    constructor(value = {}) { this.value = value; this.errors = []; this.contents = makeNode(value); }
    toJS() { return this.value; }
    setIn(path, value) { let cursor = this.value; for (let i = 0; i < path.length - 1; i++) { const key = path[i]; if (!cursor[key] || typeof cursor[key] !== 'object') cursor[key] = {}; cursor = cursor[key]; } cursor[path[path.length - 1]] = value; this.contents = makeNode(this.value); return this; }
    get(key) { return makeNode(this.value && this.value[key]); }
    set(key, value) { return this.setIn([key], value); }
    delete(key) { if (this.value && typeof this.value === 'object') delete this.value[key]; this.contents = makeNode(this.value); }
    toString() { return writeYaml(this.value) + '\n'; }
}
export function parseDocument(text) { return new Document(parseValue(text)); }
export function parse(text) { return parseValue(text); }
export function isMap(node) { return !!node && node.type === 'MAP'; }
export function isScalar(node) { return !!node && node.type === 'SCALAR'; }
export function stringify(value) { return writeYaml(value) + '\n'; }
export class Type {
    constructor(tag, options = {}) { this.tag = tag; this.options = options; }
}
export const JSON_SCHEMA = { extend() { return this; } };
export function load(text, options = {}) { return parseValue(text); }
export function dump(value, options = {}) { return writeYaml(value) + '\n'; }
export default { Document, parseDocument, parse, isMap, isScalar, stringify, Type, JSON_SCHEMA, load, dump };
