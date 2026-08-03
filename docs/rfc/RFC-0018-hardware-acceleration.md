# RFC-0018: Hardware Acceleration & Color Management

> **Trạng thái:** Proposed
> **Tác giả:** truonglv95 <anhtruonglavm2@gmail.com>
> **Ngày:** 2026-07-25
> **Liên kết:** [AI Workflow Evaluation](../evaluation/AI_WORKFLOW_EVALUATION.md)

## 1. Tóm tắt

Đề xuất kiến trúc hardware acceleration (GPU backend) cho Forge IDE renderer
thay thế CPU software rendering hiện tại, cùng với ICC color profile support
cho accurate colors trên calibrated displays.

## 2. Động lực

Hiện tại Forge IDE dùng CPU software rendering:
- Mỗi frame: fill framebuffer (CPU) → XPutImage/XShmPutImage (Linux),
  BitBlt (Windows), MetalKit blit (macOS)
- Text rendering: FreeType rasterize → CPU blend per-pixel
- Rect/circle rendering: CPU fill loop
- Performance: ~5-16ms per frame trên 1280×800, sẽ chậm hơn trên 4K

**Vấn đề:**
- 4K/retina (3840×2160 = 8.3M pixels × 4 bytes = 33MB/frame) quá chậm cho CPU
- Animation 60fps cần <16ms/frame, CPU rendering không đủ headroom
- No GPU compositing cho transparency/blur effects
- No color management → colors khác nhau giữa displays

## 3. Thiết kế

### 3.1 GPU Backend Abstraction

```text
packages/renderer/src/platform/
├── shared/backend.h          # Existing CPU API (keep for fallback)
├── gpu/
│   ├── gpu_backend.h         # GPU backend interface
│   ├── gpu_linux.c           # OpenGL ES 3.0 (X11/EGL)
│   ├── gpu_mac.m             # Metal (MTKView)
│   ├── gpu_windows.c         # Direct3D 11 / OpenGL
│   └── shaders/              # GLSL/MSL/HLSL shaders
│       ├── text.glsl         # Text rendering shader (SDF)
│       ├── rect.glsl         # Rectangle fill shader
│       └── svg.glsl          # SVG path rasterization shader
```

### 3.2 GPU Rendering Pipeline

```text
CPU prepares draw calls (batch)
  → Upload vertex + uniform data to GPU buffers
  → GPU executes shaders (text, rect, svg, image)
  → GPU composites to framebuffer
  → Swap buffers (VSync)
```

**Key optimizations:**
- **Batched draw calls**: collect all rects/text in a frame, submit 1 draw call
- **Instanced rendering**: 1000 rects = 1 draw call with instancing
- **SDF text**: signed distance field font atlas, 1 texture for all glyphs
- **GPU SVG**: tessellate SVG paths on CPU, render triangles on GPU

### 3.3 Text Rendering (SDF)

```text
Font → FreeType rasterize at 48px → SDF atlas (single texture)
  → GPU shader samples SDF → crisp text at any size
  → No per-frame glyph rendering (atlas built once)
```

Benefits:
- 1 texture upload (vs per-frame glyph cache)
- Text crisp at any size/zoom (SDF interpolation)
- Subpixel rendering via shader (no FT_LOAD_TARGET_LCD needed)
- 10-100x faster than CPU text rendering

### 3.4 Color Management (ICC)

```text
Display ICC profile (loaded at startup)
  → Color management context (lcms2 or ColorSync)
  → Shader converts linear RGB → display color space
  → Accurate colors on calibrated displays
```

Implementation:
- Linux: `lcms2` library, load ICC from `~/.local/share/icc/` or X11 `_ICC_PROFILE`
- macOS: `ColorSyncProfile` from `NSScreen.colorSpace`
- Windows: `GetICMProfileW` from HDC

### 3.5 Performance Targets

| Scenario | CPU (current) | GPU (target) |
|---|---|---|
| 1080p frame | 5-16ms | 1-3ms |
| 4K frame | 20-50ms | 2-5ms |
| Text-heavy frame | 8-16ms | 0.5-1ms |
| Animation (60fps) | Marginal | Comfortable |
| Memory (font atlas) | 4MB glyph cache | 2MB SDF atlas |

## 4. Migration Strategy

### Phase 1: GPU Backend (2-3 weeks)
1. Create `gpu_backend.h` interface matching existing `backend.h`
2. Implement Metal backend (macOS, easiest with existing MTKView)
3. Implement OpenGL ES backend (Linux X11/EGL)
4. Implement Direct3D 11 backend (Windows)
5. Add `--gpu` flag to switch between CPU/GPU backends

### Phase 2: SDF Text (1-2 weeks)
1. Generate SDF atlas from bundled fonts (build-time tool)
2. Implement SDF text shader
3. Replace FreeType per-frame rendering with SDF sampling
4. Benchmark text rendering performance

### Phase 3: Color Management (1 week)
1. Integrate lcms2 (Linux) / ColorSync (macOS) / WCS (Windows)
2. Load display ICC profile at startup
3. Add color conversion shader
4. Test on calibrated displays

### Phase 4: Advanced Effects (ongoing)
1. Gaussian blur for panel backgrounds
2. Shadow/glow effects
3. Animated transitions on GPU
4. Multi-sample anti-aliasing (MSAA)

## 5. Alternatives Considered

- **Keep CPU rendering + optimize**: Limited ceiling (~4K is max practical)
- **Skia/cairo**: Mature 2D libraries but heavy dependencies, not Zig-native
- **WebGPU**: Cross-platform but still emerging, limited driver support
- **Vulkan**: Low-level, high performance but complex (600+ lines for triangle)

## 6. Risks

| Rủi ro | Giảm |
|---|---|
| GPU driver bugs | Keep CPU fallback, test on multiple GPUs |
| Shader compatibility | Use GLSL ES 3.0 (widely supported) |
| SDF quality at small sizes | Use multi-channel SDF (MSDF) for crisp edges |
| Color profile mismatches | Default to sRGB, opt-in to ICC |
| Build complexity | GPU code in separate module, conditional compilation |

## 7. Exit Gate

- [ ] GPU backend matches CPU rendering output (visual regression tests)
- [ ] 4K rendering at 60fps on mid-range GPU
- [ ] SDF text quality >= FreeType at all sizes
- [ ] ICC color management on at least one platform
- [ ] CPU fallback works when GPU unavailable
