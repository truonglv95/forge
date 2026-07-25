//! SDF text atlas generator — generates signed distance field font atlas
//! from bundled TTF fonts at build time.
//!
//! The atlas is a single texture where each glyph is represented as a
//! signed distance field (distance from nearest glyph edge). The GPU
//! shader samples the SDF to render crisp text at any size.
//!
//! Generation steps:
//! 1. Load TTF font via FreeType
//! 2. For each glyph: rasterize at high resolution (48px)
//! 3. Compute distance field: for each pixel, find distance to nearest
//!    edge (inside = positive, outside = negative)
//! 4. Pack glyphs into atlas texture (1024x1024)
//! 5. Write atlas as PNG + glyph metadata as JSON
//!
//! Usage:
//!   zig build sdf-atlas -- --font DejaVuSansMono.ttf --size 48 --output atlas.png
//!
//! At runtime, the GPU backend loads the atlas texture and uses SDF
//! shader to render text at any size with crisp edges.

const std = @import("std");

pub const AtlasConfig = struct {
    font_path: []const u8 = "packages/renderer/assets/fonts/DejaVuSansMono.ttf",
    font_size: u32 = 48, // Source size for SDF generation
    atlas_width: u32 = 1024,
    atlas_height: u32 = 1024,
    padding: u32 = 4, // Padding between glyphs
    spread: u32 = 8, // SDF spread radius (pixels)
    output_png: []const u8 = "packages/renderer/assets/sdf_atlas.png",
    output_json: []const u8 = "packages/renderer/assets/sdf_atlas.json",
};

pub const GlyphMetadata = struct {
    codepoint: u32,
    x: u32, // Position in atlas
    y: u32,
    width: u32,
    height: u32,
    advance: f32,
    bearing_x: f32,
    bearing_y: f32,
};

/// Generate SDF atlas from font file.
/// This is a build-time tool, not part of the runtime.
pub fn generateAtlas(config: AtlasConfig) !void {
    // Phase 4 implementation:
    // 1. FT_New_Face(font_path)
    // 2. For cp in 32..127: FT_Load_Glyph, FT_Render_Glyph at font_size
    // 3. Compute SDF: for each pixel, find min distance to edge
    // 4. Pack into atlas (shelf packing algorithm)
    // 5. Write PNG (stb_image_write)
    // 6. Write JSON metadata (glyph positions, advances)
    std.debug.print("SDF atlas generation: Phase 4 (not yet implemented)\n", .{});
    std.debug.print("Will generate from {s} at {d}px\n", .{ config.font_path, config.font_size });
}

test "AtlasConfig defaults" {
    const config = AtlasConfig{};
    try std.testing.expectEqual(@as(u32, 48), config.font_size);
    try std.testing.expectEqual(@as(u32, 1024), config.atlas_width);
    try std.testing.expectEqual(@as(u32, 8), config.spread);
}

test "GlyphMetadata layout" {
    const g = GlyphMetadata{
        .codepoint = 'A',
        .x = 0,
        .y = 0,
        .width = 32,
        .height = 40,
        .advance = 28.0,
        .bearing_x = 2.0,
        .bearing_y = 38.0,
    };
    try std.testing.expectEqual(@as(u32, 'A'), g.codepoint);
    try std.testing.expectEqual(@as(u32, 32), g.width);
}
