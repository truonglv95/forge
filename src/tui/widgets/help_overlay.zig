//! Help Overlay widget - Keyboard shortcuts reference

const std = @import("std");
const layouts = @import("../layouts/layouts.zig");

pub const Shortcut = struct {
    keys: []const u8,
    description: []const u8,
};

pub const HelpOverlay = struct {
    rect: layouts.Rect,
    visible: bool = false,
    shortcuts: std.ArrayList(Shortcut),
    scroll_offset: usize = 0,
    allocator: Allocator,

    pub fn init(allocator: Allocator) HelpOverlay {
        return .{
            .rect = Rect{ .x = 0, .y = 0, .width = 0, .height = 0 },
            .shortcuts = std.ArrayList(Shortcut).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *HelpOverlay) void {
        self.shortcuts.deinit();
    }

    pub fn addShortcut(self: *HelpOverlay, keys: []const u8, desc: []const u8) !void {
        try self.shortcuts.append(.{ .keys = keys, .description = desc });
    }

    pub fn toggle(self: *HelpOverlay) void {
        self.visible = !self.visible;
    }

    pub fn render(self: *const HelpOverlay, writer: anytype) !void {
        if (!self.visible) return;

        try writer.writeAll("\x1b[2J\x1b[H");
        try writer.writeAll("\x1b[1m=== Keyboard Shortcuts ===\x1b[0m\n\n");

        for (self.shortcuts.items) |sc| {
            try writer.writeAll("\x1b[36m");
            try writer.writeAll(sc.keys);
            try writer.writeAll("\x1b[0m  ");
            try writer.writeAll(sc.description);
            try writer.writeAll("\n");
        }

        try writer.writeAll("\n\x1b[90mPress 'h' or ESC to close\x1b[0m\n");
    }
};
