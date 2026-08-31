#!/bin/bash
# Reproducible performance baseline for exact Debug/ReleaseFast artifacts.
set -euo pipefail
cd "$(dirname "$0")/.."
ZIG="${ZIG:-/home/dapao/zig/zig-x86_64-linux-0.16.0/zig}"
TMPDIR_PERF=$(mktemp -d "${TMPDIR:-/tmp}/dsh-perf.XXXXXX")
REPORT="${DSH_PERF_REPORT:-out/perf-report.json}"
trap 'rm -rf "$TMPDIR_PERF"' EXIT

build_bin() {
  local optimize name step log bin
  optimize="$1"
  name="$2"
  step="$3"
  log="$TMPDIR_PERF/build-${optimize}-${name}.log"
  "$ZIG" build -Doptimize="$optimize" --verbose "$step" >"$log" 2>&1
  bin=$(grep -aE "^([.]?/)?[.]zig-cache/.*/${name}$" "$log" | tail -1 || true)
  if [[ -z "$bin" || ! -x "$bin" ]]; then
    echo "perf: could not identify ${optimize} ${name}" >&2
    tail -20 "$log" >&2
    return 1
  fi
  printf '%s\n' "$bin"
}

measure() {
  local mode="$1" optimize="$2" name="$3" step="$4" bin="$5"
  local log="$TMPDIR_PERF/run-${mode}.log" metrics elapsed rss size stripped_size
  /usr/bin/time -f '__DSH_PERF__ %e %M' "$bin" > /dev/null 2>"$log"
  metrics=$(grep -a '__DSH_PERF__' "$log" | tail -1)
  elapsed=$(awk '{print $2}' <<<"$metrics")
  rss=$(awk '{print $3}' <<<"$metrics")
  size=$(stat -c%s "$bin")
  stripped_size="$size"
  if [[ "$optimize" == "ReleaseFast" ]]; then
    local stripped="$TMPDIR_PERF/stripped-${mode}-${name}"
    cp "$bin" "$stripped"
    strip --strip-all "$stripped"
    stripped_size=$(stat -c%s "$stripped")
  fi
  printf '%-12s %-10s %-22s start=%ss peakRSS=%skB bin=%dB stripped=%dB\n' "$mode" "$optimize" "$name" "$elapsed" "$rss" "$size" "$stripped_size"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$mode" "$optimize" "$name" "$elapsed" "$rss" "$size" "$stripped_size" >>"$TMPDIR_PERF/results.tsv"
}

echo "== performance baseline (exact artifacts; Node reference 285MB) =="
debug_boot=$(build_bin Debug boot-smoke boot-smoke-run)
release_boot=$(build_bin ReleaseFast boot-smoke boot-smoke-run)
release_services=$(build_bin ReleaseFast cordis-services-smoke cordis-services-smoke-run)
measure debug Debug boot-smoke boot-smoke-run "$debug_boot"
measure release ReleaseFast boot-smoke boot-smoke-run "$release_boot"
measure services ReleaseFast cordis-services-smoke cordis-services-smoke-run "$release_services"
# engine-ready 口径：进程起点 → entry import 落定（boot-smoke 打点）。
# 与 releaseFullStartup（smoke 全链路墙钟，含编排等待）分开门禁。
engine_ready_ms=$(grep -aoE 'engineReadyMs=[0-9]+' "$TMPDIR_PERF/run-release.log" | tail -1 | cut -d= -f2 || true)
if [[ -n "$engine_ready_ms" ]]; then
  printf '%-12s %-10s %-22s engineReady=%sms
' release ReleaseFast boot-smoke "$engine_ready_ms"
else
  echo "perf: engineReadyMs marker missing in release boot-smoke log" >&2
fi
mkdir -p "$(dirname "$REPORT")"
ENGINE_READY_MS="$engine_ready_ms" python3 - "$REPORT" "$TMPDIR_PERF/results.tsv" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

report_path = Path(sys.argv[1])
rows = []
for line in Path(sys.argv[2]).read_text(encoding="utf-8").splitlines():
    mode, optimize, name, elapsed, rss, size, stripped_size = line.split("\t")
    rows.append({
        "mode": mode,
        "optimize": optimize,
        "target": name,
        "startSeconds": float(elapsed),
        "peakRssKb": int(rss),
        "binaryBytes": int(size),
        "strippedBinaryBytes": int(stripped_size),
    })
release_full = next(row for row in rows if row["mode"] == "release" and row["target"] == "boot-smoke")
engine_ready_raw = os.environ.get("ENGINE_READY_MS", "")
engine_ready_ms = int(engine_ready_raw) if engine_ready_raw.isdigit() else None
checks = {
    "releaseFullPeakRss": {
        "limitKb": 256 * 1024,
        "actualKb": release_full["peakRssKb"],
        "status": "passed" if release_full["peakRssKb"] < 256 * 1024 else "failed",
    },
    "releaseFullStartup": {
        "limitSeconds": 10.0,
        "actualSeconds": release_full["startSeconds"],
        "status": "passed" if release_full["startSeconds"] < 10.0 else "failed",
    },
    "releaseEngineReady": {
        "limitMs": 500,
        "actualMs": engine_ready_ms,
        "status": "passed" if engine_ready_ms is not None and engine_ready_ms < 500 else "failed",
    },
}
report = {
    "schema": "dsh.performance-report/v1",
    "generatedAt": datetime.now(timezone.utc).isoformat(),
    "runtime": "dsh-zig-runtime",
    "status": "passed" if all(check["status"] == "passed" for check in checks.values()) else "failed",
    "checks": checks,
    "results": rows,
    "notes": [
        "Artifacts are resolved from the exact --verbose Zig build output.",
        "Debug is diagnostic only; ReleaseFast is the product baseline.",
        "releaseFullStartup is smoke-orchestration wall time (deliberate probe waits); releaseEngineReady is the product boot caliber (process start to entry import settled).",
    ],
    "host": {"system": os.uname().sysname, "machine": os.uname().machine},
}
report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
print(f"performance-report: {report['status']} wrote {report_path}")
PY
echo "== done =="
