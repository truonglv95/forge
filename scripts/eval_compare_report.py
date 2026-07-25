#!/usr/bin/env python3
"""Merge per-provider eval summaries into a single comparison report.

Reads N `*.summary.json` files (one per provider), writes a combined
JSON, and prints a formatted table to stdout with:
  provider | model | tasks | success | p50 ms | p95 ms | tokens | cost $

The `--baseline-name` provider (default: fake) is highlighted as the
deterministic baseline so callers can see regression vs. baseline.
"""

import argparse
import datetime
import json
import pathlib
import sys


def load_summary(path):
    try:
        return json.loads(pathlib.Path(path).read_text())
    except (OSError, json.JSONDecodeError) as exc:
        return {"_error": str(exc), "_path": str(path)}


def format_tokens(n):
    if n is None:
        return "-"
    if n < 1000:
        return f"{n}"
    if n < 1_000_000:
        return f"{n/1000:.1f}K"
    return f"{n/1_000_000:.2f}M"


def format_cost(summary, provider):
    """Estimate cost using the same pricing table as the Zig usage_tracker."""
    pricing = {
        ("gemini", "gemini-2.0-flash"): (0.10, 0.40),
        ("gemini", "gemini-1.5-flash"): (0.075, 0.30),
        ("gemini", "gemini-1.5-pro"): (1.25, 5.00),
        ("gemini", "gemini-2.5-pro"): (1.25, 5.00),
        ("gemini", "_default"): (0.50, 1.50),
        ("openai", "gpt-4o-mini"): (0.150, 0.600),
        ("openai", "gpt-4o"): (2.50, 10.00),
        ("openai", "gpt-4-turbo"): (10.00, 30.00),
        ("openai", "_default"): (1.00, 3.00),
        ("anthropic", "_default"): (3.00, 15.00),
        ("openrouter", "_default"): (1.00, 3.00),
        ("nvidia", "_default"): (0.50, 1.50),
        ("ollama", "_default"): (0.0, 0.0),
        ("fake", "_default"): (0.0, 0.0),
    }
    model = summary.get("model", "default")
    provider_lower = provider.lower()
    key = (provider_lower, model.lower())
    in_per_1k, out_per_1k = pricing.get(key) or pricing.get(
        (provider_lower, "_default"), (0.0, 0.0)
    )
    # We don't have prompt/completion split in the summary, so estimate
    # using a 4:1 ratio (prompt:completion) as a rough heuristic.
    total = summary.get("reported_tokens_total", 0)
    if total == 0:
        return "$0.00"
    prompt = total * 0.8
    completion = total * 0.2
    cost = (prompt / 1000.0) * in_per_1k + (completion / 1000.0) * out_per_1k
    return f"${cost:.4f}"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--timestamp", required=True)
    parser.add_argument("--outdir", required=True)
    parser.add_argument("--baseline-name", default="fake")
    parser.add_argument("--summary", action="append", default=[])
    args = parser.parse_args()

    summaries = []
    for path in args.summary:
        s = load_summary(path)
        if "_error" not in s:
            summaries.append(s)
        else:
            print(f"WARNING: could not load {path}: {s['_error']}", file=sys.stderr)

    if not summaries:
        print("ERROR: no valid summaries to compare", file=sys.stderr)
        return 2

    # Sort: baseline first, then by success_rate desc.
    def sort_key(s):
        provider = s.get("provider", "")
        is_baseline = 0 if provider == args.baseline_name else 1
        return (is_baseline, -s.get("success_rate", 0))

    summaries.sort(key=sort_key)

    # Write combined JSON.
    combined = {
        "schema_version": 2,
        "generated_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "timestamp": args.timestamp,
        "baseline": args.baseline_name,
        "providers": summaries,
    }
    combined_path = pathlib.Path(args.outdir) / f"compare-{args.timestamp}.json"
    combined_path.write_text(json.dumps(combined, indent=2, sort_keys=True) + "\n")

    # Print comparison table.
    print()
    print(f"  Forge AI Provider Comparison — {args.timestamp}")
    print(f"  Corpus: agent_reliability.json ({summaries[0].get('tasks', '?')} tasks)")
    print()
    # Header
    print(f"  {'Provider':<12} {'Model':<24} {'Success':>8} {'p50ms':>8} {'p95ms':>8} {'Tokens':>10} {'Est.Cost':>10}")
    print(f"  {'-' * 12} {'-' * 24} {'-' * 8} {'-' * 8} {'-' * 8} {'-' * 10} {'-' * 10}")
    for s in summaries:
        provider = s.get("provider", "?")
        model = s.get("model", "?") or "default"
        if len(model) > 24:
            model = model[:21] + "..."
        success = s.get("success_rate", 0)
        p50 = s.get("latency_ms_p50", 0)
        p95 = s.get("latency_ms_p95", 0)
        tokens = s.get("reported_tokens_total", 0)
        cost = format_cost(s, provider)
        marker = " *" if provider == args.baseline_name else "  "
        print(
            f"{marker}{provider:<12} {model:<24} {success*100:>7.1f}% {p50:>8.1f} {p95:>8.1f} {format_tokens(tokens):>10} {cost:>10}"
        )
    print()
    print(f"  * = baseline ({args.baseline_name})")
    print(f"  Combined report: {combined_path}")
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
