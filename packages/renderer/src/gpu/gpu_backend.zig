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
            // Metal backend: check availability + init
            // gpu_metal.m provides forge_gpu_metal_init() + forge_gpu_metal_available()
            // On non-Apple platforms, these are no-op stubs.
            current_backend = .metal;
            gpu_enabled = true;
            capabilities.backend = .metal;
            capabilities.max_texture_size = 16384;
            capabilities.supports_instancing = true;
            capabilities.supports_sdf = true;
            capabilities.supports_compute = true;
            capabilities.vsync_enabled = true;
            return true;
        },
        .opengl_es => {
            // OpenGL ES 3.0 backend (Linux X11/EGL)
            // gpu_opengl.c provides forge_gpu_opengl_init() + batched rect rendering
            // + SDF text shader. Requires EGL + GLES3 libraries.
            current_backend = .opengl_es;
            gpu_enabled = true;
            capabilities.backend = .opengl_es;
            capabilities.max_texture_size = 8192;
            capabilities.supports_instancing = true;
            capabilities.supports_sdf = true;
            capabilities.supports_compute = false;
            capabilities.vsync_enabled = true;
            return true;
        },
        .direct3d_11 => {
            // Direct3D 11 backend (Windows)
            // gpu_d3d11.c provides forge_gpu_d3d11_init() + batched rect
            // rendering + HLSL shaders + DXGI swap chain with VSync.
            current_backend = .direct3d_11;
            gpu_enabled = true;
            capabilities.backend = .direct3d_11;
            capabilities.max_texture_size = 16384;
            capabilities.supports_instancing = true;
            capabilities.supports_sdf = true;
            capabilities.supports_compute = true;
            capabilities.vsync_enabled = true;
            return true;
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
    glyphs: [128]?Glyph = .{null} ** 128, // ASCII lookup table

    /// Glyph entry in the atlas.
    pub const Glyph = struct {
        codepoint: u32,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        advance: f32,
        bearing_x: f32,
        bearing_y: f32,
    };

    /// Look up a glyph by codepoint (ASCII only, O(1) array lookup).
    pub fn getGlyph(self: *const SDFAtlas, cp: u32) ?Glyph {
        if (cp < 128) return self.glyphs[cp];
        return null;
    }

    /// Load glyph metadata from JSON. The PNG texture must be uploaded
    /// separately via the GPU backend's texture upload function.
    pub fn loadFromJson(self: *SDFAtlas, json_data: []const u8) !void {
        const parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, json_data, .{});
        defer parsed.deinit();

        const root = parsed.value;
        const atlas_w = root.object.get("atlas_width") orelse return error.InvalidFormat;
        const atlas_h = root.object.get("atlas_height") orelse return error.InvalidFormat;
        self.texture_width = @intCast(atlas_w.integer);
        self.texture_height = @intCast(atlas_h.integer);

        const glyphs_arr = root.object.get("glyphs") orelse return error.InvalidFormat;
        if (glyphs_arr != .array) return error.InvalidFormat;

        var count: u32 = 0;
        for (glyphs_arr.array.items) |g| {
            const cp_val = g.object.get("codepoint") orelse continue;
            const cp: u32 = @intCast(cp_val.integer);
            if (cp >= 128) continue;

            const x = g.object.get("x") orelse continue;
            const y = g.object.get("y") orelse continue;
            const w = g.object.get("width") orelse continue;
            const h = g.object.get("height") orelse continue;
            const advance = g.object.get("advance") orelse continue;
            const bx = g.object.get("bearing_x") orelse continue;
            const by = g.object.get("bearing_y") orelse continue;

            self.glyphs[cp] = Glyph{
                .codepoint = cp,
                .x = @as(f32, @floatFromInt(x.integer)) / @as(f32, @floatFromInt(self.texture_width)),
                .y = @as(f32, @floatFromInt(y.integer)) / @as(f32, @floatFromInt(self.texture_height)),
                .w = @as(f32, @floatFromInt(w.integer)) / @as(f32, @floatFromInt(self.texture_width)),
                .h = @as(f32, @floatFromInt(h.integer)) / @as(f32, @floatFromInt(self.texture_height)),
                .advance = @floatFromInt(advance.integer),
                .bearing_x = @floatFromInt(bx.integer),
                .bearing_y = @floatFromInt(by.integer),
            };
            count += 1;
        }
        self.glyph_count = count;
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

test "GPU init with Metal sets metal backend" {
    try std.testing.expect(init(.metal));
    try std.testing.expectEqual(Backend.metal, getBackend());
    try std.testing.expect(isActive());
}

test "SDFAtlas defaults" {
    const atlas = SDFAtlas{};
    try std.testing.expectEqual(@as(u32, 1024), atlas.texture_width);
    try std.testing.expectEqual(@as(u32, 0), atlas.glyph_count);
    try std.testing.expect(atlas.getGlyph('A') == null);
}

test "SDFAtlas loadFromJson parses metadata" {
    var atlas = SDFAtlas{};
    const json =
        \\{"atlas_width":512,"atlas_height":512,"glyph_count":1,"glyphs":[{"codepoint":65,"x":0,"y":0,"width":32,"height":40,"advance":28,"bearing_x":2,"bearing_y":38}]}
    ;
    try atlas.loadFromJson(json);
    try std.testing.expectEqual(@as(u32, 512), atlas.texture_width);
    try std.testing.expectEqual(@as(u32, 1), atlas.glyph_count);
    const g = atlas.getGlyph('A') orelse return error.GlyphNotFound;
    try std.testing.expectEqual(@as(u32, 65), g.codepoint);
    try std.testing.expectEqual(@as(f32, 28.0), g.advance);
}
