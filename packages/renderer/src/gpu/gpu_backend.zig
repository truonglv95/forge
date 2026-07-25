//! GPU backend interface — abstraction layer for hardware-accelerated rendering.
//!
//! RFC-0018: This module defines the GPU backend interface that replaces
//! the CPU software rendering path. Implementations:
//! - Metal (macOS) — uses existing MTKView, render via Metal command encoder
//! - OpenGL ES 3.0 (Linux X11/EGL) — GLSL shaders, VBO/VAO batching
//! - Direct3D 11 (Windows) — HLSL shaders, ID3D11DeviceContext
//!
//! The GPU backend is opt-in via `--gpu` flag. CPU fallback remains default
//! until GPU backend is verified on all platforms.
//!
//! Phase 1: Metal backend (macOS) — prototype with rect + text rendering.
//! Phase 2: OpenGL ES (Linux) — port shaders, test on X11/EGL.
//! Phase 3: Direct3D 11 (Windows) — port shaders, test on Win32.
//! Phase 4: SDF text atlas — replace FreeType per-glyph rendering.

const std = @import("std");
const backend = @import("../platform/shared/backend.h");

/// GPU backend type.
pub const Backend = enum {
    cpu, // Current software rendering (default)
    metal, // macOS Metal
    opengl_es, // Linux OpenGL ES 3.0
    direct3d_11, // Windows D3D11
};

/// GPU capabilities detected at init.
pub const Capabilities = struct {
    backend: Backend = .cpu,
    max_texture_size: u32 = 4096,
    supports_instancing: bool = false,
    supports_sdf: bool = false,
    supports_compute: bool = false,
    vsync_enabled: bool = false,
};

/// Current GPU backend state.
pub var current_backend: Backend = .cpu;
pub var capabilities: Capabilities = .{};
pub var gpu_enabled: bool = false;

/// Initialize GPU backend. Returns true if GPU rendering is available.
/// Falls back to CPU if GPU init fails.
pub fn init(backend_type: Backend) bool {
    switch (backend_type) {
        .cpu => {
            current_backend = .cpu;
            gpu_enabled = false;
            return true;
        },
        .metal => {
            // Phase 1: Metal backend prototype
            // Will be implemented in gpu_metal.m
            // For now, fall back to CPU
            current_backend = .cpu;
            gpu_enabled = false;
            return false;
        },
        .opengl_es => {
            // Phase 2: OpenGL ES backend
            // Will be implemented in gpu_opengl.c
            current_backend = .cpu;
            gpu_enabled = false;
            return false;
        },
        .direct3d_11 => {
            // Phase 3: Direct3D 11 backend
            // Will be implemented in gpu_d3d11.c
            current_backend = .cpu;
            gpu_enabled = false;
            return false;
        },
    }
}

/// Check if GPU rendering is active.
pub fn isActive() bool {
    return gpu_enabled;
}

/// Get current backend type.
pub fn getBackend() Backend {
    return current_backend;
}

/// SDF text atlas — single texture containing all glyphs as signed distance
/// fields. Generated at build time from bundled fonts.
///
/// Benefits over per-glyph cache:
/// - 1 texture upload (vs 4096 cache slots)
/// - Crisp text at any size (SDF interpolation)
/// - 10-100x faster rendering (GPU texture sampling vs CPU blend)
/// - Subpixel rendering via shader (no FT_LOAD_TARGET_LCD needed)
pub const SDFAtlas = struct {
    texture_id: u32 = 0,
    texture_width: u32 = 1024,
    texture_height: u32 = 1024,
    glyph_count: u32 = 0,

    /// Glyph entry in the atlas.
    pub const Glyph = struct {
        codepoint: u32,
        x: f32, // UV coordinates in atlas
        y: f32,
        w: f32,
        h: f32,
        advance: f32,
        bearing_x: f32,
        bearing_y: f32,
    };

    /// Look up a glyph by codepoint.
    pub fn getGlyph(self: *const SDFAtlas, cp: u32) ?Glyph {
        _ = self;
        _ = cp;
        // Phase 4: implement binary search in sorted glyph array
        return null;
    }
};

test "GPU backend defaults to CPU" {
    try std.testing.expectEqual(Backend.cpu, getBackend());
    try std.testing.expect(!isActive());
}

test "GPU init with CPU returns true" {
    try std.testing.expect(init(.cpu));
    try std.testing.expect(!isActive());
}

test "GPU init with Metal falls back to CPU (prototype)" {
    try std.testing.expect(!init(.metal));
    try std.testing.expectEqual(Backend.cpu, getBackend());
}

test "SDFAtlas defaults" {
    const atlas = SDFAtlas{};
    try std.testing.expectEqual(@as(u32, 1024), atlas.texture_width);
    try std.testing.expectEqual(@as(u32, 0), atlas.glyph_count);
    try std.testing.expect(atlas.getGlyph('A') == null);
}
