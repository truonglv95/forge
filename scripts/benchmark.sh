#!/usr/bin/env bash

# Forge M2.4 Benchmark Harness
# Captures execution latency and peak memory usage for baseline CLI commands.

set -e

# Change to the root of the project
cd "$(dirname "$0")/.."

echo "============================================="
echo " Forge Baseline Benchmark"
echo "============================================="
echo "Machine Info: $(uname -m -v)"
echo "Commit:       $(git rev-parse HEAD 2>/dev/null || echo 'Not a git repo')"
echo "Timestamp:    $(date)"
echo "============================================="

FORGE_BIN="zig build run -- "

# Warm up the build
zig build

echo -e "\n[1] Benchmark: forge inspect"
/usr/bin/time -l $FORGE_BIN inspect --workspace ./fixtures 2>&1 | grep -E "real|maximum resident set size"

echo -e "\n[2] Benchmark: forge search"
/usr/bin/time -l $FORGE_BIN search "std.testing" --workspace ./fixtures 2>&1 | grep -E "real|maximum resident set size"

echo -e "\n[3] Benchmark: forge check"
# We expect this to run and exit with code 0 for the MVP stub
/usr/bin/time -l $FORGE_BIN check --workspace ./fixtures 2>&1 | grep -E "real|maximum resident set size"

echo -e "\nBenchmark completed."
