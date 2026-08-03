const std = @import("std");
const renderer = @import("forge-renderer");
const theme_loader = @import("../../theme_loader.zig");

pub fn color(rgba: @import("forge-workspace").Rgba) renderer.Color {
    return theme_loader.toColor(rgba);
}
