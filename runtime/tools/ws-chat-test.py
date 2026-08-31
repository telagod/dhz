#!/usr/bin/env python3
"""WS 会话面板端到端测试（stdlib RFC6455 客户端——无依赖）。
流程: handshake → subscribe → history（导入校验）→ chat-send → 等 assistant 事件 → 打印。
用法: ws-chat-test.py [port=3091] [question]
"""
import socket, base64, os, json, sys, time

def ws_connect(host, port, path):
    s = socket.create_connection((host, port), timeout=30)
    key = base64.b64encode(os.urandom(16)).decode()
    req = ('GET %s HTTP/1.1\r\nHost: %s:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n' % (path, host, port))
    req += 'Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n' % key
    s.sendall(req.encode())
    resp = b''
    while b'\r\n\r\n' not in resp:
        chunk = s.recv(4096)
        if not chunk: raise RuntimeError('handshake eof')
        resp += chunk
    assert b' 101' in resp.split(b'\r\n', 1)[0], resp[:200]
    return s

def ws_send(s, payload):
    data = payload.encode()
    mask = os.urandom(4)
    n = len(data)
    hdr = bytearray([0x81])
    if n < 126: hdr.append(0x80 | n)
    elif n < 65536: hdr.append(0x80 | 126); hdr += n.to_bytes(2, 'big')
    else: hdr.append(0x80 | 127); hdr += n.to_bytes(8, 'big')
    s.sendall(bytes(hdr) + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))

def ws_recv(s, timeout=90):
    s.settimeout(timeout)
    hdr = b''
    while len(hdr) < 2: hdr += s.recv(2 - len(hdr))
    ln = hdr[1] & 0x7F
    if ln == 126:
        ext = b''
        while len(ext) < 2: ext += s.recv(2 - len(ext))
        ln = int.from_bytes(ext, 'big')
    elif ln == 127:
        ext = b''
        while len(ext) < 8: ext += s.recv(8 - len(ext))
        ln = int.from_bytes(ext, 'big')
    data = b''
    while len(data) < ln:
        chunk = s.recv(ln - len(data))
        if not chunk: raise RuntimeError('frame eof')
        data += chunk
    return data.decode('utf-8', 'replace')

def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 3091
    q = sys.argv[2] if len(sys.argv) > 2 else '用一句中文介绍你自己'
    s = ws_connect('127.0.0.1', port, '/ws')
    ws_send(s, json.dumps({ 'op': 'subscribe', 'session': 'chat' }))
    print('sub:', ws_recv(s)[:80])
    ws_send(s, json.dumps({ 'op': 'history', 'limit': 300 }))
    hraw = ws_recv(s)
    print('history raw:', repr(hraw[:200]))
    h = json.loads(hraw)
    evs = h.get('events', [])
    print('history: total=%d got=%d' % (h.get('total', -1), len(evs)))
    for e in evs[-2:]: print('  tail:', e.get('type'), repr((e.get('text') or '')[:60]))
    ws_send(s, json.dumps({ 'op': 'chat-send', 'session': 'chat', 'text': q }))
    print('send:', ws_recv(s)[:100])
    t0 = time.time()
    while time.time() - t0 < 90:
        fr = ws_recv(s, timeout=max(1, 90 - (time.time() - t0)))
        try: m = json.loads(fr)
        except Exception: continue
        if m.get('op') == 'event' and m.get('session') == 'chat':
            ws_send(s, json.dumps({ 'op': 'history', 'limit': 5 }))
        elif m.get('op') == 'history':
            last = (m.get('events') or [{}])[-1]
            if last.get('type') == 'assistant/message':
                print('assistant:', repr(last.get('text', '')[:200]))
                print('WS-CHAT-E2E: PASS (%.1fs)' % (time.time() - t0))
                return
    print('WS-CHAT-E2E: FAIL (timeout)')
    sys.exit(1)

if __name__ == '__main__':
    main()
