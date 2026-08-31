#!/usr/bin/env python3
"""dsh 会话导出器：session.jsonl.zstd → Zig 运行时 chat 导入 JSON。
滤掉流式碎屑（*-chunks/step/retry/inbox 等），保留实质事件并归一化双轨：
  events   —— 展示轨（user/assistant/tool-call/tool-result，长文本截断）
  messages —— LLM 上下文轨（仅 user/assistant 纯文本对，continuation 种子）
用法: export-session.py <session.jsonl.zstd> [tail=200] [out=/tmp/dsh-chat-import.json]
"""
import sys, os, json, subprocess

def main():
    src = sys.argv[1]
    tail = int(sys.argv[2]) if len(sys.argv) > 2 else 200
    out = sys.argv[3] if len(sys.argv) > 3 else '/tmp/dsh-chat-import.json'
    raw = subprocess.run(['zstd', '-dc', src], capture_output=True, check=True).stdout.decode('utf-8', 'replace')
    meta = {}
    events = []
    def text_of(parts):
        out = []
        for p in (parts or []):
            if not isinstance(p, dict): continue
            if p.get('type') == 'text' and p.get('text'): out.append(p['text'])
            elif p.get('type') == 'tool-result': out.append(text_of(p.get('content')))
        return '\n'.join(x for x in out if x)
    for line in raw.splitlines():
        if not line.strip(): continue
        try: j = json.loads(line)
        except Exception: continue
        t = j.get('type', '')
        d = j.get('data') or {}
        if t == 'session':
            meta = { 'id': j.get('id'), 'cwd': j.get('cwd'), 'createdAt': j.get('createdAt') }
        elif t == 'user/message':
            txt = text_of(d.get('content'))
            if txt: events.append({ 'type': 'user', 'text': txt, 'time': j.get('time') })
        elif t == 'assistant/message':
            m = d.get('message') or {}
            txt = text_of(m.get('content'))
            ntc = sum(1 for p in (m.get('content') or []) if isinstance(p, dict) and p.get('type') == 'tool-call')
            if txt or ntc: events.append({ 'type': 'assistant', 'text': txt, 'toolCalls': ntc, 'time': j.get('time') })
        elif t == 'tool/call':
            args = str(d.get('arguments') or '')[:160]
            events.append({ 'type': 'tool-call', 'name': d.get('name'), 'args': args, 'time': j.get('time') })
        elif t == 'tool/result':
            m = d.get('message') or {}
            txt = text_of(m.get('content'))[:400]
            events.append({ 'type': 'tool-result', 'text': txt, 'time': j.get('time') })
    # 展示轨 = 末尾 tail 条；上下文轨取 8×tail 窗口（自主长链单轮数百工具事件——
    # 2×tail 窗口实测仍会全 assistant，归一化 pop 光变 0 条；8× 后稳定覆盖最近 user 轮）
    ctx_events = events[-(tail * 8):]
    events = events[-tail:]
    # LLM 上下文轨归一化：合并连续同角色 + 首条必须 user——上游对非交替/assistant 开头
    # 的消息序列在 stream:true 下会静默回空（实测 26 条原始轨 0 data 行，归一化 6 条 906 行）
    messages = []
    for e in ctx_events:
        if e['type'] not in ('user', 'assistant') or not e.get('text'): continue
        role = 'user' if e['type'] == 'user' else 'assistant'
        if messages and messages[-1]['role'] == role:
            messages[-1]['content'] += '\n' + e['text']
        else:
            messages.append({ 'role': role, 'content': e['text'] })
    while messages and messages[0]['role'] != 'user': messages.pop(0)
    if len(messages) > 24: messages = messages[-24:]  # 截尾限窗——保最近 24 条（控 prompt 体量/时延）
    while messages and messages[0]['role'] != 'user': messages.pop(0)  # 截尾后再保首条 user
    with open(out, 'w', encoding='utf-8') as f:
        json.dump({ 'meta': meta, 'events': events, 'messages': messages }, f, ensure_ascii=False)
    print('export: %s events=%d messages=%d -> %s' % (meta.get('id'), len(events), len(messages), out))

if __name__ == '__main__':
    main()
