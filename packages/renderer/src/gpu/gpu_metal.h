#ifndef FORGE_GPU_METAL_H
#define FORGE_GPU_METAL_H

// Metal GPU backend interface for Forge IDE.
// On macOS, the Metal rendering is already integrated into mac_window.m
// via MTKView + MTLRenderCommandEncoder. This header provides the
// interface for the gpu_backend.zig module to query Metal availability
// and initialize the GPU path.
//
// On non-Apple platforms, these are no-op stubs.

#ifdef __APPLE__
int forge_gpu_metal_init(void);
int forge_gpu_metal_available(void);
void forge_gpu_metal_draw_rect(float x, float y, float w, float h, float r, float g, float b, float a);
void forge_gpu_metal_flush(void* encoder, float vw, float vh);
#else
static inline int forge_gpu_metal_init(void) { return 0; }
static inline int forge_gpu_metal_available(void) { return 0; }
static inline void forge_gpu_metal_draw_rect(float x, float y, float w, float h, float r, float g, float b, float a) { (void)x; (void)y; (void)w; (void)h; (void)r; (void)g; (void)b; (void)a; }
static inline void forge_gpu_metal_flush(void* encoder, float vw, float vh) { (void)encoder; (void)vw; (void)vh; }
#endif

#endif // FORGE_GPU_METAL_H
