// 无头 ESM 页面仿真：shell 内联脚本 + 插件 + index bundle（真 ESM 执行）
import fs from 'node:fs';
import path from 'node:path';
import http from 'node:http';
import vm from 'node:vm';
import { randomBytes } from 'node:crypto';

const ROOT = '/home/dapao/proj/dhz/runtime/vendor/web-shell';
const html = fs.readFileSync(path.join(ROOT, 'shell.html'), 'utf8');

function realFetch(url, init) {
  return new Promise((resolve, reject) => {
    const u = new URL(url, 'http://127.0.0.1:3088');
    const req = http.request({ host: u.hostname, port: +u.port, path: u.pathname + u.search, method: (init && init.method) || 'GET', headers: { ...((init && init.headers) || {}), origin: 'http://127.0.0.1:3088' } }, (res) => {
      let b = '';
      res.setEncoding('utf8');
      res.on('data', (c) => b += c);
      res.on('end', () => resolve({ ok: res.statusCode >= 200 && res.statusCode < 300, status: res.statusCode, headers: res.headers, text: async () => b, json: async () => JSON.parse(b) }));
    });
    req.on('error', reject);
    if (init && init.body) req.write(init.body);
    req.end();
  });
}

class FakeWebSocket {
  constructor(url) {
    this.url = url;
    this.readyState = 0;
    this._buf = Buffer.alloc(0);
    const u = new URL(url);
    const key = randomBytes(16).toString('base64');
    const req = http.request({ host: u.hostname, port: +u.port, path: u.pathname, headers: { Connection: 'Upgrade', Upgrade: 'websocket', 'Sec-WebSocket-Version': 13, 'Sec-WebSocket-Key': key, origin: 'http://127.0.0.1:3088' } });
    req.on('upgrade', (res, socket) => {
      this.readyState = 1;
      this._socket = socket;
      socket.on('data', (d) => this._feed(d));
      socket.on('close', () => { this.readyState = 3; this._close && this._close.forEach((f) => f({ code: 1006 })); });
      this._open && this._open.forEach((f) => f({}));
    });
    req.on('error', (e) => { this._err && this._err.forEach((f) => f(e)); });
    req.end();
  }
  _feed(chunk) {
    this._buf = Buffer.concat([this._buf, chunk]);
    // 解析 unmasked 服务端 text 帧 → message 事件（data 为字符串）
    while (this._buf.length >= 2) {
      const b0 = this._buf[0], b1 = this._buf[1];
      const op = b0 & 0x0f;
      let len = b1 & 0x7f, off = 2;
      if (len === 126) { if (this._buf.length < 4) return; len = this._buf.readUInt16BE(2); off = 4; }
      else if (len === 127) { if (this._buf.length < 10) return; len = Number(this._buf.readBigUInt64BE(2)); off = 10; }
      if (this._buf.length < off + len) return;
      const payload = this._buf.slice(off, off + len).toString('utf8');
      this._buf = this._buf.slice(off + len);
      if (op === 1) {
        this._message && this._message.forEach((f) => f({ data: payload }));
      } else if (op === 9) {
        // ping → pong（掩码帧：客户方向必须掩码——简化为随机掩码）
        const mask = randomBytes(4);
        const pong = Buffer.alloc(2 + 4 + payload.length);
        pong[0] = 0x8A; pong[1] = 0x80 | payload.length;
        mask.copy(pong, 2);
        for (let i = 0; i < payload.length; i++) pong[6 + i] = payload.charCodeAt(i) ^ mask[i % 4];
        this._socket && this._socket.write(pong);
      }
    }
  }
  addEventListener(ev, f) { this['_' + ev] = (this['_' + ev] || []).concat(f); }
  send() {}
  close() { this._socket && this._socket.destroy(); this.readyState = 3; this._close && this._close.forEach((f) => f({})); }
}

class FakeEventSource {
  constructor(url) {
    const u = new URL(url, 'http://127.0.0.1:3088');
    const req = http.get({ host: u.hostname, port: +u.port, path: u.pathname, headers: { origin: 'http://127.0.0.1:3088' } }, (res) => {
      if (res.statusCode !== 200) { this._err && this._err.forEach((f) => f(new Error('ES ' + res.statusCode))); return; }
      this._open && this._open.forEach((f) => f({}));
      res.on('data', () => {});
    });
    req.on('error', (e) => { this._err && this._err.forEach((f) => f(e)); });
  }
  addEventListener(ev, f) { this['_' + ev] = (this['_' + ev] || []).concat(f); }
  close() {}
}

// —— 全局面（ESM 代码会访问 window.* / document.*）
const elem = () => ({ setAttribute(){}, getAttribute: () => null, setAttributeNS(){}, appendChild(){ return arguments[0] }, append(...a){ return a }, prepend(...a){ return a }, removeChild(){ return arguments[0] }, remove(){}, insertBefore(){ return arguments[0] }, insertAdjacentElement(){ return arguments[1] }, replaceChildren(){}, closest: () => null, contains: () => false, querySelector: () => null, querySelectorAll: () => [], getBoundingClientRect: () => ({ left: 0, top: 0, right: 1280, bottom: 800, width: 1280, height: 800, x: 0, y: 0 }), focus(){}, blur(){}, click(){}, scrollIntoView(){}, textContent: '', innerHTML: '', innerText: '', outerHTML: '', value: '', style: { setProperty(){}, getPropertyValue: () => '' }, sheet: { insertRule(){} }, classList: { add(){}, remove(){}, toggle(){}, contains: () => false }, toggleAttribute(){}, addEventListener(){}, removeEventListener(){}, dispatchEvent: () => true, dataset: {}, rel: '', href: '', relList: { supports: () => false }, childNodes: [], children: [], firstChild: null, lastChild: null, parentNode: null, parentElement: null, nextSibling: null, previousSibling: null, tagName: 'DIV', nodeName: 'DIV', nodeType: 1, ownerDocument: null });
globalThis.location = { origin: 'http://127.0.0.1:3088', protocol: 'http:', host: '127.0.0.1:3088', hostname: '127.0.0.1', port: '3088', href: 'http://127.0.0.1:3088/', search: '', hash: '', pathname: '/' };
const rootEl = elem(); rootEl.getBoundingClientRect = () => ({ left: 0, top: 0, right: 1280, bottom: 800, width: 1280, height: 800 }); rootEl.querySelectorAll = () => []; rootEl.querySelector = () => null; rootEl.textContent = ''; rootEl.innerHTML = '';
globalThis.document = { createElement: elem, createTextNode: () => ({ textContent: '' }), documentElement: elem(), head: elem(), body: elem(), addEventListener(){}, removeEventListener(){}, querySelector: (sel) => (String(sel).includes('root') ? rootEl : null), querySelectorAll: () => [], getElementById: (id) => (String(id).includes('root') ? rootEl : null), visibilityState: 'visible' };
globalThis.window = globalThis;
try { Object.defineProperty(globalThis, 'navigator', { value: { userAgent: 'node-esm-sim', language: 'zh-CN', languages: ['zh-CN'] }, configurable: true }); } catch {}
globalThis.fetch = realFetch;
globalThis.WebSocket = FakeWebSocket;
globalThis.EventSource = FakeEventSource;
globalThis.addEventListener = () => {};
globalThis.removeEventListener = () => {};
globalThis.getComputedStyle = () => ({ getPropertyValue: () => '' });
globalThis.matchMedia = () => ({ matches: false, addEventListener(){}, removeEventListener(){} });
globalThis.requestAnimationFrame = (f) => setTimeout(f, 16);
globalThis.MutationObserver = class { observe(){} disconnect(){} takeRecords() { return [] } };
globalThis.IntersectionObserver = class { observe(){} disconnect(){} unobserve(){} };
globalThis.ResizeObserver = class { observe(){} disconnect(){} unobserve(){} };
globalThis.CustomEvent = class extends Event { constructor(t, o) { super(t, o); this.detail = o && o.detail; } };
globalThis.history = { pushState(){}, replaceState(){}, back(){} };
globalThis.Image = class { set src(v) { if (this.onload) this.onload(); } };
globalThis.screen = { width: 1920, height: 1080 };
globalThis.innerWidth = 1280;
globalThis.innerHeight = 800;
globalThis.devicePixelRatio = 1;
globalThis.DOMParser = class { parseFromString() { return globalThis.document; } };
globalThis.HTMLElement = class {};
globalThis.localStorage = { getItem: () => null, setItem(){}, removeItem(){} };
globalThis.sessionStorage = globalThis.localStorage;

// —— 1) 内联脚本（vm 同步执行）
const scripts = [...html.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g)].map((m) => m[1]).filter((s) => s.trim());
const ctx = vm.createContext(globalThis);
for (const s of scripts) {
  try { vm.runInContext(s, ctx, { filename: 'shell-inline.js' }); }
  catch (e) { console.log('INLINE FAIL:', e.message); process.exit(1); }
}
console.log('inline scripts OK:', scripts.length);

// —— 2) src 脚本（插件=同步 vm；index/vendor=动态 ESM import）
const srcs = [...html.matchAll(/<script[^>]*src="([^"]+)"[^>]*><\/script>/g)].map((m) => m[1]);
for (const src of srcs) {
  const u = new URL(src, 'http://127.0.0.1:3088');
  let fp = path.join(ROOT, 'dist', u.pathname.replace(/^\//, ''));
  if (u.pathname.startsWith('/plugins/')) {
    const pkg = u.pathname.replace('/plugins/', '').replace('/client.js', '');
    fp = path.join(ROOT, 'plugins', pkg + '.js');
    const code = fs.readFileSync(fp, 'utf8');
    try { vm.runInContext(code, ctx, { filename: u.pathname }); console.log('plugin OK:', u.pathname); }
    catch (e) { console.log('PLUGIN FAIL:', u.pathname, e.message); process.exit(1); }
  } else {
    let fp2 = fp;
    if (u.pathname.startsWith('/dsh-whale/')) fp2 = path.join(ROOT, 'dist', 'dsh-whale-widget.js');
    try { await import('file://' + fp2); console.log('ESM OK:', u.pathname); }
    catch (e) { console.log('ESM FAIL:', u.pathname, '——', e.message); console.log(String(e.stack).split('\n').slice(0, 4).join('\n')); }
  }
}
console.log('PAGE-ESM: 完成initial-load；存活 30s 观察连接行为');
// 连接循环观测：拦截 console.warn/error 找 reconnect 痕迹
const origWarn = console.warn;
console.warn = function (...a) { console.log('[page-warn]', ...a); origWarn.apply(console, arguments); };
const origErr = console.error;
console.error = function (...a) { console.log('[page-error]', ...a.map((x) => String(x && x.message || x).slice(0, 200))); origErr.apply(console, arguments); };
setTimeout(() => { console.log('done（30s 存活结束）'); process.exit(0); }, 30000);
