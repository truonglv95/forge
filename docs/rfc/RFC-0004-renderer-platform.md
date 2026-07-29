# RFC-0004: Native macOS Renderer Platform

- Status: Accepted
- Date: 2026-07-03
- Owners: Forge maintainers

## 1. Summary

Forge is an AI-first IDE that prioritizes responsiveness, low input latency, and
seamless typography (Vietnamese, emoji, combining marks) over immediate
cross-platform reach. The MVP uses **Native macOS Cocoa (AppKit) + CoreText +
Metal** via Zig C/Objective-C interop instead of a cross-platform engine with
bundled HarfBuzz/FreeType.

## 2. Motivation

The MVP is constrained to macOS. The rendering stack must handle:

- complex font shaping (ligatures, combining marks, emoji, RTL samples);
- low idle CPU and RSS;
- display-synchronized frames (ProMotion 120 Hz target).

Cross-platform windowing stacks typically require bundling heavyweight shaping
libraries to match CoreText quality on macOS. That duplicates platform capability
and increases binary size without improving the MVP hypothesis.

## 3. Spike Results (M0.2)

Target: `tools/renderer-spike` (`zig build run-spike`)

Verified capabilities:

1. **Windowing:** AppKit window via minimal Objective-C wrapper (`mac_window.m`).
2. **GPU surface:** `MTKView` attached to the window.
3. **Typography:** CoreText shapes UTF-8 samples containing Vietnamese and emoji.
4. **Zig interop:** Zig imports `mac_window.h` and calls into Objective-C via
   `@cImport`.

Baseline measurements on reference machine (2026-07-03):

| Metric | Value | Notes |
|---|---|---|
| Machine | Apple Silicon, macOS 25.5, arm64 | Darwin 25.5.0 |
| `forge inspect` wall time | 0.71 s real | includes cold `zig build run` wrapper |
| `forge search` wall time | 0.20 s real | CLI stub path |
| `forge check` wall time | 0.19 s real | CLI stub path |
| Peak RSS (CLI commands) | ~34 MB | `/usr/bin/time -l` |

Renderer-specific frame timing and 10k-glyph layout benchmarks remain M4 work;
the spike's purpose was to de-risk platform interop and typography path selection.

Recorded by `./scripts/benchmark.sh`.

## 4. Decision

Proceed with **Native Cocoa + Metal + CoreText** for M4 (native IDE editing
foundation).

- **UI and windowing:** minimal Objective-C wrappers in
  `packages/renderer/src/platform/mac/`.
- **Rendering:** Metal glyph atlas fed by CoreText measurements.
- **Event loop:** AppKit-driven, isolated from headless kernel work. Filesystem,
  tasks, LSP, and model calls stay off the render thread.

Production renderer code lives under `packages/renderer/`. The disposable spike
stays under `tools/renderer-spike/`.

## 5. Alternatives Considered

| Option | Result |
|---|---|
| Electron / Tauri | Disqualified — conflicts with native-first north star |
| SDL3 / GLFW / Mach | Viable later, but redundant shaping stack on macOS MVP |
| Skia-only custom stack | Higher implementation cost before editor proof |

## 6. Consequences

- macOS-only MVP is explicit until a second platform spike in M7.
- `apps/forge-ide` depends on Objective-C sources and Apple frameworks in
  `build.zig`.
- IME, accessibility, and fallback font policy must be documented before M5 IDE
  AI workflow.

## 7. Next Steps

1. Complete M1 safe workspace engine (blocks IDE file save/conflict handling).
2. Prove M2/M3 CLI workflow before investing in M4 editor depth.
3. Benchmark rope vs piece table and text layout on a reference corpus during
   M4.1.
