#!/usr/bin/env python3
"""Forge inline completion latency benchmark.

Measures p50/p95 latency and acceptance rate of `forge complete` across
a corpus of realistic coding contexts. Mirrors the eval methodology in
docs/evaluation/AI_WORKFLOW_EVALUATION.md section 3.8.

Usage:
    python3 scripts/eval_inline_completion.py --forge ./zig-out/bin/forge
    python3 scripts/eval_inline_completion.py --provider fake --iterations 20

Exit codes:
    0 — all iterations succeeded, targets met
    1 — one or more iterations failed
    2 — benchmark targets NOT met (p50 > 500ms or p95 > 1500ms or accept < 20%)
"""

import argparse
import json
import os
import pathlib
import statistics
import subprocess
import sys
import tempfile
import time


# Realistic completion scenarios — each is a partial code file with a
# cursor position where a completion should be requested. The "expected"
# field is a substring that should appear in a good completion.
SCENARIOS = [
    {
        "id": "zig-fn-body",
        "filename": "sample.zig",
        "content": "pub fn add(a: i32, b: i32) i32 {\n    ",
        "line": 2,
        "char": 4,
        "expected_contains": "return",
    },
    {
        "id": "python-class-method",
        "filename": "model.py",
        "content": "class User:\n    def __init__(self, name, email):\n        self.name = name\n        ",
        "line": 4,
        "char": 8,
        "expected_contains": "self",
    },
    {
        "id": "ts-react-component",
        "filename": "Button.tsx",
        "content": "export function Button({ label, onClick }: Props) {\n  return (\n    ",
        "line": 3,
        "char": 4,
        "expected_contains": "button",
    },
    {
        "id": "rust-impl-block",
        "filename": "stack.rs",
        "content": "impl Stack {\n    pub fn push(&mut self, item: T) {\n        ",
        "line": 3,
        "char": 8,
        "expected_contains": "self",
    },
    {
        "id": "go-handler",
        "filename": "main.go",
        "content": "func handleHealth(w http.ResponseWriter, r *http.Request) {\n    ",
        "line": 2,
        "char": 4,
        "expected_contains": "w",
    },
    {
        "id": "json-config",
        "filename": "config.json",
        "content": '{\n  "name": "forge",\n  "version": "0.1.0",\n  ',
        "line": 4,
        "char": 2,
        "expected_contains": '"',
    },
]


def run_forge_complete(forge_bin, workspace, scenario, provider, model, timeout_s):
    """Run `forge complete` for a single scenario, return (latency_ms, completion_text, ok)."""
    file_path = pathlib.Path(workspace, scenario["filename"])
    file_path.parent.mkdir(parents=True, exist_ok=True)
    file_path.write_text(scenario["content"])

    cmd = [
        forge_bin,
        "complete",
        "--file", scenario["filename"],
        "--line", str(scenario["line"]),
        "--char", str(scenario["char"]),
        "--provider", provider,
        "--workspace", workspace,
        "--json",
        "--quiet",
    ]
    if model:
        cmd.extend(["--model", model])

    started = time.perf_counter()
    try:
        completed = subprocess.run(
            cmd,
            cwd=workspace,
            text=True,
            capture_output=True,
            timeout=timeout_s,
        )
        latency_ms = round((time.perf_counter() - started) * 1000, 2)
    except subprocess.TimeoutExpired:
        return round(timeout_s * 1000, 2), "", False, "timeout"

    if completed.returncode != 0:
        return latency_ms, "", False, f"exit={completed.returncode} stderr={completed.stderr[:200]}"

    # Parse JSON from stdout (last line)
    text = ""
    parse_err = ""
    for line in reversed(completed.stdout.splitlines()):
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
            text = obj.get("completion", obj.get("text", ""))
            if not text and "error" in obj:
                return latency_ms, "", False, f"error={obj['error']}"
            break
        except json.JSONDecodeError:
            continue

    if not text:
        parse_err = "no completion in output"
        return latency_ms, "", False, parse_err

    # Check acceptance: does the completion contain the expected substring?
    expected = scenario.get("expected_contains", "")
    accepted = bool(expected) and expected.lower() in text.lower()
    return latency_ms, text, True, "ok" if accepted else f"missing '{expected}'"


def percentile(values, pct):
    """Compute the pct-th percentile (0-100) of a list."""
    if not values:
        return 0.0
    sorted_vals = sorted(values)
    k = (len(sorted_vals) - 1) * (pct / 100.0)
    f = int(k)
    c = min(f + 1, len(sorted_vals) - 1)
    if f == c:
        return sorted_vals[f]
    return sorted_vals[f] + (sorted_vals[c] - sorted_vals[f]) * (k - f)


def main():
    parser = argparse.ArgumentParser(description="Forge inline completion latency benchmark")
    parser.add_argument("--forge", default="./zig-out/bin/forge", help="Path to forge binary")
    parser.add_argument("--provider", default="fake", help="Provider name (fake/openai/gemini/ollama/anthropic)")
    parser.add_argument("--model", default="", help="Model name (empty = provider default)")
    parser.add_argument("--iterations", type=int, default=10, help="Iterations per scenario")
    parser.add_argument("--timeout", type=int, default=30, help="Timeout per iteration (seconds)")
    parser.add_argument("--p50-target-ms", type=int, default=500, help="p50 target (ms)")
    parser.add_argument("--p95-target-ms", type=int, default=1500, help="p95 target (ms)")
    parser.add_argument("--accept-target-pct", type=int, default=20, help="Acceptance rate target (%%)")
    parser.add_argument("--json", action="store_true", help="Output JSON report")
    args = parser.parse_args()

    forge_bin = args.forge
    if not pathlib.Path(forge_bin).is_file():
        # Try resolving from forge-ide path
        alt = forge_bin.replace("/forge", "/forge-ide")
        if pathlib.Path(alt).is_file():
            forge_bin = alt
        else:
            print(f"error: forge binary not found at {args.forge}", file=sys.stderr)
            return 2

    all_latencies = []
    all_accepted = []
    per_scenario = []

    for scenario in SCENARIOS:
        scenario_latencies = []
        scenario_accepted = 0
        scenario_errors = []

        for i in range(args.iterations):
            with tempfile.TemporaryDirectory(prefix="forge-complete-") as workspace:
                latency, text, ok, msg = run_forge_complete(
                    forge_bin, workspace, scenario, args.provider, args.model, args.timeout
                )
                scenario_latencies.append(latency)
                all_latencies.append(latency)
                if ok and "ok" in msg:
                    scenario_accepted += 1
                    all_accepted.append(True)
                else:
                    all_accepted.append(False)
                    scenario_errors.append(msg)

        per_scenario.append({
            "id": scenario["id"],
            "iterations": args.iterations,
            "p50_ms": round(percentile(scenario_latencies, 50), 2),
            "p95_ms": round(percentile(scenario_latencies, 95), 2),
            "mean_ms": round(statistics.mean(scenario_latencies), 2),
            "min_ms": round(min(scenario_latencies), 2),
            "max_ms": round(max(scenario_latencies), 2),
            "accepted": scenario_accepted,
            "accept_pct": round(scenario_accepted / args.iterations * 100, 1),
            "errors": scenario_errors[:3],  # First 3 errors only
        })

    p50 = percentile(all_latencies, 50)
    p95 = percentile(all_latencies, 95)
    accept_pct = round(sum(all_accepted) / len(all_accepted) * 100, 1) if all_accepted else 0.0

    report = {
        "provider": args.provider,
        "model": args.model or "default",
        "total_iterations": len(all_latencies),
        "p50_ms": round(p50, 2),
        "p95_ms": round(p95, 2),
        "mean_ms": round(statistics.mean(all_latencies), 2),
        "accept_pct": accept_pct,
        "targets": {
            "p50_ms": args.p50_target_ms,
            "p95_ms": args.p95_target_ms,
            "accept_pct": args.accept_target_pct,
        },
        "targets_met": (
            p50 <= args.p50_target_ms
            and p95 <= args.p95_target_ms
            and accept_pct >= args.accept_target_pct
        ),
        "per_scenario": per_scenario,
    }

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"\n=== Inline Completion Latency Benchmark ===")
        print(f"Provider: {args.provider} | Model: {args.model or 'default'}")
        print(f"Iterations: {len(all_latencies)} ({len(SCENARIOS)} scenarios x {args.iterations})")
        print(f"")
        print(f"  p50 latency: {p50:.2f} ms  (target <= {args.p50_target_ms} ms)")
        print(f"  p95 latency: {p95:.2f} ms  (target <= {args.p95_target_ms} ms)")
        print(f"  mean latency: {statistics.mean(all_latencies):.2f} ms")
        print(f"  acceptance rate: {accept_pct:.1f}%  (target >= {args.accept_target_pct}%)")
        print(f"")
        print(f"  Per-scenario:")
        for s in per_scenario:
            status = "OK" if s["accept_pct"] >= args.accept_target_pct else "FAIL"
            print(f"    [{status}] {s['id']:<25} p50={s['p50_ms']:>7.2f}ms p95={s['p95_ms']:>7.2f}ms accept={s['accept_pct']:>5.1f}%")
            if s["errors"]:
                print(f"          errors: {s['errors'][0]}")
        print(f"")
        print(f"  Targets {'MET' if report['targets_met'] else 'NOT MET'}")
        print(f"")

    return 0 if report["targets_met"] else 2


if __name__ == "__main__":
    sys.exit(main())
