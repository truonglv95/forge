#!/usr/bin/env python3
"""Forge live/deterministic agent reliability benchmark."""

import argparse
import datetime
import json
import math
import pathlib
import shutil
import subprocess
import tempfile
import time


def run(command, cwd=None):
    started = time.perf_counter()
    completed = subprocess.run(command, cwd=cwd, text=True, capture_output=True)
    return completed, round((time.perf_counter() - started) * 1000, 2)


def last_json(stdout):
    for line in reversed(stdout.splitlines()):
        try:
            return json.loads(line)
        except json.JSONDecodeError:
            continue
    raise ValueError("command produced no JSON object")


def score_postcondition(workspace, expected):
    if expected.get("proposal_only"):
        return True, "proposal contract satisfied"
    target = pathlib.Path(workspace, expected["path"])
    if not target.is_file():
        return False, f'missing expected file {expected["path"]}'
    content = target.read_text(errors="replace")
    needle = expected.get("contains")
    if needle and needle not in content:
        return False, f'expected content not found in {expected["path"]}'
    return True, "postcondition satisfied"


def evaluate_once(args, task, repetition):
    workspace = tempfile.mkdtemp(prefix="forge-reliability-")
    try:
        for relative, content in task.get("workspace_files", {}).items():
            target = pathlib.Path(workspace, relative)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(content)

        command = [
            args.forge,
            "agent",
            "run",
            task["intent"],
            "--workspace",
            workspace,
            "--provider",
            args.provider,
            "--max-steps",
            str(args.max_steps),
            "--json",
            "--quiet",
        ]
        if args.model:
            command.extend(["--model", args.model])
        completed, latency_ms = run(command)
        record = {
            "task_id": task["id"],
            "repetition": repetition,
            "provider": args.provider,
            "model": args.model or "default",
            "latency_ms": latency_ms,
            "command_success": completed.returncode == 0,
            "proposal_valid": False,
            "apply_success": False,
            "validation_pass": False,
            "task_success": False,
            "steps": 0,
            "repair_attempts": 0,
            "reported_tokens": {"prompt": 0, "completion": 0, "total": 0},
            "reason": "agent command failed",
        }
        if completed.returncode != 0:
            record["stderr"] = completed.stderr[-1000:]
            return record

        event = last_json(completed.stdout)
        record["steps"] = event.get("steps", 0)
        record["repair_attempts"] = event.get("repair_attempts", 0)
        record["reported_tokens"] = event.get("reported_tokens", record["reported_tokens"])
        proposal_rel = event.get("proposal_path", "")
        proposal_path = pathlib.Path(workspace, proposal_rel)
        try:
            proposal = json.loads(proposal_path.read_text())
            record["proposal_valid"] = bool(proposal.get("workspace_edit", {}).get("files"))
        except (OSError, json.JSONDecodeError):
            record["reason"] = "proposal missing or malformed"
            return record

        expected = task.get("expect", {})
        if record["steps"] < expected.get("min_steps", 0):
            record["reason"] = "insufficient tool exploration"
            return record

        if expected.get("proposal_only"):
            record["apply_success"] = True
            record["validation_pass"] = True
            record["reason"] = "proposal contract satisfied"
        else:
            applied, _ = run([
                args.forge,
                "apply",
                proposal_rel,
                "--workspace",
                workspace,
                "--yes",
                "--json",
                "--quiet",
            ])
            record["apply_success"] = applied.returncode == 0
            if not record["apply_success"]:
                record["reason"] = "proposal failed transaction apply"
                return record
            # Validation here is the deterministic postcondition oracle. Model-
            # supplied commands are separately exercised by isolated repair.
            record["validation_pass"], record["reason"] = score_postcondition(workspace, expected)

        record["task_success"] = all([
            record["command_success"],
            record["proposal_valid"],
            record["apply_success"],
            record["validation_pass"],
        ])
        return record
    except Exception as error:  # benchmark must record failures, not abort corpus
        return {
            "task_id": task["id"],
            "repetition": repetition,
            "provider": args.provider,
            "model": args.model or "default",
            "command_success": False,
            "task_success": False,
            "reason": f"evaluator error: {error}",
        }
    finally:
        shutil.rmtree(workspace, ignore_errors=True)


def percentile(values, fraction):
    if not values:
        return 0
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, max(0, math.ceil(len(ordered) * fraction) - 1))]


def main():
    root = pathlib.Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser()
    parser.add_argument("--forge", default=str(root / "zig-out/bin/forge"))
    parser.add_argument("--corpus", default=str(root / "fixtures/eval/agent_reliability.json"))
    parser.add_argument("--provider", default="fake", choices=["fake", "gemini", "ollama"])
    parser.add_argument("--model")
    parser.add_argument("--repeat", type=int, default=1)
    parser.add_argument("--max-steps", type=int, default=8)
    parser.add_argument("--output", default=str(root / ".forge/evals/latest.jsonl"))
    parser.add_argument("--min-success-rate", type=float, default=0.0)
    parser.add_argument("--baseline", help="Previous .summary.json to compare")
    parser.add_argument("--max-success-regression", type=float, default=0.0)
    args = parser.parse_args()

    forge = pathlib.Path(args.forge)
    if not forge.is_file():
        subprocess.check_call(["zig", "build"], cwd=root)
    tasks = json.loads(pathlib.Path(args.corpus).read_text())
    records = [
        evaluate_once(args, task, repetition)
        for repetition in range(1, args.repeat + 1)
        for task in tasks
    ]

    output = pathlib.Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("".join(json.dumps(item, sort_keys=True) + "\n" for item in records))

    successes = sum(bool(item.get("task_success")) for item in records)
    latencies = [item["latency_ms"] for item in records if "latency_ms" in item]
    token_totals = [item.get("reported_tokens", {}).get("total", 0) for item in records]
    summary = {
        "schema_version": 1,
        "generated_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "provider": args.provider,
        "model": args.model or "default",
        "tasks": len(records),
        "successes": successes,
        "success_rate": round(successes / len(records), 4) if records else 0,
        "proposal_valid_rate": round(sum(bool(x.get("proposal_valid")) for x in records) / len(records), 4) if records else 0,
        "validation_pass_rate": round(sum(bool(x.get("validation_pass")) for x in records) / len(records), 4) if records else 0,
        "average_steps": round(sum(x.get("steps", 0) for x in records) / len(records), 2) if records else 0,
        "average_repairs": round(sum(x.get("repair_attempts", 0) for x in records) / len(records), 2) if records else 0,
        "reported_tokens_total": sum(token_totals),
        "latency_ms_p50": percentile(latencies, 0.50),
        "latency_ms_p95": percentile(latencies, 0.95),
        "results_jsonl": str(output),
    }
    try:
        summary["git_commit"] = subprocess.check_output(
            ["git", "rev-parse", "--short", "HEAD"], cwd=root, text=True
        ).strip()
    except subprocess.SubprocessError:
        summary["git_commit"] = "unknown"

    regression_ok = True
    if args.baseline:
        baseline = json.loads(pathlib.Path(args.baseline).read_text())
        delta = round(summary["success_rate"] - baseline.get("success_rate", 0), 4)
        summary["baseline"] = str(pathlib.Path(args.baseline))
        summary["success_rate_delta"] = delta
        regression_ok = delta >= -args.max_success_regression
    summary_path = output.with_suffix(".summary.json")
    summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
    print(json.dumps(summary, sort_keys=True))
    raise SystemExit(0 if summary["success_rate"] >= args.min_success_rate and regression_ok else 2)


if __name__ == "__main__":
    main()
