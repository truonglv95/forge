//! Forge TUI - Modern Terminal User Interface for Forge CLI
//! 
//! This package provides a complete TUI framework for building
//! interactive terminal applications with advanced features like:
//! - AI integration with streaming responses
//! - Git native operations
//! - Daemon mode for instant startup
//! - Plugin system
//! - Accessibility support
//! - High performance rendering

const std = @import("std");
const builtin = @import("builtin");

// Core modules
pub const renderer = @import("core/renderer.zig");
pub const state = @import("core/state.zig");

// UI components
pub const themes = @import("ui/themes/theme.zig");
pub const layouts = @import("ui/layouts/layouts.zig");
pub const components = @import("ui/components/components.zig");
pub const widgets = @import("ui/widgets/widgets.zig");

// Utilities
pub const perf = @import("utils/perf/optimizer.zig");
pub const a11y = @import("utils/a11y/accessibility.zig");
pub const animations = @import("utils/polish/animations.zig");

// Features (optional, may require additional dependencies)
// pub const ai = @import("features/ai/ai_engine.zig");
// pub const daemon = @import("features/daemon/daemon.zig");
// pub const git = @import("features/git/git_integration.zig");
// pub const workspace = @import("features/workspace/indexer.zig");

/// TUI version
pub const version = struct {
    pub const major: u32 = 0;
    pub const minor: u32 = 1;
    pub const patch: u32 = 0;
    
    pub fn comptime string() []const u8 {
        return "0.1.0";
    }
};

/// Initialize the TUI system
pub fn init(allocator: std.mem.Allocator) !void {
    try renderer.init(allocator);
    try state.init(allocator);
}

/// Cleanup TUI resources
pub fn deinit() void {
    renderer.deinit();
    state.deinit();
}

/// Run the main TUI event loop
pub fn run(comptime AppType: type, app: *AppType) !void {
    try app.run();
}

test "tui package structure" {
    // Verify all modules can be imported
    _ = renderer;
    _ = state;
    _ = themes;
    _ = layouts;
    _ = components;
    _ = widgets;
    _ = perf;
    _ = a11y;
    _ = animations;
}
