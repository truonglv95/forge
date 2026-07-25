#!/usr/bin/env python3
"""Benchmark suite for Forge IDE rendering performance.

Measures frame time, text rendering speed, SVG icon rendering speed,
and overall FPS under various workloads.

Usage:
    python3 scripts/benchmark_render.py [--frames N] [--output PATH]
"""

import argparse
import json
import os
import subprocess
import sys
import time
import statistics

def run_xvfb():
    """Start Xvfb on a free display."""
    display = 99
    proc = subprocess.Popen(
        ["Xvfb", f":{display}", "-screen", "0", "1280x800x24", "-nolisten", "tcp"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    time.sleep(2)
    return display, proc


def run_ide(display, workspace, ide_path, duration=10):
    """Run forge-ide for a duration and capture stderr (perf logs)."""
    env = os.environ.copy()
    env["DISPLAY"] = f":{display}"

    proc = subprocess.Popen(
        [ide_path, workspace],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
    )

    time.sleep(duration)

    proc.terminate()
    try:
        proc.wait(timeout=3)
    except subprocess.TimeoutExpired:
        proc.kill()

    stdout, stderr = proc.communicate()
    return stdout.decode("utf-8", errors="replace"), stderr.decode("utf-8", errors="replace")


def parse_perf_logs(stderr):
    """Parse [perf] lines from stderr."""
    frames = []
    for line in stderr.split("\n"):
        if "[perf]" in line:
            # Example: [perf] slow frame: 20ms (tick=2ms layout=1ms)
            parts = line.split()
            try:
                frame_ms = int(parts[3].replace("ms", ""))
                tick_ms = int(parts[4].split("=")[1].replace("ms", ""))
                layout_ms = int(parts[5].split("=")[1].replace("ms", ""))
                frames.append({
                    "total_ms": frame_ms,
                    "tick_ms": tick_ms,
                    "layout_ms": layout_ms,
                })
            except (IndexError, ValueError):
                pass
    return frames


def benchmark(ide_path, workspace, frames_duration):
    """Run benchmark and return results."""
    print(f"Starting benchmark (duration={frames_duration}s)...")

    display, xvfb_proc = run_xvfb()
    try:
        stdout, stderr = run_ide(display, workspace, ide_path, frames_duration)
    finally:
        xvfb_proc.terminate()
        try:
            xvfb_proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            xvfb_proc.kill()

    perf_data = parse_perf_logs(stderr)

    results = {
        "duration_s": frames_duration,
        "perf_frames": perf_data,
        "stdout_preview": stdout[:500],
    }

    if perf_data:
        totals = [f["total_ms"] for f in perf_data]
        ticks = [f["tick_ms"] for f in perf_data]
        layouts = [f["layout_ms"] for f in perf_data]

        results["summary"] = {
            "frame_count": len(perf_data),
            "p50_total_ms": statistics.median(totals),
            "p95_total_ms": sorted(totals)[int(len(totals) * 0.95)] if len(totals) > 1 else totals[0],
            "avg_total_ms": statistics.mean(totals),
            "min_total_ms": min(totals),
            "max_total_ms": max(totals),
            "avg_tick_ms": statistics.mean(ticks),
            "avg_layout_ms": statistics.mean(layouts),
            "estimated_fps": 1000.0 / statistics.median(totals) if totals else 0,
        }

    return results


def main():
    parser = argparse.ArgumentParser(description="Forge IDE rendering benchmark")
    parser.add_argument("--frames", type=int, default=10, help="Duration in seconds")
    parser.add_argument("--output", default=".forge/benchmark.json", help="Output JSON path")
    parser.add_argument("--workspace", default=".", help="Workspace path")
    parser.add_argument("--ide-path", default=None, help="Path to forge-ide binary")
    args = parser.parse_args()

    if args.ide_path:
        ide_path = args.ide_path
    else:
        repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        ide_path = os.path.join(repo_root, "zig-out", "bin", "forge-ide")

    if not os.path.exists(ide_path):
        print(f"error: forge-ide not found at {ide_path}", file=sys.stderr)
        print("Run 'zig build' first.", file=sys.stderr)
        sys.exit(1)

    results = benchmark(ide_path, args.workspace, args.frames)

    # Save results
    os.makedirs(os.path.dirname(args.output), exist_ok=True)
    with open(args.output, "w") as f:
        json.dump(results, f, indent=2)

    print(f"\nBenchmark results saved to {args.output}")
    if "summary" in results:
        s = results["summary"]
        print(f"\n=== Summary ===")
        print(f"Frames measured: {s['frame_count']}")
        print(f"p50 frame time: {s['p50_total_ms']:.1f}ms ({s['estimated_fps']:.0f} fps)")
        print(f"p95 frame time: {s['p95_total_ms']:.1f}ms")
        print(f"avg frame time: {s['avg_total_ms']:.1f}ms")
        print(f"min/max: {s['min_total_ms']}/{s['max_total_ms']}ms")
        print(f"avg tick: {s['avg_tick_ms']:.1f}ms")
        print(f"avg layout: {s['avg_layout_ms']:.1f}ms")


if __name__ == "__main__":
    main()
