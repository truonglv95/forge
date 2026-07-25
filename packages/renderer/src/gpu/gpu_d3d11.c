// Direct3D 11 backend for Forge IDE — GPU-accelerated rendering on Windows.
//
// This module implements GPU rendering via Direct3D 11, matching the
// Metal backend (macOS) and OpenGL ES backend (Linux). It provides
// batched rect rendering with HLSL shaders.
//
// Architecture:
//   - DXGI swap chain on HWND
//   - ID3D11Device + ID3D11DeviceContext for rendering
//   - Vertex buffer for batched quads (same as Metal/OpenGL)
//   - HLSL shaders compiled at runtime via D3DCompile
//
// Phase 1: Rect rendering (batched quads)
// Phase 2: SDF text rendering (texture atlas + pixel shader)

#include "../shared/backend.h"

#ifdef _WIN32

#include <windows.h>
#include <d3d11.h>
#include <d3dcompiler.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "d3dcompiler.lib")

// --- HLSL Shaders ---

static const char* kRectVS =
    "struct VSInput { float2 pos : POSITION; float4 col : COLOR; };\n"
    "struct VSOutput { float4 pos : SV_POSITION; float4 col : COLOR; };\n"
    "cbuffer ViewportCB : register(b0) { float2 viewport; };\n"
    "VSOutput main(VSInput input) {\n"
    "    VSOutput output;\n"
    "    float2 clip = input.pos / viewport * 2.0 - 1.0;\n"
    "    output.pos = float4(clip.x, -clip.y, 0.0, 1.0);\n"
    "    output.col = input.col;\n"
    "    return output;\n"
    "}\n";

static const char* kRectPS =
    "struct PSInput { float4 pos : SV_POSITION; float4 col : COLOR; };\n"
    "float4 main(PSInput input) : SV_TARGET {\n"
    "    return input.col;\n"
    "}\n";

// --- D3D11 state ---

static ID3D11Device* g_d3d_device = NULL;
static ID3D11DeviceContext* g_d3d_context = NULL;
static IDXGISwapChain* g_swap_chain = NULL;
static ID3D11RenderTargetView* g_rtv = NULL;
static ID3D11VertexShader* g_rect_vs = NULL;
static ID3D11PixelShader* g_rect_ps = NULL;
static ID3D11Buffer* g_rect_vbo = NULL;
static ID3D11Buffer* g_viewport_cb = NULL;
static ID3D11InputLayout* g_input_layout = NULL;
static int g_d3d_initialized = 0;

// Batched rect vertices
#define D3D_MAX_RECT_VERTS 65536
typedef struct {
    float position[2];
    float color[4];
} D3DVertex;
static D3DVertex g_rect_verts[D3D_MAX_RECT_VERTS];
static int g_rect_count = 0;

// --- Initialization ---

int forge_gpu_d3d11_init(void* hwnd) {
    HWND window = (HWND)hwnd;
    if (!window) return 0;

    DXGI_SWAP_CHAIN_DESC scd = {0};
    scd.BufferCount = 2;
    scd.BufferDesc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    scd.BufferDesc.Width = 0; // Use window size
    scd.BufferDesc.Height = 0;
    scd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    scd.OutputWindow = window;
    scd.SampleDesc.Count = 1;
    scd.Windowed = TRUE;
    scd.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;
    scd.Flags = DXGI_SWAP_CHAIN_FLAG_ALLOW_MODE_SWITCH;

    D3D_FEATURE_LEVEL feature_levels[] = { D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_1, D3D_FEATURE_LEVEL_10_0 };
    D3D_FEATURE_LEVEL selected_level;
    HRESULT hr = D3D11CreateDeviceAndSwapChain(
        NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0,
        feature_levels, 3, D3D11_SDK_VERSION,
        &scd, &g_swap_chain, &g_d3d_device, &selected_level, &g_d3d_context);

    if (FAILED(hr)) {
        fprintf(stderr, "[gpu_d3d11] D3D11CreateDeviceAndSwapChain failed: 0x%08X\n", hr);
        return 0;
    }

    // Create render target view
    ID3D11Texture2D* back_buffer = NULL;
    g_swap_chain->lpVtbl->GetBuffer(g_swap_chain, 0, &IID_ID3D11Texture2D, (void**)&back_buffer);
    if (back_buffer) {
        g_d3d_device->lpVtbl->CreateRenderTargetView(g_d3d_device, (ID3D11Resource*)back_buffer, NULL, &g_rtv);
        back_buffer->lpVtbl->Release(back_buffer);
    }
    g_d3d_context->lpVtbl->OMSetRenderTargets(g_d3d_context, 1, &g_rtv, NULL);

    // Compile shaders
    ID3DBlob* vs_blob = NULL;
    ID3DBlob* ps_blob = NULL;
    ID3DBlob* error_blob = NULL;

    D3DCompile(kRectVS, strlen(kRectVS), NULL, NULL, NULL, "main", "vs_4_0", 0, 0, &vs_blob, &error_blob);
    if (error_blob) { error_blob->lpVtbl->Release(error_blob); error_blob = NULL; }
    if (vs_blob) {
        g_d3d_device->lpVtbl->CreateVertexShader(g_d3d_device, vs_blob->lpVtbl->GetBufferPointer(vs_blob), vs_blob->lpVtbl->GetBufferSize(vs_blob), NULL, &g_rect_vs);
    }

    D3DCompile(kRectPS, strlen(kRectPS), NULL, NULL, NULL, "main", "ps_4_0", 0, 0, &ps_blob, &error_blob);
    if (error_blob) { error_blob->lpVtbl->Release(error_blob); error_blob = NULL; }
    if (ps_blob) {
        g_d3d_device->lpVtbl->CreatePixelShader(g_d3d_device, ps_blob->lpVtbl->GetBufferPointer(ps_blob), ps_blob->lpVtbl->GetBufferSize(ps_blob), NULL, &g_rect_ps);
    }

    // Create input layout
    D3D11_INPUT_ELEMENT_DESC layout[] = {
        { "POSITION", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 0, D3D11_INPUT_PER_VERTEX_DATA, 0 },
        { "COLOR", 0, DXGI_FORMAT_R32G32B32A32_FLOAT, 0, 8, D3D11_INPUT_PER_VERTEX_DATA, 0 },
    };
    if (vs_blob) {
        g_d3d_device->lpVtbl->CreateInputLayout(g_d3d_device, layout, 2, vs_blob->lpVtbl->GetBufferPointer(vs_blob), vs_blob->lpVtbl->GetBufferSize(vs_blob), &g_input_layout);
        vs_blob->lpVtbl->Release(vs_blob);
    }
    if (ps_blob) ps_blob->lpVtbl->Release(ps_blob);

    // Create dynamic VBO
    D3D11_BUFFER_DESC bd = {0};
    bd.Usage = D3D11_USAGE_DYNAMIC;
    bd.ByteWidth = sizeof(D3DVertex) * D3D_MAX_RECT_VERTS;
    bd.BindFlags = D3D11_BIND_VERTEX_BUFFER;
    bd.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
    g_d3d_device->lpVtbl->CreateBuffer(g_d3d_device, &bd, NULL, &g_rect_vbo);

    // Create viewport constant buffer
    D3D11_BUFFER_DESC cb_desc = {0};
    cb_desc.Usage = D3D11_USAGE_DYNAMIC;
    cb_desc.ByteWidth = 16; // float2 (8 bytes) + padding
    cb_desc.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
    cb_desc.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
    g_d3d_device->lpVtbl->CreateBuffer(g_d3d_device, &cb_desc, NULL, &g_viewport_cb);

    // Set blend state for alpha blending
    D3D11_BLEND_DESC blend_desc = {0};
    blend_desc.RenderTarget[0].BlendEnable = TRUE;
    blend_desc.RenderTarget[0].SrcBlend = D3D11_BLEND_SRC_ALPHA;
    blend_desc.RenderTarget[0].DestBlend = D3D11_BLEND_INV_SRC_ALPHA;
    blend_desc.RenderTarget[0].BlendOp = D3D11_BLEND_OP_ADD;
    blend_desc.RenderTarget[0].SrcBlendAlpha = D3D11_BLEND_SRC_ALPHA;
    blend_desc.RenderTarget[0].DestBlendAlpha = D3D11_BLEND_INV_SRC_ALPHA;
    blend_desc.RenderTarget[0].BlendOpAlpha = D3D11_BLEND_OP_ADD;
    blend_desc.RenderTarget[0].RenderTargetWriteMask = D3D11_COLOR_WRITE_ENABLE_ALL;
    ID3D11BlendState* blend_state = NULL;
    g_d3d_device->lpVtbl->CreateBlendState(g_d3d_device, &blend_desc, &blend_state);
    if (blend_state) {
        g_d3d_context->lpVtbl->OMSetBlendState(g_d3d_context, blend_state, NULL, 0xFFFFFFFF);
        blend_state->lpVtbl->Release(blend_state);
    }

    g_d3d_initialized = 1;
    fprintf(stderr, "[gpu_d3d11] initialized (Feature Level: 0x%X)\n", selected_level);
    return 1;
}

// --- Batched rect rendering ---

void forge_gpu_d3d11_draw_rect(float x, float y, float w, float h, float r, float g, float b, float a) {
    if (g_rect_count + 6 > D3D_MAX_RECT_VERTS) return;
    int base = g_rect_count;
    g_rect_verts[base + 0] = (D3DVertex){{x, y}, {r, g, b, a}};
    g_rect_verts[base + 1] = (D3DVertex){{x + w, y}, {r, g, b, a}};
    g_rect_verts[base + 2] = (D3DVertex){{x, y + h}, {r, g, b, a}};
    g_rect_verts[base + 3] = (D3DVertex){{x + w, y}, {r, g, b, a}};
    g_rect_verts[base + 4] = (D3DVertex){{x + w, y + h}, {r, g, b, a}};
    g_rect_verts[base + 5] = (D3DVertex){{x, y + h}, {r, g, b, a}};
    g_rect_count += 6;
}

// --- Frame flush ---

void forge_gpu_d3d11_flush(float viewport_w, float viewport_h) {
    if (!g_d3d_initialized || g_rect_count == 0) return;

    // Set viewport
    D3D11_VIEWPORT vp = {0};
    vp.TopLeftX = 0;
    vp.TopLeftY = 0;
    vp.Width = viewport_w;
    vp.Height = viewport_h;
    vp.MinDepth = 0.0f;
    vp.MaxDepth = 1.0f;
    g_d3d_context->lpVtbl->RSSetViewports(g_d3d_context, 1, &vp);

    // Map VBO + upload vertex data
    D3D11_MAPPED_SUBRESOURCE mapped = {0};
    if (SUCCEEDED(g_d3d_context->lpVtbl->Map(g_d3d_context, (ID3D11Resource*)g_rect_vbo, 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped))) {
        memcpy(mapped.pData, g_rect_verts, sizeof(D3DVertex) * g_rect_count);
        g_d3d_context->lpVtbl->Unmap(g_d3d_context, (ID3D11Resource*)g_rect_vbo, 0);
    }

    // Update viewport constant buffer
    float viewport_data[2] = { viewport_w, viewport_h };
    if (SUCCEEDED(g_d3d_context->lpVtbl->Map(g_d3d_context, (ID3D11Resource*)g_viewport_cb, 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped))) {
        memcpy(mapped.pData, viewport_data, sizeof(viewport_data));
        g_d3d_context->lpVtbl->Unmap(g_d3d_context, (ID3D11Resource*)g_viewport_cb, 0);
    }

    // Set pipeline
    g_d3d_context->lpVtbl->VSSetShader(g_d3d_context, g_rect_vs, NULL, 0);
    g_d3d_context->lpVtbl->PSSetShader(g_d3d_context, g_rect_ps, NULL, 0);
    g_d3d_context->lpVtbl->VSSetConstantBuffers(g_d3d_context, 0, 1, &g_viewport_cb);

    UINT stride = sizeof(D3DVertex);
    UINT offset = 0;
    g_d3d_context->lpVtbl->IASetVertexBuffers(g_d3d_context, 0, 1, &g_rect_vbo, &stride, &offset);
    g_d3d_context->lpVtbl->IASetInputLayout(g_d3d_context, g_input_layout);
    g_d3d_context->lpVtbl->IASetPrimitiveTopology(g_d3d_context, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);

    // Draw batched rects
    g_d3d_context->lpVtbl->Draw(g_d3d_context, g_rect_count, 0);

    g_rect_count = 0;
}

// --- Present (VSync via DXGI) ---

void forge_gpu_d3d11_present(void) {
    if (g_swap_chain) {
        // SyncInterval=1 = VSync on, 0 = VSync off
        g_swap_chain->lpVtbl->Present(g_swap_chain, 1, 0);
    }
}

// --- Clear ---

void forge_gpu_d3d11_clear(float r, float g, float b, float a) {
    if (g_d3d_context && g_rtv) {
        float color[4] = { r, g, b, a };
        g_d3d_context->lpVtbl->ClearRenderTargetView(g_d3d_context, g_rtv, color);
    }
}

// --- Check availability ---

int forge_gpu_d3d11_available(void) {
    // D3D11 is available on Windows 7+ with DXGI 1.0+
    return 1;
}

#else // !_WIN32

// Stubs for non-Windows platforms
int forge_gpu_d3d11_init(void* hwnd) { (void)hwnd; return 0; }
void forge_gpu_d3d11_draw_rect(float x, float y, float w, float h, float r, float g, float b, float a) { (void)x; (void)y; (void)w; (void)h; (void)r; (void)g; (void)b; (void)a; }
void forge_gpu_d3d11_flush(float vw, float vh) { (void)vw; (void)vh; }
void forge_gpu_d3d11_present(void) {}
void forge_gpu_d3d11_clear(float r, float g, float b, float a) { (void)r; (void)g; (void)b; (void)a; }
int forge_gpu_d3d11_available(void) { return 0; }

#endif // _WIN32
