#!/bin/bash
# DSH Zig 运行时发布管线（最小面）：ReleaseFast 构建 → 产物落位 → golden 校验 → 打包清单。
# 用法: tools/release.sh [outdir]  （默认 out/dsh-zig-runtime/）
set -e
cd "$(dirname "$0")/.."
PATH="/home/dapao/zig/zig-x86_64-linux-0.16.0:$PATH"
OUT="${1:-out/dsh-zig-runtime}"
echo "== 1/4 构建（ReleaseFast）"
build_log=$(mktemp "${TMPDIR:-/tmp}/dsh-release-build.XXXXXX.log")
trap 'rm -f "$build_log"' EXIT
zig build -Doptimize=ReleaseFast --verbose boot-smoke-run >"$build_log" 2>&1
BIN=$(grep -aE '^([.]?/)?[.]zig-cache/.*/boot-smoke$' "$build_log" | tail -1)
if [[ -z "$BIN" || ! -x "$BIN" ]]; then
  echo "release: could not identify ReleaseFast boot-smoke artifact" >&2
  tail -20 "$build_log" >&2
  exit 1
fi
mkdir -p "$OUT"
cp "$BIN" "$OUT/dsh-zig-runtime"
chmod +x "$OUT/dsh-zig-runtime"
# Debug info is useful in .zig-cache, but should not ship in the product artifact.
strip --strip-all "$OUT/dsh-zig-runtime" 2>/dev/null || true
echo "   -> $OUT/dsh-zig-runtime ($(stat -c%s "$OUT/dsh-zig-runtime") bytes, stripped)"
echo "== 2/4 工具件"
mkdir -p "$OUT/tools"
cp tools/llm-mock.py "$OUT/tools/"
cp tools/headless-profile.json "$OUT/tools/" 2>/dev/null || true
mkdir -p "$OUT/golden"
cp golden/headless.txt "$OUT/golden/headless.txt"
# 结构化报告随发布件分发（perf 门限 + 生态兼容证据——发布即自文档化）
if [[ -f out/perf-report.json ]]; then mkdir -p "$OUT/reports"; cp out/perf-report.json "$OUT/reports/"; fi
if [[ -f out/compat-report.json ]]; then mkdir -p "$OUT/reports"; cp out/compat-report.json "$OUT/reports/"; fi
echo "== 3/4 黄金校验（headless 全链）"
(cd "$OUT" && ./dsh-zig-runtime headless --profile tools/headless-profile.json > /tmp/release_h.log 2>&1) || { echo "RELEASE CHECK FAIL"; tail -5 /tmp/release_h.log; exit 1; }
grep -q "golden match" /tmp/release_h.log || { echo "RELEASE GOLDEN MISS"; exit 1; }
echo "   golden match OK"
echo "== 4/4 清单"
cat > "$OUT/MANIFEST.txt" << MANI
dsh-zig-runtime  $(stat -c%s "$OUT/dsh-zig-runtime")  $(sha256sum "$OUT/dsh-zig-runtime" | cut -d' ' -f1)
tools/llm-mock.py (运行时 mock——dev/录播)
golden-headless.txt (headless 黄金基线)
MANI
cat "$OUT/MANIFEST.txt"
echo "== 发布完成: $OUT"
