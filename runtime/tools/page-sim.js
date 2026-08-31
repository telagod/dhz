// 无头页面仿真：shell.html 脚本序列 + 42 插件 + BOOT + 网络桩
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const http = require('node:http');

const ROOT = '/home/dapao/proj/dhz/runtime/vendor/web-shell';
const html = fs.readFileSync(path.join(ROOT, 'shell.html'), 'utf8');

// —— 网络桩：fetch/WebSocket/EventSource 都打真 3088
function realFetch(url, init) {
  return new Promise((resolve, reject) => {
    const u = new URL(url, 'http://127.0.0.1:3088');
    const req = http.request({ host: u.hostname, port: +u.port, path: u.pathname + u.search, method: (init && init.method) || 'GET', headers: { ...(init && init.headers || {}), origin: 'http://127.0.0.1:3088' } }, (res) => {
      let b = '';
      const decoder = new (require('node:stream').Transform)({ transform(c, e, cb) { cb(null, c); } });
      res.setEncoding('utf8');
      res.on('data', (c) => b += c);
      res.on('end', () => resolve({ ok: res.statusCode >= 200 && res.statusCode < 300, status: res.statusCode, headers: res.headers, text: async () => b, json: async () => JSON.parse(b), body: { getReader: () => ({ read: async () => ({ done: true, value: undefined }) }) } }));
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
    const u = new URL(url);
    const key = require('node:crypto').randomBytes(16).toString('base64');
    const req = http.request({ host: u.hostname, port: +u.port, path: u.pathname, headers: { Connection: 'Upgrade', Upgrade: 'websocket', 'Sec-WebSocket-Version': 13, 'Sec-WebSocket-Key': key, origin: 'http://127.0.0.1:3088' } });
    req.on('upgrade', (res, socket) => {
      this.readyState = 1;
      this._socket = socket;
      socket.on('data', (d) => this._feed(d));
      this._open && this._open.forEach((f) => f({}));
    });
    req.on('error', (e) => { this._err && this._err.forEach((f) => f(e)); });
    req.end();
  }
  _feed() {} // 帧解析略——只需 open 事件即可驱动 streamsOpen
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

// —— DOM/全局最小面
const sandbox = {
  console, setTimeout, clearTimeout, setInterval, clearInterval,
  fetch: realFetch, WebSocket: FakeWebSocket, EventSource: FakeEventSource,
  crypto: require('node:crypto').webcrypto,
  TextEncoder, TextDecoder, URL, URLSearchParams,
  performance: { now: () => Date.now() },
  AbortController, AbortSignal,
  location: { origin: 'http://127.0.0.1:3088', protocol: 'http:', host: '127.0.0.1:3088', hostname: '127.0.0.1', port: '3088', href: 'http://127.0.0.1:3088/', search: '' },
  document: { createElement: () => ({ setAttribute(){}, appendChild(){}, style: {}, sheet: { insertRule(){} }, classList: { add(){}, remove(){} } }), documentElement: { style: { setProperty(){} } }, head: { appendChild(){} }, body: { appendChild(){}, style: {}, toggleAttribute(){}, setAttribute(){}, getAttribute: () => null, addEventListener(){} }, addEventListener(){}, querySelector: () => null, querySelectorAll: () => [], getElementById: () => null, createTextNode: () => ({}) },
  window: undefined,
  navigator: { userAgent: 'node-page-sim' },
  addEventListener() {}, removeEventListener() {},
  btoa: (s) => Buffer.from(s, 'binary').toString('base64'),
  atob: (s) => Buffer.from(s, 'base64').toString('binary'),
  TextEncoder, TextDecoder,
  queueMicrotask, structuredClone,
};
sandbox.window = sandbox;
sandbox.globalThis = sandbox;

// —— 执行 shell 里的脚本序列
const scripts = [...html.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g)].map((m) => m[1]).filter((s) => s.trim());
console.log('inline scripts:', scripts.length);
// src 脚本按序加载
const srcs = [...html.matchAll(/<script[^>]*src="([^"]+)"[^>]*><\/script>/g)].map((m) => m[1]);
console.log('src scripts:', srcs.length);

const ctx = vm.createContext(sandbox);
try {
  for (const s of scripts) { vm.runInContext(s, ctx, { filename: 'shell-inline.js' }); }
  for (const src of srcs) {
    const u = new URL(src, 'http://127.0.0.1:3088');
    let fp = path.join(ROOT, 'dist', u.pathname.replace(/^\//, ''));
    if (u.pathname.startsWith('/plugins/')) {
      const pkg = u.pathname.replace('/plugins/', '').replace('/client.js', '');
      fp = path.join(ROOT, 'plugins', pkg + '.js');
    }
    const code = fs.readFileSync(fp, 'utf8');
    vm.runInContext(code, ctx, { filename: u.pathname });
    console.log('loaded', u.pathname, code.length + 'B');
  }
  console.log('PAGE-LOAD: PASS（脚本序列全执行无异常）');
} catch (e) {
  console.log('PAGE-LOAD: FAIL——', e.message);
  console.log((e.stack || '').split('\n').slice(0, 5).join('\n'));
}
setTimeout(() => { console.log('30s 后存活，WS 连接数见 /debug/gateway'); process.exit(0); }, 30000);
