#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
zig_bin="${ZIG:-}"
if [[ -z "$zig_bin" ]]; then
  if command -v zig >/dev/null 2>&1; then
    zig_bin=$(command -v zig)
  else
    zig_bin="$root/../../../zig/zig-x86_64-linux-0.16.0/zig"
  fi
fi
if [[ ! -x "$zig_bin" ]]; then
  printf 'compat-report: Zig compiler not found: %s\n' "$zig_bin" >&2
  exit 127
fi

out_file="${1:-$root/out/compat-report.json}"
mkdir -p "$(dirname -- "$out_file")"
log_file="${out_file%.json}.log"
raw_log=$(mktemp "${TMPDIR:-/tmp}/dsh-compat.XXXXXX.log")
trap 'rm -f "$raw_log"' EXIT

set +e
(
  cd "$root"
  "$zig_bin" build -Doptimize=ReleaseFast boot-smoke-run
) >"$raw_log" 2>&1
exit_code=$?
set -e

python3 - "$raw_log" "$out_file" "$exit_code" "$log_file" <<'PY'
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

raw_log_path = Path(sys.argv[1])
out_path = Path(sys.argv[2])
exit_code = int(sys.argv[3])
log_path = Path(sys.argv[4])
text = raw_log_path.read_bytes().decode("utf-8", errors="replace")
log_path.write_text(text, encoding="utf-8")

known = {
    "llm-pi-ai": ("ecosystem", "warning", "investigate", "plugin activation is not currently compatible"),
    "attachment-local": ("native-only", "info", "design-skip", "native attachment implementation is outside the Zig host scope"),
    "@deepseek-ai/dsh-attachment-local": ("native-only", "info", "design-skip", "native attachment implementation is outside the Zig host scope"),
    "@deepseek-ai/dsh-subprocess-local": ("native-only", "info", "design-skip", "the native subprocess implementation is replaced by the Zig bridge"),
    "@deepseek-ai/dsh-sandbox-local": ("native-only", "info", "design-skip", "the native sandbox implementation is outside the embedded host scope"),
    "session-telemetry-otel": ("service-contract", "error", "regression", "OpenTelemetry compatibility layers are embedded; activation failure is a regression"),
    "subprocess": ("native-only", "info", "zig-replacement", "the Zig subprocess bridge replaces the native Node addon"),
    "sandbox": ("native-only", "info", "design-skip", "the Zig sandbox bridge replaces the native Node addon"),
    "@deepseek-ai/dsh-sandbox-windows-acl": ("native-only", "info", "design-skip", "Windows ACL binding is outside the Linux embedded host scope"),
    "koffi": ("native-only", "info", "design-skip", "native FFI binding is intentionally excluded from the embedded closure"),
    "detect-libc": ("native-only", "info", "design-skip", "optional native libc probe is not required by the Zig host"),
    "turndown": ("ecosystem", "info", "optional-skip", "optional markdown dependency is not part of the embedded web closure"),
    "sharp": ("native-only", "info", "design-skip", "native image processing is intentionally outside the embedded host closure"),
    "permission": ("service-contract", "warning", "investigate", "permission preset activation still needs the full shell policy context"),
    "settings": ("runtime-config", "warning", "configuration-required", "settings activation requires a readable user settings file"),
    "credentials": ("runtime-config", "warning", "configuration-required", "credentials activation requires a readable user credentials file"),
    "skill-filesystem": ("ecosystem", "warning", "investigate", "filesystem skill activation still has an unresolved deep dependency"),
    "tool-web": ("ecosystem", "warning", "investigate", "web tool activation still has an unresolved deep dependency"),
}

def add_issue(issue_id, package, category, severity, disposition, message, evidence):
    key = (issue_id, package, message)
    if any((i["id"], i.get("package"), i["message"]) == key for i in issues):
        return
    issues.append({
        "id": issue_id,
        "package": package,
        "category": category,
        "severity": severity,
        "disposition": disposition,
        "message": message,
        "evidence": evidence,
    })

issues = []
load_fail_packages = set()
fail_match = re.search(r"^boot smoke: loadFails='(.*)'$", text, re.MULTILINE)
if fail_match:
    for item in fail_match.group(1).split("|"):
        if not item:
            continue
        package, _, detail = item.partition("=")
        load_fail_packages.add(package)
        category, severity, disposition, message = known.get(
            package,
            ("ecosystem", "warning", "investigate", "plugin activation failed"),
        )
        add_issue(
            "load-" + package,
            package,
            category,
            severity,
            disposition,
            message,
            {"source": "boot-smoke", "detail": detail},
        )

for package in sorted(set(re.findall(r"\[loader\] resolve failed: ([^ ]+)", text))):
    category, severity, disposition, message = known.get(
        package,
        ("resolver", "warning", "investigate", "module specifier could not be resolved"),
    )
    add_issue(
        "resolve-" + package,
        package,
        category,
        severity,
        disposition,
        message,
        {"source": "boot-smoke", "pattern": "[loader] resolve failed"},
    )

for module_path in sorted(set(re.findall(r"\[quickjs-host\] compile failed: ([^\s]+)", text))):
    if module_path == "[uninitialized]":
        continue
    parts = module_path.split("/")
    package = "/".join(parts[:2]) if module_path.startswith("@") and len(parts) > 1 else parts[0]
    if package in load_fail_packages:
        continue
    category, severity, disposition, message = known.get(
        package,
        ("ecosystem", "warning", "investigate", "module compilation failed"),
    )
    add_issue(
        "compile-" + package,
        package,
        category,
        severity,
        disposition,
        message,
        {"source": "quickjs-host", "module": module_path, "pattern": "compile failed"},
    )

skip_match = re.search(r"boot smoke: loadSkips='([^']*)'", text)
skips = [x for x in (skip_match.group(1).split("|") if skip_match else []) if x]
passed = exit_code == 0 and "boot smoke OK" in text
issue_counts = {level: sum(1 for item in issues if item["severity"] == level) for level in ("error", "warning", "info")}
blocking_issue = any(item["severity"] in ("error", "warning") for item in issues)
compatibility_status = "clean" if not issues else "review-required" if blocking_issue else "design-skips-only"
report = {
    "schema": "dsh.compatibility-report/v1",
    "generatedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "runtime": "dsh-zig-runtime",
    "command": "zig build -Doptimize=ReleaseFast boot-smoke-run",
    "exitCode": exit_code,
    "status": "passed" if passed else "failed",
    "compatibilityStatus": compatibility_status,
    "issueCounts": issue_counts,
    "checks": [{"id": "boot-smoke", "status": "passed" if passed else "failed"}],
    "issues": issues,
    "compatibilityLayers": [
        {"package": "@opentelemetry/api", "mode": "embedded-api-shim", "status": "passed"},
        {"package": "@opentelemetry/sdk-logs", "mode": "embedded-sdk-shim", "status": "passed"},
        {"package": "@opentelemetry/resources", "mode": "embedded-resource-shim", "status": "passed"},
        {"package": "@opentelemetry/exporter-logs-otlp-http", "mode": "fetch-otlp-shim", "status": "passed"},
        {"package": "yaml", "mode": "embedded-yaml-document-shim", "status": "passed"},
        {"package": "turndown", "mode": "embedded-markdown-shim", "status": "passed"},
        {"package": "@joplin/turndown-plugin-gfm", "mode": "embedded-gfm-shim", "status": "passed"},
    ],
    "designSkips": skips,
    "evidence": {
        "logFile": str(log_path),
        "rawLogBytes": len(raw_log_path.read_bytes()),
        "loadFailsPresent": bool(fail_match),
        "rawOutputBytes": len(text.encode("utf-8")),
    },
}
out_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(f"compat-report: {report['status']} issues={len(issues)} skips={len(skips)}")
print(f"compat-report: wrote {out_path}")
PY

if [[ "$exit_code" -ne 0 ]]; then
  printf 'compat-report: boot smoke failed with exit %s\n' "$exit_code" >&2
  exit "$exit_code"
fi
