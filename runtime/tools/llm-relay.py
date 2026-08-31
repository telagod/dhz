#!/usr/bin/env python3
"""LLM 渠道中继（真 API 线——独立进程）。
Zig 运行时无 TLS 面：guest postAsync 打本中继（本地明文 HTTP），
中继转发上游 HTTPS 并注入 Authorization: Bearer，SSE 字节流原样回流（close-delimited，同 llm-mock 线形）。
密钥仅从 $DSH_HOME/.credentials.yaml refs 读取——不打印、不落盘、不进 Zig 进程。
用法: llm-relay.py [port=18100]
环境: DSH_LLM_BASE（默认 https://api.a6api.com/v1） DSH_LLM_KEY_ENV（默认 A6API_API_KEY）
"""
import sys, os, json
import http.server
try:
    import requests
except Exception as e:
    print('llm-relay: requests missing', e); sys.exit(2)

def load_key():
    home = os.environ.get('DSH_HOME', os.path.expanduser('~/.dsh'))
    keyname = os.environ.get('DSH_LLM_KEY_ENV', 'A6API_API_KEY')
    try:
        in_refs = False
        with open(os.path.join(home, '.credentials.yaml'), encoding='utf-8') as f:
            for line in f:
                s = line.rstrip('\n')
                if s.startswith('refs:'):
                    in_refs = True; continue
                if in_refs:
                    if not s.startswith(' '): break
                    if ':' in s:
                        k, _, v = s.strip().partition(':')
                        v = v.strip().strip('"').strip("'")
                        if k == keyname and v: return v
    except Exception as e:
        print('llm-relay: credentials read failed:', e, file=sys.stderr)
    return None

KEY = load_key()
BASE = os.environ.get('DSH_LLM_BASE', 'https://api.a6api.com/v1').rstrip('/')
MOCK_ONLY_FIELDS = ('tool',)  # mock 线专有字段——真 API 会 400，剥掉

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def _raw(self, status, ctype):
        self.send_response(status)
        self.send_header('Content-Type', ctype)
        self.end_headers()

    def do_GET(self):
        if self.path == '/ping':
            body = b'pong:relay'
            self._raw(200, 'text/plain')
            self.wfile.write(body); self.wfile.flush()
            return
        self._raw(404, 'text/plain')

    def do_POST(self):
        ln = int(self.headers.get('Content-Length', 0) or 0)
        body = self.rfile.read(ln) if ln else b''
        if not KEY:
            self._raw(502, 'text/plain')
            self.wfile.write(b'llm-relay: no api key in credentials refs'); return
        # 剥 mock 专有字段 + 消息白名单化（dsh 消息含 source/id/time 等——真 API 会 400）
        try:
            m = json.loads(body.decode('utf-8', 'replace') or '{}')
            for k in MOCK_ONLY_FIELDS: m.pop(k, None)
            keep = ('role', 'content', 'name', 'tool_call_id', 'tool_calls')
            if isinstance(m.get('messages'), list):
                m['messages'] = [{k: v for k, v in (x or {}).items() if k in keep} for x in m['messages']]
            body = json.dumps(m).encode('utf-8')
        except Exception:
            pass
        path = self.path
        if path.startswith('/v1/') and BASE.endswith('/v1'):
            path = path[3:]
        if os.environ.get('DSH_RELAY_TRACE'):
            print('relay: POST %s body=%dB' % (path, len(body)), file=sys.stderr, flush=True)
        url = BASE + path
        try:
            r = requests.post(url, data=body, timeout=300, stream=True, headers={
                'Content-Type': 'application/json',
                'Authorization': 'Bearer ' + KEY,
                'Accept': 'text/event-stream',
            })
            # 全量缓冲后带 Content-Length 回写——guest 读取面按长度消费（同 llm-mock 契约；
            # close-delimited 流式会被 guest 读成空 body，实测 realWire 200:body=''）
            buf = b''.join(r.iter_content(4096))
            r.close()
            if os.environ.get('DSH_RELAY_TRACE'):
                print('relay: <- status=%d resp=%dB head=%s' % (r.status_code, len(buf), buf[:80]), file=sys.stderr, flush=True)
            self.send_response(r.status_code)
            self.send_header('Content-Type', r.headers.get('Content-Type', 'application/json'))
            self.send_header('Content-Length', str(len(buf)))
            self.end_headers()
            i = 0
            while i < len(buf):
                n = min(8192, len(buf) - i)
                self.wfile.write(buf[i:i + n]); self.wfile.flush()
                i += n
        except Exception as e:
            try:
                self._raw(502, 'text/plain')
                self.wfile.write(('llm-relay upstream error: ' + str(e)[:200]).encode())
            except Exception:
                pass

if __name__ == '__main__':
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 18100
    print('llm-relay: 127.0.0.1:%d -> %s (key %s)' % (port, BASE, 'loaded' if KEY else 'MISSING'), flush=True)
    http.server.ThreadingHTTPServer(('127.0.0.1', port), H).serve_forever()
