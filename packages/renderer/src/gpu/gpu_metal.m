// Metal backend for Forge IDE — GPU-accelerated rendering via Metal.
//
// This module implements the GPU backend interface using Metal framework
// on macOS. It replaces CPU software rendering with GPU command encoders
// for rect fills, text rendering (via SDF atlas), and SVG icons.
//
// Architecture:
//   - MTKView provides the Metal device + drawable
//   - MTLRenderCommandEncoder issues draw calls
//   - Vertex shader transforms quad positions
//   - Fragment shader fills color or samples SDF atlas
//
// Phase 1: Rect rendering (batched quads)
// Phase 2: Text rendering (SDF atlas sampling)
// Phase 3: SVG icon rendering (texture atlas)

#include "../shared/backend.h"

#ifdef __APPLE__

#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <simd/simd.h>

// --- Metal shaders (inline source, compiled at runtime) ---

static NSString* const kRectShaderSource = @""
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "\n"
    "struct RectVertex {\n"
    "    float2 position [[attribute(0)]];\n"
    "    float4 color    [[attribute(1)]];\n"
    "};\n"
    "\n"
    "struct RectUniforms {\n"
    "    float2 viewport_size;\n"
    "};\n"
    "\n"
    "struct RasterizerData {\n"
    "    float4 position [[position]];\n"
    "    float4 color;\n"
    "};\n"
    "\n"
    "vertex RasterizerData rect_vertex(uint vid [[vertex_id]],\n"
    "                                   device const RectVertex* verts [[buffer(0)]],\n"
    "                                   constant RectUniforms& uniforms [[buffer(1)]]) {\n"
    "    RasterizerData out;\n"
    "    float2 pos = verts[vid].position;\n"
    "    // Convert pixel coordinates to clip space (-1 to 1)\n"
    "    out.position = float4(pos / uniforms.viewport_size * 2.0 - 1.0, 0.0, 1.0);\n"
    "    out.position.y = -out.position.y; // Flip Y for screen coords\n"
    "    out.color = verts[vid].color;\n"
    "    return out;\n"
    "}\n"
    "\n"
    "fragment float4 rect_fragment(RasterizerData in [[stage_in]]) {\n"
    "    return in.color;\n"
    "}\n";

// SDF text shader source
static NSString* const kTextShaderSource = @""
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "\n"
    "struct TextVertex {\n"
    "    float2 position [[attribute(0)]];\n"
    "    float2 texcoord [[attribute(1)]];\n"
    "    float4 color    [[attribute(2)]];\n"
    "};\n"
    "\n"
    "struct TextUniforms {\n"
    "    float2 viewport_size;\n"
    "    float smoothing; // SDF edge smoothing (1.0/font_size)\n"
    "};\n"
    "\n"
    "struct TextRasterizerData {\n"
    "    float4 position [[position]];\n"
    "    float2 texcoord;\n"
    "    float4 color;\n"
    "};\n"
    "\n"
    "vertex TextRasterizerData text_vertex(uint vid [[vertex_id]],\n"
    "                                       device const TextVertex* verts [[buffer(0)]],\n"
    "                                       constant TextUniforms& uniforms [[buffer(1)]]) {\n"
    "    TextRasterizerData out;\n"
    "    float2 pos = verts[vid].position;\n"
    "    out.position = float4(pos / uniforms.viewport_size * 2.0 - 1.0, 0.0, 1.0);\n"
    "    out.position.y = -out.position.y;\n"
    "    out.texcoord = verts[vid].texcoord;\n"
    "    out.color = verts[vid].color;\n"
    "    return out;\n"
    "}\n"
    "\n"
    "fragment float4 text_fragment(TextRasterizerData in [[stage_in]],\n"
    "                               texture2d<float> atlas [[texture(0)]],\n"
    "                               sampler tex_sampler [[sampler(0)]],\n"
    "                               constant TextUniforms& uniforms [[buffer(1)]]) {\n"
    "    float dist = atlas.sample(tex_sampler, in.texcoord).r;\n"
    "    // SDF to alpha: smoothstep around edge (0.5)\n"
    "    float alpha = smoothstep(0.5 - uniforms.smoothing, 0.5 + uniforms.smoothing, dist);\n"
    "    return float4(in.color.rgb, in.color.a * alpha);\n"
    "}\n";

// --- Metal state ---

static id<MTLDevice> g_mtl_device = nil;
static id<MTLCommandQueue> g_mtl_queue = nil;
static id<MTLRenderPipelineState> g_rect_pipeline = nil;
static id<MTLRenderPipelineState> g_text_pipeline = nil;
static id<MTLBuffer> g_rect_vbo = nil; // Dynamic VBO for batched rects
static id<MTLSamplerState> g_sampler = nil;

// Batched rect vertices (CPU-side, uploaded per frame)
#define MAX_RECT_VERTS 65536
typedef struct {
    vector_float2 position;
    vector_float4 color;
} RectVertex;
static RectVertex g_rect_verts[MAX_RECT_VERTS];
static int g_rect_count = 0;

// --- Initialization ---

int forge_gpu_metal_init(void) {
    g_mtl_device = MTLCreateSystemDefaultDevice();
    if (!g_mtl_device) return 0;

    g_mtl_queue = [g_mtl_device newCommandQueue];
    if (!g_mtl_queue) return 0;

    // Compile rect shaders
    NSError* error = nil;
    id<MTLLibrary> rect_lib = [g_mtl_device newLibraryWithSource:kRectShaderSource
                                                          options:nil
                                                            error:&error];
    if (!rect_lib) { NSLog(@"Rect shader compile error: %@", error); return 0; }

    MTLRenderPipelineDescriptor* rect_desc = [[MTLRenderPipelineDescriptor alloc] init];
    rect_desc.vertexFunction = [rect_lib newFunctionWithName:@"rect_vertex"];
    rect_desc.fragmentFunction = [rect_lib newFunctionWithName:@"rect_fragment"];
    rect_desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    rect_desc.colorAttachments[0].blendingEnabled = YES;
    rect_desc.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
    rect_desc.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
    rect_desc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    rect_desc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
    rect_desc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    rect_desc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;

    g_rect_pipeline = [g_mtl_device newRenderPipelineStateWithDescriptor:rect_desc error:&error];
    if (!g_rect_pipeline) { NSLog(@"Rect pipeline error: %@", error); return 0; }

    // Compile text shaders (Phase 2)
    id<MTLLibrary> text_lib = [g_mtl_device newLibraryWithSource:kTextShaderSource
                                                          options:nil
                                                            error:&error];
    if (text_lib) {
        MTLRenderPipelineDescriptor* text_desc = [[MTLRenderPipelineDescriptor alloc] init];
        text_desc.vertexFunction = [text_lib newFunctionWithName:@"text_vertex"];
        text_desc.fragmentFunction = [text_lib newFunctionWithName:@"text_fragment"];
        text_desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        text_desc.colorAttachments[0].blendingEnabled = YES;
        text_desc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
        text_desc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
        text_desc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        text_desc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        g_text_pipeline = [g_mtl_device newRenderPipelineStateWithDescriptor:text_desc error:&error];
    }

    // Create dynamic VBO for batched rects
    g_rect_vbo = [g_mtl_device newBufferWithLength:sizeof(RectVertex) * MAX_RECT_VERTS
                                            options:MTLResourceStorageModeShared |
                                                    MTLResourceCPUCacheModeWriteCombined];

    // Create sampler for SDF atlas (linear filtering for smooth text)
    MTLSamplerDescriptor* sampler_desc = [[MTLSamplerDescriptor alloc] init];
    sampler_desc.minFilter = MTLSamplerMinMagFilterLinear;
    sampler_desc.magFilter = MTLSamplerMinMagFilterLinear;
    sampler_desc.sAddressMode = MTLSamplerAddressModeClampToEdge;
    sampler_desc.tAddressMode = MTLSamplerAddressModeClampToEdge;
    g_sampler = [g_mtl_device newSamplerStateWithDescriptor:sampler_desc];

    return 1;
}

// --- Batched rect rendering ---

void forge_gpu_metal_draw_rect(float x, float y, float w, float h, float r, float g, float b, float a) {
    if (g_rect_count + 6 > MAX_RECT_VERTS) return; // Buffer full, skip (should flush)

    int base = g_rect_count;
    // Two triangles forming a quad
    g_rect_verts[base + 0] = (RectVertex){{x, y}, {r, g, b, a}};
    g_rect_verts[base + 1] = (RectVertex){{x + w, y}, {r, g, b, a}};
    g_rect_verts[base + 2] = (RectVertex){{x, y + h}, {r, g, b, a}};
    g_rect_verts[base + 3] = (RectVertex){{x + w, y}, {r, g, b, a}};
    g_rect_verts[base + 4] = (RectVertex){{x + w, y + h}, {r, g, b, a}};
    g_rect_verts[base + 5] = (RectVertex){{x, y + h}, {r, g, b, a}};
    g_rect_count += 6;
}

// --- Frame flush: upload batched rects + draw via Metal ---

void forge_gpu_metal_flush(id<MTLRenderCommandEncoder> encoder, float viewport_w, float viewport_h) {
    if (g_rect_count == 0) return;

    // Upload vertex data
    memcpy([g_rect_vbo contents], g_rect_verts, sizeof(RectVertex) * g_rect_count);

    // Set pipeline + buffers
    [encoder setRenderPipelineState:g_rect_pipeline];

    typedef struct {
        vector_float2 viewport_size;
    } RectUniforms;
    RectUniforms uniforms = {{viewport_w, viewport_h}};

    [encoder setVertexBuffer:g_rect_vbo offset:0 atIndex:0];
    [encoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:1];

    // Draw batched rects
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:g_rect_count];

    g_rect_count = 0; // Reset for next frame
}

// --- Check if Metal is available ---

int forge_gpu_metal_available(void) {
    return MTLCreateSystemDefaultDevice() != nil;
}

#else // !__APPLE__

// Stubs for non-Apple platforms
int forge_gpu_metal_init(void) { return 0; }
void forge_gpu_metal_draw_rect(float x, float y, float w, float h, float r, float g, float b, float a) { (void)x; (void)y; (void)w; (void)h; (void)r; (void)g; (void)b; (void)a; }
void forge_gpu_metal_flush(void* encoder, float vw, float vh) { (void)encoder; (void)vw; (void)vh; }
int forge_gpu_metal_available(void) { return 0; }

#endif // __APPLE__
