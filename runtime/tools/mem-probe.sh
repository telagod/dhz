#!/bin/bash
# 峰值 RSS 探针（对照 M-1 Node 基线：宿主 ~285MB + npm 包装 55.6MB + 会话 366MB）
# ReleaseFast 产物测量：先 `zig build -Doptimize=ReleaseFast <target>` 再跑本脚本
# 用法: tools/mem-probe.sh [目标名...]（默认关键 5 项）
set -e
cd "$(dirname "$0")/.."
if [ "$#" -eq 0 ]; then
  set -- cordis-services-smoke boot-smoke event-loop-smoke host-services-smoke proc-smoke
fi
for t in "$@"; do
  BIN=$(find .zig-cache -name "$t" -type f -printf "%T@\t%p\n" 2>/dev/null | sort -rn | head -1 | cut -f2)
  if [ -z "$BIN" ]; then echo "$t: no binary"; continue; fi
  SIZE=$(stat -c%s "$BIN" 2>/dev/null || echo "?")
  RSS=$(/usr/bin/time -v "$BIN" 2>&1 | grep "Maximum resident" | awk '{print $NF}')
  echo "$t: size=${SIZE}B peakRSS=${RSS}kB"
done
