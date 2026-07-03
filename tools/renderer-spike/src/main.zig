const std = @import("std");

const mac = @cImport({
    @cInclude("mac_window.h");
});

pub fn main() !void {
    std.debug.print("Starting Forge Native Renderer Spike...\n", .{});
    
    mac.forge_mac_init();
    
    // Demonstrate CoreText via wrapper
    mac.forge_mac_shape_text("Hello Forge 🇻🇳 🚀");

    mac.forge_mac_create_window("Forge Native MVP", 800, 600);
    
    std.debug.print("Window created, entering event loop...\n", .{});
    mac.forge_mac_run();
}
