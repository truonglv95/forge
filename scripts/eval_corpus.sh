#!/usr/bin/env bash
# Runs declarative checks from fixtures/eval/tasks/corpus.json
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FORGE="${FORGE:-$ROOT/zig-out/bin/forge}"
CORPUS="$ROOT/fixtures/eval/tasks/corpus.json"

python3 - "$FORGE" "$CORPUS" <<'PY'
import json, subprocess, sys, tempfile, shutil, os

forge, corpus_path = sys.argv[1], sys.argv[2]
with open(corpus_path) as f:
    tasks = json.load(f)

passed = 0
for task in tasks:
    tid = task["id"]
    kind = task.get("kind", "unknown")
    print(f"== corpus: {tid} ({kind}) ==")

    if kind == "context_safety":
        ws = tempfile.mkdtemp(prefix="forge-eval-")
        try:
            if task.get("setup"):
                subprocess.check_call(task["setup"], shell=True, cwd=ws)
            if task["file"] == ".env":
                open(os.path.join(ws, ".env"), "w").write("API_KEY=secret\n")
            elif task["file"] == "leak.zig":
                open(os.path.join(ws, "leak.zig"), "w").write('const key = "sk-test123456789";\n')
            elif task["file"] == "ghp.zig":
                open(os.path.join(ws, "ghp.zig"), "w").write('const t = "ghp_abc12345678901234567890123456789012";\n')
            elif task["file"] == "key.pem":
                open(os.path.join(ws, "key.pem"), "w").write("-----BEGIN PRIVATE KEY-----\n")
            elif task["file"] == "credentials.json":
                open(os.path.join(ws, "credentials.json"), "w").write("{}\n")
            args = [forge, "context", task.get("intent", "review"), "--file", task["file"], "--workspace", ws, "--json", "--quiet"]
            out = subprocess.check_output(args, text=True)
            if task.get("expect_included") is False:
                needle = f'"name":"{task["file"]}"'
                if needle in out and '"included":true' in out.split(needle, 1)[1][:120]:
                    raise SystemExit(f"FAIL {tid}: file should be excluded")
        finally:
            shutil.rmtree(ws)
    elif kind == "context_budget":
        ws = tempfile.mkdtemp(prefix="forge-eval-")
        try:
            open(os.path.join(ws, "large.txt"), "w").write("x" * 500 + "\n")
            args = [forge, "context", "review", "--file", "large.txt", "--workspace", ws,
                    "--budget-bytes", str(task["budget_bytes"]), "--json", "--quiet"]
            out = subprocess.check_output(args, text=True)
            if task.get("expect_truncated") and '"truncated":true' not in out:
                raise SystemExit(f"FAIL {tid}: expected truncation")
        finally:
            shutil.rmtree(ws)
    elif kind == "doctor":
        args = [forge, "doctor", "--json", "--quiet"]
        if task.get("expect_ready"):
            out = subprocess.check_output(args, text=True)
            if '"ready":true' not in out:
                raise SystemExit(f"FAIL {tid}: doctor not ready")
    else:
        print(f"  skip (handled by eval.sh): {tid}")
        continue

    passed += 1

print(f"PASS: corpus slice ({passed} tasks)")
PY
