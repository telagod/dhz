#!/usr/bin/env bash
# M-1 内存采样：把 dsh web 宿主进程树与系统内存追加到 probe/memory-series.csv
# 用法: tools/sample-memory.sh [间隔秒] [次数]   （默认 5s x 12）
set -euo pipefail
cd "$(dirname "$0")/.."
INTERVAL="${1:-5}"
COUNT="${2:-12}"
CSV="probe/memory-series.csv"
[ -f "$CSV" ] || printf 'iso_time,host_rss_kb,wrapper_rss_kb,children_total_kb,cpu_pct_sys\n' > "$CSV"
HOST_PID="$(pgrep -f 'node_modules/.bin/dsh web' | head -1 || true)"
WRAPPER_PID="$(pgrep -f 'npm exec @deepseek-ai/dsh web' | head -1 || true)"
if [ -z "$HOST_PID" ]; then echo "dsh web 进程未找到"; exit 1; fi
for i in $(seq 1 "$COUNT"); do
  HOST_RSS=$(grep VmRSS "/proc/$HOST_PID/status" | awk '{print $2}')
  WRAP_RSS=$(grep VmRSS "/proc/$WRAPPER_PID/status" 2>/dev/null | awk '{print $2}' || echo 0)
  CHILD_RSS=$(ps --ppid "$HOST_PID" -o rss= 2>/dev/null | awk '{s+=$1} END{print s+0}')
  printf '%s,%s,%s,%s\n' "$(date -Iseconds)" "${HOST_RSS:-0}" "${WRAP_RSS:-0}" "${CHILD_RSS:-0}" >> "$CSV"
  sleep "$INTERVAL"
done
echo "appended: $CSV (last line: $(tail -1 "$CSV"))"