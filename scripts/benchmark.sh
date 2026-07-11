#!/usr/bin/env bash

# Forge baseline benchmark.
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

OPTIMIZE="${FORGE_OPTIMIZE:-Debug}"

# Build once, then time the installed binary. Timing `zig build run` measures
# build-runner overhead instead of Forge command latency.
zig build -Doptimize="$OPTIMIZE"
FORGE_BIN="./zig-out/bin/forge"

echo -e "\n[1] Benchmark: forge inspect"
/usr/bin/time -l "$FORGE_BIN" inspect --workspace ./fixtures 2>&1 | grep -E "real|maximum resident set size|peak memory footprint"

echo -e "\n[2] Benchmark: forge search"
/usr/bin/time -l "$FORGE_BIN" search "std.testing" --workspace ./fixtures 2>&1 | grep -E "real|maximum resident set size|peak memory footprint"

echo -e "\n[3] Benchmark: forge check"
# We expect this to run and exit with code 0 for the MVP stub
/usr/bin/time -l "$FORGE_BIN" check --workspace ./fixtures 2>&1 | grep -E "real|maximum resident set size|peak memory footprint"

echo -e "\nBenchmark completed."
