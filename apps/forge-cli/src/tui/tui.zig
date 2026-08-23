//! Forge TUI - Modern Terminal User Interface Framework
//! 
//! Phase 1: Foundation - Core TUI infrastructure and rendering engine
//! 
//! This module provides the foundational components for building a modern,
//! responsive terminal user interface for the Forge CLI.

const std = @import("std");
const builtin = @import("builtin");

// Theme system
pub const theme = @import("theme/theme.zig");
pub const Theme = theme.Theme;
pub const ColorScheme = theme.ColorScheme;

// Layout system
pub const layouts = @import("layouts/layouts.zig");
pub const Layout = layouts.Layout;
pub const FlexBox = layouts.FlexBox;
pub const Grid = layouts.Grid;

// State management
pub const state = @import("state/state.zig");
pub const AppState = state.AppState;
pub const FocusState = state.FocusState;

// Core components
pub const components = @import("components/components.zig");
pub const Component = components.Component;
pub const InputHandler = components.InputHandler;
pub const EventLoop = components.EventLoop;

// Widgets
pub const widgets = @import("widgets/widgets.zig");
pub const Widget = widgets.Widget;
pub const FuzzyFinder = widgets.FuzzyFinder;
pub const CommandPalette = widgets.CommandPalette;
pub const StatusBar = widgets.StatusBar;
pub const HelpOverlay = widgets.HelpOverlay;
pub const ChatPanel = widgets.ChatPanel;
pub const FileTree = widgets.FileTree;

// Rendering engine
pub const Renderer = @import("renderer.zig").Renderer;

/// TUI Application configuration
pub const Config = struct {
    theme: Theme,
    layout: Layout,
    enable_mouse: bool = true,
    enable_vim_mode: bool = true,
    fps_target: u32 = 60,
    buffer_size: usize = 4096,
};

/// Main TUI Application entry point
pub fn run(comptime AppType: type, config: Config) !void {
    var app = try AppType.init(config);
    defer app.deinit();
    
    var renderer = Renderer.init(std.io.getStdWriter(), config.theme);
    defer renderer.deinit();
    
    var event_loop = EventLoop.init(config.enable_mouse);
    defer event_loop.deinit();
    
    while (!app.should_quit) {
        // Process events
        if (event_loop.poll()) |event| {
            try app.handleEvent(event);
        }
        
        // Update application state
        try app.update();
        
        // Render frame
        try renderer.render(&app);
        try renderer.flush();
    }
}

test "TUI module imports" {
    _ = Theme;
    _ = Layout;
    _ = AppState;
    _ = Component;
    _ = Widget;
    _ = Renderer;
}
