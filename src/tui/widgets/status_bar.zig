//! Status Bar widget

const std = @import("std");
const layouts = @import("../layouts/layouts.zig");
const theme = @import("../theme/theme.zig");
const state = @import("../state/state.zig");

pub const StatusBar = struct {
    rect: layouts.Rect,
    mode: state.AppMode,
    message: ?[]const u8,
    filename: ?[]const u8,
    position: struct { line: usize, col: usize } = .{ .line = 1, .col = 1 },
    palette: theme.ColorScheme.Palette,
    allocator: Allocator,

    pub fn init(allocator: Allocator) StatusBar {
        return .{
            .rect = Rect{ .x = 0, .y = 0, .width = 0, .height = 1 },
            .mode = .normal,
            .message = null,
            .filename = null,
            .palette = theme.ColorScheme.dark.getPalette(),
            .allocator = allocator,
        };
    }

    pub fn setMode(self: *StatusBar, mode: state.AppMode) void {
        self.mode = mode;
    }

    pub fn setMessage(self: *StatusBar, msg: []const u8) void {
        self.message = msg;
    }

    pub fn clearMessage(self: *StatusBar) void {
        self.message = null;
    }

    pub fn render(self: *const StatusBar, writer: anytype) !void {
        // Mode indicator
        const mode_str = switch (self.mode) {
            .normal => "NORMAL",
            .insert => "INSERT",
            .command => "COMMAND",
            .search => "SEARCH",
            .help => "HELP",
            .chat => "CHAT",
            .file_picker => "FILE PICKER",
        };

        try writer.writeAll("\x1b[7m"); // Reverse video
        try writer.writeAll(" ");
        try writer.writeAll(mode_str);
        try writer.writeAll(" ");

        // Filename
        if (self.filename) |fn| {
            try writer.writeAll(" | ");
            try writer.writeAll(fn);
        }

        // Position
        try writer.writeAll(std.fmt.allocPrint(
            self.allocator,
            " | Line {d}, Col {d}",
            .{ self.position.line, self.position.col },
        ) catch "");

        // Message
        if (self.message) |msg| {
            try writer.writeAll(" | ");
            try writer.writeAll(msg);
        }

        // Fill rest of line
        try writer.writeAll("\x1b[0K");
        try writer.writeAll("\x1b[0m");
    }
};
