#!/usr/bin/env bash

# benchmark_sandbox.sh
# Benchmarks the latency overhead of sandbox-exec vs native execution

set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$DIR")"

echo "Creating temporary sandbox profile..."
cat << 'EOF' > "$DIR/test_profile.sb"
(version 1)
(deny default)
(allow process-exec (regex #"^/bin/.*"))
(allow file-read*)
(allow file-write*)
EOF

COMMAND="/bin/echo 'hello'"
ITERATIONS=100

echo "Benchmarking Native Execution ($ITERATIONS iterations)..."
start=$(python3 -c 'import time; print(time.time())')
for i in $(seq 1 $ITERATIONS); do
    $COMMAND >/dev/null
done
end=$(python3 -c 'import time; print(time.time())')
native_time=$(python3 -c "print(($end - $start) / $ITERATIONS)")
echo "Average Native Latency: $(python3 -c "print(f'{($end - $start) / $ITERATIONS * 1000:.2f} ms')")"

echo ""
echo "Benchmarking Sandbox Execution ($ITERATIONS iterations)..."
start=$(python3 -c 'import time; print(time.time())')
for i in $(seq 1 $ITERATIONS); do
    sandbox-exec -f "$DIR/test_profile.sb" $COMMAND >/dev/null
done
end=$(python3 -c 'import time; print(time.time())')
sandbox_time=$(python3 -c "print(($end - $start) / $ITERATIONS)")
echo "Average Sandbox Latency: $(python3 -c "print(f'{($end - $start) / $ITERATIONS * 1000:.2f} ms')")"

echo ""
overhead=$(python3 -c "print(f'{($sandbox_time - $native_time) * 1000:.2f}')")
echo "Sandbox Overhead per execution: $overhead ms"

rm "$DIR/test_profile.sb"
