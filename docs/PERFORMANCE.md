# Forge Performance Audit

> Comprehensive performance baseline + optimization log for the Forge ecosystem.
> Last updated: 2026-08-07

## Ecosystem overview

| Component | Language | LOC | Binary size (ReleaseFast stripped) | Status |
|---|---|---|---|---|
| `forge` CLI | Zig 0.16 | 124K | ~10-15 MB | Production |
| `forge-ide` desktop app | Zig 0.16 + Metal/GLX | 42K + 6K C/ObjC | ~15-20 MB | Pre-alpha |
| `forge-cloud-backend` | Deno/TypeScript | ~2K | N/A (Edge Functions) | Production |
| `@forge-ai/cli` npm package | JS shim + Zig binary | ~200 LOC JS | ~10-15 MB per platform | Ready to publish |

## Build performance

| Build type | Time (clean) | Time (incremental) | Binary size |
|---|---|---|---|
| Debug (`zig build`) | 30s | 0.2s | 100 MB (forge) + 130 MB (forge-ide) |
| ReleaseSafe | ~2 min | 0.5s | ~25 MB |
| ReleaseFast + strip | ~3 min | 0.5s | ~10-15 MB |

**Recommendation**: Use Debug for development (fast iteration), ReleaseFast+strip for distribution.

## Runtime performance (CLI eval, fake provider)

| Metric | Value | Notes |
|---|---|---|
| Eval latency p50 | 50ms | agent_reliability.json, 5 tasks |
| Eval latency p95 | 73ms | |
| Average steps per task | 3.2 | |
| Success rate | 100% (5/5) | |
| Token usage | 150 total | fake provider reports 30 tokens/call |

## Runtime performance (IDE, measured)

| Metric | Before optimization | After optimization | Improvement |
|---|---|---|---|
| Idle CPU (editor focus) | 30-60% (60fps continuous) | ~0% (paused + caret timer) | 95%+ reduction |
| Typing CPU | 30% (full clear + cache miss) | ~5% (dirty-rect + cache hit) | 83% reduction |
| Measure cache hit rate (2000-line file) | ~40% (1024 slots) | ~95% (8192 slots, 8-probe) | 2.4x better |
| Frame time (typing) | 16-25ms | 5-10ms | 2x faster |
| Mac MTKView fps | 120fps | 60fps | 50% GPU load reduction |
| Full-screen clear per frame | Always (3-4ms 1080p) | Only on layout change | 3-4ms saved/frame |

## Memory performance

| Component | Allocator | Notes |
|---|---|---|
| Frame arena (IDE render) | ArenaAllocator, reused | `reset(.retain_capacity)` per frame, peak tracked |
| Agent loop | Caller allocator | No global state, no leaks (tested with testing.allocator) |
| JSON parse (hot paths) | page_allocator → stack scan | mcp_capability.zig now scans `readOnly` without full parse |
| Measure cache | Static array, 8192 slots | No allocation, O(1) lookup |
| Render cache (TUI) | HashMap, per-line | Invalidated on width change |

## Optimization log

### Phase 1: Idle CPU fix (commit `e47eb1f`)
- Removed continuous rendering when editor focused
- Caret blink driven by 530ms timer instead of 60fps time accumulation
- 8 render sites updated to use `state.caret_blink_visible`

### Phase 2: GPU + cache + dirty-rect (commit `6e062bd`)
- Mac MTKView 120fps → 60fps
- Measure cache 1024 → 8192 slots, probe 4 → 8
- Full clear only when `dirty_full` (saves 3-4ms/frame)
- Frame arena peak tracking

### Phase 3: Allocator cleanup (commit `6e062bd` + this)
- `orchestrator.fromHeuristic` now takes allocator param (was hardcoded page_allocator)
- `mcp_capability.inferPolicy` scans `readOnly` without JSON parse (was page_allocator per call)
- npm `build-npm.sh` uses ReleaseFast + strip (was ReleaseSafe, no strip)

## Known bottlenecks (not yet fixed)

1. **Linux CPU rendering by default** — `-Dwith-glx=false` in CI because libGL-dev not always available. GPU mode requires manual setup. **Fix**: ship GLX dynamically loaded (dlopen libGL.so).

2. **7 `page_allocator` JSON parse sites** — all have `defer deinit()` (no leak), but page_allocator is slower than arena for temporaries. **Fix**: pass caller allocator through.

3. **`index_warm.zig` uses page_allocator for StringHashMap** — long-lived hash map on page_allocator. Should use a dedicated arena or GeneralPurposeAllocator for better tracking.

4. **No incremental compilation cache across CI runs** — each CI build starts fresh. Could cache `.zig-cache/` but Zig 0.16 cache format may not be stable across versions.

5. **Binary size 10-15MB** — acceptable but could be smaller with `-fstrip -fno-emit-bin` tricks or LTO. Not a priority.

## Benchmark methodology

### CLI eval
```bash
forge eval ai-flow --provider fake --corpus fixtures/eval/agent_reliability.json --repeat 3 --output /tmp/eval.jsonl
```

### IDE perf overlay
```bash
FORGE_PERF=1 forge-ide
```
Shows per-frame: tick/layout/draw/editor/agent/panel timings, cache hit/miss counts, frame arena usage.

### Memory leak check
```bash
zig build test  # uses testing.allocator — fails on any leak
```

### Binary size
```bash
zig build -Doptimize=ReleaseFast -Dwith-glx=false
strip zig-out/bin/forge
ls -lh zig-out/bin/forge
```

## Performance targets

| Metric | Current | Target | How |
|---|---|---|---|
| Idle CPU (Mac) | ~0% | <1% | Achieved |
| Typing CPU | ~5% | <3% | Further dirty-rect granularity |
| Frame time p95 (typing) | 5-10ms | <8ms | Measure cache already helps |
| Binary size (stripped) | 10-15MB | <10MB | LTO + dead code elimination |
| CLI cold start | 50ms | <30ms | Lazy init providers |
| Eval latency p95 (live LLM) | unmeasured | <5s | Depends on provider |
