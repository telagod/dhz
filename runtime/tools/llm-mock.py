#!/usr/bin/env python3
"""LLM mock（M-2 录播线——独立进程；POST /chat -> JSON echo；SSE 面后续）。"""
import sys, json
try:
    import http.server
except Exception as e:
    print('http missing', e); sys.exit(2)
class H(http.server.BaseHTTPRequestHandler):
    def _write_chunked(self, resp):
        import time as _t
        _i = 0
        while _i < len(resp):
            _n = min(9, len(resp) - _i)
            self.wfile.write(resp[_i:_i + _n])
            self.wfile.flush()
            _t.sleep(0.002)
            _i += _n

    def do_POST(self):
        ln = int(self.headers.get('Content-Length', 0) or 0)
        body = self.rfile.read(ln) if ln else b''
        m = {}
        try: m = json.loads(body.decode('utf-8', 'replace') or '{}')
        except Exception: pass
        if '/chat/completions' in self.path:
            has_tool_msg = any(((x or {}).get('source') or {}).get('kind') == 'tool' for x in m.get('messages', []) or [])
            if m.get('stream') and m.get('tool'):
                full_args = json.dumps({"command": "echo tool-round-trip; exit 0", "description": "round trip", "timeout": 30})
                cut = len(json.dumps({"command": "echo tool-round-trip; exit 0", "description": "round trip"}))
                parts = [
                    'data: ' + json.dumps({"id": "cmpl-s", "choices": [{"index": 0, "delta": {"role": "assistant", "content": ""}}]}) + '\n\n',
                    'data: ' + json.dumps({"id": "cmpl-s", "choices": [{"index": 0, "delta": {"tool_calls": [{"index": 0, "id": "call-1", "type": "function", "function": {"name": "bash", "arguments": full_args[:cut]}}]}}]}) + '\n\n',
                    'data: ' + json.dumps({"id": "cmpl-s", "choices": [{"index": 0, "delta": {"tool_calls": [{"index": 0, "function": {"arguments": full_args[cut:]}}]}}]}) + '\n\n',
                    'data: [DONE]\n\n',
                ]
                resp = ''.join(parts).encode()
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.send_header('Content-Length', str(len(resp)))
                self.end_headers()
                self._write_chunked(resp)
                return
            if m.get('stream') and has_tool_msg:
                parts = [
                    'data: {"id":"cmpl-s","choices":[{"index":0,"delta":{"role":"assistant","content":""}}]}\n\n',
                    'data: {"id":"cmpl-s","choices":[{"index":0,"delta":{"content":"tool"}}]}\n\n',
                    'data: {"id":"cmpl-s","choices":[{"index":0,"delta":{"content":"-ok"}}]}\n\n',
                    'data: [DONE]\n\n',
                ]
                resp = ''.join(parts).encode()
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.send_header('Content-Length', str(len(resp)))
                self.end_headers()
                self._write_chunked(resp)
                return
            if m.get('stream'):
                parts = [
                    'data: {"id":"cmpl-s","choices":[{"index":0,"delta":{"role":"assistant","content":""}}]}\n\n',
                    'data: {"id":"cmpl-s","choices":[{"index":0,"delta":{"content":"mock"}}]}\n\n',
                    'data: {"id":"cmpl-s","choices":[{"index":0,"delta":{"content":"-text"}}]}\n\n',
                    'data: [DONE]\n\n',
                ]
                resp = ''.join(parts).encode()
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.send_header('Content-Length', str(len(resp)))
                self.end_headers()
                self._write_chunked(resp)
                return
            resp = json.dumps({"id": "cmpl-1", "choices": [{"index": 0, "message": {"role": "assistant", "content": "mock-text"}}], "usage": {"total_tokens": 7}}).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(resp)))
            self.end_headers()
            self.wfile.write(resp)
            return
        if self.path.startswith('/v1/frames'):
            parts = ['data: {"i": ' + str(i) + '}\n\n' for i in range(1000)]
            resp = ''.join(parts).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Content-Length', str(len(resp)))
            self.end_headers()
            self.wfile.write(resp)
            return
        if self.path.startswith('/v1/big'):
            resp = b'x' * 100000
            self.send_response(200)
            self.send_header('Content-Type', 'application/octet-stream')
            self.send_header('Content-Length', str(len(resp)))
            self.end_headers()
            # 分块写（8×12500B + flush + 间隙——wire 级逐块到达面）
            import time as _t
            for _i in range(8):
                self.wfile.write(resp[12500 * _i:12500 * (_i + 1)])
                self.wfile.flush()
                _t.sleep(0.02)
            return
        if self.path.startswith('/stream-chunk'):
            payload = 'data: hello\n\ndata: world\n\ndata: [DONE]\n\n'
            resp = payload.encode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Content-Length', str(len(resp)))
            self.end_headers()
            # 不规则分块（1-7 字节 + 5ms 间隙）——强制帧跨块面
            import time as _t2
            _i = 0
            while _i < len(resp):
                _n = (_i % 7) + 1
                self.wfile.write(resp[_i:_i + _n])
                self.wfile.flush()
                _t2.sleep(0.005)
                _i += _n
            return
        resp = json.dumps({'ok': True, 'echo': m.get('echo')}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(resp)))
        self.end_headers()
        self.wfile.write(resp)
    def _sse_payload(self):
        return ('data: {"delta": "hello "}\n\n'
                'data: {"delta": "world"}\n\n'
                'data: [DONE]\n\n').encode()
    def do_GET(self):
        if self.path.startswith('/v1/chat/completions') or self.path.startswith('/chat/completions'):
            resp = json.dumps({"id": "cmpl-1", "choices": [{"index": 0, "message": {"role": "assistant", "content": "mock-text"}}], "usage": {"total_tokens": 7}}).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(resp)))
            self.end_headers()
            self.wfile.write(resp)
            return
        if self.path.startswith('/stream'):
            resp = self._sse_payload()
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Content-Length', str(len(resp)))
            self.end_headers()
            self.wfile.write(resp)
            return
        resp = b'{"ok": true, "path": "' + self.path.encode() + b'"}'
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(resp)))
        self.end_headers()
        self.wfile.write(resp)
    def log_message(self, *a): pass
port = int(sys.argv[1]) if len(sys.argv) > 1 else 18099
# 并发面：真实 LLM endpoint 并发服务；SSE 流进行时 frames/health 等探针不再排队
server = http.server.ThreadingHTTPServer(('127.0.0.1', port), H)
server.daemon_threads = True
server.serve_forever()
