// TUI Theme Engine - Light/Dark/Custom themes with True Color support
const std = @import("std");
const Cell = @import("cell_buffer.zig").Cell;
const Color = @import("cell_buffer.zig").Color;

pub const ThemePreset = enum {
    dark,
    light,
    custom,
};

pub const ThemeColors = struct {
    // UI Elements
    background: Color = .default,
    foreground: Color = .default,
    
    // Status Bar
    status_bar_bg: Color = .default,
    status_bar_fg: Color = .default,
    
    // Input Field
    input_bg: Color = .default,
    input_fg: Color = .default,
    input_cursor: Color = .default,
    
    // Messages
    user_msg_bg: Color = .default,
    user_msg_fg: Color = .default,
    assistant_msg_bg: Color = .default,
    assistant_msg_fg: Color = .default,
    system_msg_bg: Color = .default,
    system_msg_fg: Color = .default,
    
    // Highlights
    selection_bg: Color = .default,
    selection_fg: Color = .default,
    error_bg: Color = .default,
    error_fg: Color = .default,
    warning_bg: Color = .default,
    warning_fg: Color = .default,
    success_bg: Color = .default,
    success_fg: Color = .default,
    
    // Borders
    border: Color = .default,
    
    pub fn darkDefault() ThemeColors {
        return .{
            .background = .{ .true_color = .{ .r = 30, .g = 30, .b = 30 } },
            .foreground = .{ .true_color = .{ .r = 220, .g = 220, .b = 220 } },
            
            .status_bar_bg = .{ .true_color = .{ .r = 50, .g = 50, .b = 50 } },
            .status_bar_fg = .{ .true_color = .{ .r = 200, .g = 200, .b = 200 } },
            
            .input_bg = .{ .true_color = .{ .r = 40, .g = 40, .b = 40 } },
            .input_fg = .{ .true_color = .{ .r = 255, .g = 255, .b = 255 } },
            .input_cursor = .{ .true_color = .{ .r = 100, .g = 200, .b = 255 } },
            
            .user_msg_bg = .{ .true_color = .{ .r = 40, .g = 40, .b = 60 } },
            .user_msg_fg = .{ .true_color = .{ .r = 200, .g = 200, .b = 255 } },
            .assistant_msg_bg = .{ .true_color = .{ .r = 35, .g = 35, .b = 35 } },
            .assistant_msg_fg = .{ .true_color = .{ .r = 220, .g = 220, .b = 220 } },
            .system_msg_bg = .{ .true_color = .{ .r = 30, .g = 30, .b = 30 } },
            .system_msg_fg = .{ .true_color = .{ .r = 150, .g = 150, .b = 150 } },
            
            .selection_bg = .{ .true_color = .{ .r = 60, .g = 60, .b = 100 } },
            .selection_fg = .{ .true_color = .{ .r = 255, .g = 255, .b = 255 } },
            .error_bg = .{ .true_color = .{ .r = 80, .g = 30, .b = 30 } },
            .error_fg = .{ .true_color = .{ .r = 255, .g = 100, .b = 100 } },
            .warning_bg = .{ .true_color = .{ .r = 80, .g = 60, .b = 20 } },
            .warning_fg = .{ .true_color = .{ .r = 255, .g = 200, .b = 100 } },
            .success_bg = .{ .true_color = .{ .r = 30, .g = 60, .b = 30 } },
            .success_fg = .{ .true_color = .{ .r = 100, .g = 255, .b = 100 } },
            
            .border = .{ .true_color = .{ .r = 80, .g = 80, .b = 80 } },
        };
    }
    
    pub fn lightDefault() ThemeColors {
        return .{
            .background = .{ .true_color = .{ .r = 255, .g = 255, .b = 255 } },
            .foreground = .{ .true_color = .{ .r = 30, .g = 30, .b = 30 } },
            
            .status_bar_bg = .{ .true_color = .{ .r = 220, .g = 220, .b = 220 } },
            .status_bar_fg = .{ .true_color = .{ .r = 50, .g = 50, .b = 50 } },
            
            .input_bg = .{ .true_color = .{ .r = 240, .g = 240, .b = 240 } },
            .input_fg = .{ .true_color = .{ .r = 0, .g = 0, .b = 0 } },
            .input_cursor = .{ .true_color = .{ .r = 0, .g = 100, .b = 200 } },
            
            .user_msg_bg = .{ .true_color = .{ .r = 230, .g = 230, .b = 255 } },
            .user_msg_fg = .{ .true_color = .{ .r = 30, .g = 30, .b = 100 } },
            .assistant_msg_bg = .{ .true_color = .{ .r = 250, .g = 250, .b = 250 } },
            .assistant_msg_fg = .{ .true_color = .{ .r = 30, .g = 30, .b = 30 } },
            .system_msg_bg = .{ .true_color = .{ .r = 255, .g = 255, .b = 255 } },
            .system_msg_fg = .{ .true_color = .{ .r = 100, .g = 100, .b = 100 } },
            
            .selection_bg = .{ .true_color = .{ .r = 180, .g = 200, .b = 255 } },
            .selection_fg = .{ .true_color = .{ .r = 0, .g = 0, .b = 0 } },
            .error_bg = .{ .true_color = .{ .r = 255, .g = 200, .b = 200 } },
            .error_fg = .{ .true_color = .{ .r = 180, .g = 0, .b = 0 } },
            .warning_bg = .{ .true_color = .{ .r = 255, .g = 240, .b = 200 } },
            .warning_fg = .{ .true_color = .{ .r = 180, .g = 100, .b = 0 } },
            .success_bg = .{ .true_color = .{ .r = 200, .g = 255, .b = 200 } },
            .success_fg = .{ .true_color = .{ .r = 0, .g = 100, .b = 0 } },
            
            .border = .{ .true_color = .{ .r = 180, .g = 180, .b = 180 } },
        };
    }
};

pub const Theme = struct {
    name: []const u8,
    preset: ThemePreset,
    colors: ThemeColors,

    const Self = @This();

    pub fn init(name: []const u8, preset: ThemePreset) Self {
        const colors = switch (preset) {
            .dark => ThemeColors.darkDefault(),
            .light => ThemeColors.lightDefault(),
            .custom => ThemeColors{},
        };
        return .{
            .name = name,
            .preset = preset,
            .colors = colors,
        };
    }

    pub fn loadFromFile(self: *Self, path: []const u8, allocator: std.mem.Allocator) !void {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(content);

        // Simple JSON-like parsing (can be enhanced later)
        _ = content;
        // TODO: Parse custom theme config
    }

    pub fn apply(self: *const Self, cell: *Cell, role: []const u8) void {
        const c = self.colors;
        
        if (std.mem.eql(u8, role, "background")) {
            cell.bg = c.background;
            cell.fg = c.foreground;
        } else if (std.mem.eql(u8, role, "status_bar")) {
            cell.bg = c.status_bar_bg;
            cell.fg = c.status_bar_fg;
        } else if (std.mem.eql(u8, role, "input")) {
            cell.bg = c.input_bg;
            cell.fg = c.input_fg;
        } else if (std.mem.eql(u8, role, "user_msg")) {
            cell.bg = c.user_msg_bg;
            cell.fg = c.user_msg_fg;
        } else if (std.mem.eql(u8, role, "assistant_msg")) {
            cell.bg = c.assistant_msg_bg;
            cell.fg = c.assistant_msg_fg;
        } else if (std.mem.eql(u8, role, "system_msg")) {
            cell.bg = c.system_msg_bg;
            cell.fg = c.system_msg_fg;
        } else if (std.mem.eql(u8, role, "selection")) {
            cell.bg = c.selection_bg;
            cell.fg = c.selection_fg;
        } else if (std.mem.eql(u8, role, "error")) {
            cell.bg = c.error_bg;
            cell.fg = c.error_fg;
        } else if (std.mem.eql(u8, role, "warning")) {
            cell.bg = c.warning_bg;
            cell.fg = c.warning_fg;
        } else if (std.mem.eql(u8, role, "success")) {
            cell.bg = c.success_bg;
            cell.fg = c.success_fg;
        } else if (std.mem.eql(u8, role, "border")) {
            cell.bg = c.background;
            cell.fg = c.border;
        }
    }
};

pub const ThemeManager = struct {
    current_theme: Theme,
    themes: std.AutoHashMap([]const u8, Theme),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .current_theme = Theme.init("dark", .dark),
            .themes = std.AutoHashMap([]const u8, Theme).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.themes.deinit();
    }

    pub fn registerTheme(self: *Self, name: []const u8, theme: Theme) !void {
        try self.themes.put(name, theme);
    }

    pub fn setTheme(self: *Self, name: []const u8) !void {
        if (self.themes.getPtr(name)) |theme| {
            self.current_theme = theme.*;
        } else if (std.mem.eql(u8, name, "dark")) {
            self.current_theme = Theme.init("dark", .dark);
        } else if (std.mem.eql(u8, name, "light")) {
            self.current_theme = Theme.init("light", .light);
        } else {
            return error.ThemeNotFound;
        }
    }

    pub fn getCurrentTheme(self: *const Self) *const Theme {
        return &self.current_theme;
    }
};

test "Theme creation" {
    var dark = Theme.init("dark", .dark);
    try std.testing.expectEqualStrings("dark", dark.name);
    try std.testing.expectEqual(ThemePreset.dark, dark.preset);
    
    var light = Theme.init("light", .light);
    try std.testing.expectEqualStrings("light", light.name);
    try std.testing.expectEqual(ThemePreset.light, light.preset);
}

test "Theme Manager" {
    const allocator = std.testing.allocator;
    var manager = ThemeManager.init(allocator);
    defer manager.deinit();
    
    try manager.setTheme("light");
    try std.testing.expectEqualStrings("light", manager.current_theme.name);
    
    try manager.setTheme("dark");
    try std.testing.expectEqualStrings("dark", manager.current_theme.name);
}
