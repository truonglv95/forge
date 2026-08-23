//! Theme System for Forge TUI
//! 
//! Provides color schemes, styling, and theme management for the TUI.

const std = @import("std");

/// ANSI Color codes
pub const Color = union(enum) {
    reset,
    black,
    red,
    green,
    yellow,
    blue,
    magenta,
    cyan,
    white,
    bright_black,
    bright_red,
    bright_green,
    bright_yellow,
    bright_blue,
    bright_magenta,
    bright_cyan,
    bright_white,
    rgb: struct { r: u8, g: u8, b: u8 },
    indexed: u8,

    pub fn toAnsi(self: Color) []const u8 {
        return switch (self) {
            .reset => "\x1b[0m",
            .black => "\x1b[30m",
            .red => "\x1b[31m",
            .green => "\x1b[32m",
            .yellow => "\x1b[33m",
            .blue => "\x1b[34m",
            .magenta => "\x1b[35m",
            .cyan => "\x1b[36m",
            .white => "\x1b[37m",
            .bright_black => "\x1b[90m",
            .bright_red => "\x1b[91m",
            .bright_green => "\x1b[92m",
            .bright_yellow => "\x1b[93m",
            .bright_blue => "\x1b[94m",
            .bright_magenta => "\x1b[95m",
            .bright_cyan => "\x1b[96m",
            .bright_white => "\x1b[97m",
            .rgb => |c| blk: {
                break :blk std.fmt.allocPrint(std.heap.page_allocator, "\x1b[38;2;{};{};{}m", .{ c.r, c.g, c.b }) catch unreachable;
            },
            .indexed => |idx| blk: {
                break :blk std.fmt.allocPrint(std.heap.page_allocator, "\x1b[38;5;{}m", .{idx}) catch unreachable;
            },
        };
    }
};

/// Text attributes
pub const Attr = packed struct {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    blink: bool = false,
    reverse: bool = false,
    hidden: bool = false,
    strikethrough: bool = false,

    pub fn toAnsi(self: Attr) []const u8 {
        var buf: [64]u8 = undefined;
        var pos: usize = 0;
        
        const codes = [_]struct { flag: bool, code: []const u8 }{
            .{ .flag = self.bold, .code = "1" },
            .{ .flag = self.dim, .code = "2" },
            .{ .flag = self.italic, .code = "3" },
            .{ .flag = self.underline, .code = "4" },
            .{ .flag = self.blink, .code = "5" },
            .{ .flag = self.reverse, .code = "7" },
            .{ .flag = self.hidden, .code = "8" },
            .{ .flag = self.strikethrough, .code = "9" },
        };
        
        for (codes) |c| {
            if (c.flag) {
                const s = std.fmt.bufPrint(buf[pos..], "{s};", .{c.code}) catch break;
                pos += s.len;
            }
        }
        
        if (pos > 0) {
            buf[pos - 1] = 'm';
            return buf[0..pos];
        }
        return "";
    }
};

/// Style combines color and attributes
pub const Style = struct {
    fg: ?Color = null,
    bg: ?Color = null,
    attr: Attr = .{},

    pub fn render(self: Style) void {
        if (self.fg) |c| _ = std.io.getStdOut().write(c.toAnsi()) catch {};
        if (self.bg) |c| _ = std.io.getStdOut().write(c.toAnsi()) catch {};
        _ = std.io.getStdOut().write(self.attr.toAnsi()) catch {};
    }

    pub fn reset() void {
        _ = std.io.getStdOut().write(Color.reset.toAnsi()) catch {};
    }
};

/// Predefined color schemes
pub const ColorScheme = enum {
    dark,
    light,
    monokai,
    dracula,
    nord,
    gruvbox,

    pub fn getTheme(self: ColorScheme) Theme {
        return switch (self) {
            .dark => Theme.dark(),
            .light => Theme.light(),
            .monokai => Theme.monokai(),
            .dracula => Theme.dracula(),
            .nord => Theme.nord(),
            .gruvbox => Theme.gruvbox(),
        };
    }
};

/// Complete theme definition
pub const Theme = struct {
    name: []const u8,
    background: Color,
    foreground: Color,
    
    // UI colors
    primary: Color,
    secondary: Color,
    accent: Color,
    success: Color,
    warning: Color,
    error: Color,
    
    // Syntax highlighting
    keyword: Color,
    string: Color,
    number: Color,
    comment: Color,
    function: Color,
    type_: Color,
    variable: Color,
    
    // Component styles
    panel_bg: Color,
    border: Color,
    selected_bg: Color,
    selected_fg: Color,
    hover_bg: Color,

    pub fn dark() Theme {
        return .{
            .name = "Dark",
            .background = .rgb = .{ .r = 30, .g = 30, .b = 30 },
            .foreground = .rgb = .{ .r = 220, .g = 220, .b = 220 },
            .primary = .blue,
            .secondary = .cyan,
            .accent = .magenta,
            .success = .green,
            .warning = .yellow,
            .error = .red,
            .keyword = .magenta,
            .string = .green,
            .number = .cyan,
            .comment = .bright_black,
            .function = .blue,
            .type_ = .yellow,
            .variable = .white,
            .panel_bg = .rgb = .{ .r = 40, .g = 40, .b = 40 },
            .border = .bright_black,
            .selected_bg = .rgb = .{ .r = 60, .g = 60, .b = 80 },
            .selected_fg = .bright_white,
            .hover_bg = .rgb = .{ .r = 50, .g = 50, .b = 50 },
        };
    }

    pub fn light() Theme {
        return .{
            .name = "Light",
            .background = .white,
            .foreground = .black,
            .primary = .blue,
            .secondary = .cyan,
            .accent = .magenta,
            .success = .green,
            .warning = .yellow,
            .error = .red,
            .keyword = .blue,
            .string = .green,
            .number = .cyan,
            .comment = .bright_black,
            .function = .blue,
            .type_ = .yellow,
            .variable = .black,
            .panel_bg = .rgb = .{ .r = 245, .g = 245, .b = 245 },
            .border = .bright_black,
            .selected_bg = .rgb = .{ .r = 200, .g = 220, .b = 255 },
            .selected_fg = .black,
            .hover_bg = .rgb = .{ .r = 230, .g = 230, .b = 230 },
        };
    }

    pub fn monokai() Theme {
        return .{
            .name = "Monokai",
            .background = .rgb = .{ .r = 39, .g = 40, .b = 34 },
            .foreground = .rgb = .{ .r = 248, .g = 248, .b = 242 },
            .primary = .rgb = .{ .r = 102, .g = 217, .b = 239 },
            .secondary = .rgb = .{ .r = 166, .g = 226, .b = 46 },
            .accent = .rgb = .{ .r = 174, .g = 129, .b = 255 },
            .success = .rgb = .{ .r = 166, .g = 226, .b = 46 },
            .warning = .rgb = .{ .r = 230, .g = 219, .b = 116 },
            .error = .rgb = .{ .r = 249, .g = 38, .b = 114 },
            .keyword = .rgb = .{ .r = 249, .g = 38, .b = 114 },
            .string = .rgb = .{ .r = 230, .g = 219, .b = 116 },
            .number = .rgb = .{ .r = 174, .g = 129, .b = 255 },
            .comment = .rgb = .{ .r = 117, .g = 113, .b = 94 },
            .function = .rgb = .{ .r = 102, .g = 217, .b = 239 },
            .type_ = .rgb = .{ .r = 230, .g = 219, .b = 116 },
            .variable = .rgb = .{ .r = 248, .g = 248, .b = 242 },
            .panel_bg = .rgb = .{ .r = 50, .g = 50, .b = 44 },
            .border = .rgb = .{ .r = 117, .g = 113, .b = 94 },
            .selected_bg = .rgb = .{ .r = 68, .g = 68, .b = 62 },
            .selected_fg = .rgb = .{ .r = 248, .g = 248, .b = 242 },
            .hover_bg = .rgb = .{ .r = 60, .g = 60, .b = 54 },
        };
    }

    pub fn dracula() Theme {
        return .{
            .name = "Dracula",
            .background = .rgb = .{ .r = 40, .g = 42, .b = 54 },
            .foreground = .rgb = .{ .r = 248, .g = 248, .b = 242 },
            .primary = .rgb = .{ .r = 80, .g = 250, .b = 123 },
            .secondary = .rgb = .{ .r = 139, .g = 233, .b = 253 },
            .accent = .rgb = .{ .r = 189, .g = 147, .b = 249 },
            .success = .rgb = .{ .r = 80, .g = 250, .b = 123 },
            .warning = .rgb = .{ .r = 241, .g = 250, .b = 140 },
            .error = .rgb = .{ .r = 255, .g = 85, .b = 85 },
            .keyword = .rgb = .{ .r = 255, .g = 121, .b = 198 },
            .string = .rgb = .{ .r = 241, .g = 250, .b = 140 },
            .number = .rgb = .{ .r = 189, .g = 147, .b = 249 },
            .comment = .rgb = .{ .r = 98, .g = 114, .b = 164 },
            .function = .rgb = .{ .r = 80, .g = 250, .b = 123 },
            .type_ = .rgb = .{ .r = 139, .g = 233, .b = 253 },
            .variable = .rgb = .{ .r = 248, .g = 248, .b = 242 },
            .panel_bg = .rgb = .{ .r = 50, .g = 52, .b = 64 },
            .border = .rgb = .{ .r = 98, .g = 114, .b = 164 },
            .selected_bg = .rgb = .{ .r = 68, .g = 70, .b = 84 },
            .selected_fg = .rgb = .{ .r = 248, .g = 248, .b = 242 },
            .hover_bg = .rgb = .{ .r = 60, .g = 62, .b = 74 },
        };
    }

    pub fn nord() Theme {
        return .{
            .name = "Nord",
            .background = .rgb = .{ .r = 46, .g = 52, .b = 64 },
            .foreground = .rgb = .{ .r = 216, .g = 222, .b = 233 },
            .primary = .rgb = .{ .r = 129, .g = 162, .b = 190 },
            .secondary = .rgb = .{ .r = 163, .g = 190, .b = 140 },
            .accent = .rgb = .{ .r = 180, .g = 142, .b = 173 },
            .success = .rgb = .{ .r = 163, .g = 190, .b = 140 },
            .warning = .rgb = .{ .r = 235, .g = 203, .b = 139 },
            .error = .rgb = .{ .r = 191, .g = 97, .b = 106 },
            .keyword = .rgb = .{ .r = 191, .g = 97, .b = 106 },
            .string = .rgb = .{ .r = 163, .g = 190, .b = 140 },
            .number = .rgb = .{ .r = 180, .g = 142, .b = 173 },
            .comment = .rgb = .{ .r = 94, .g = 109, .b = 128 },
            .function = .rgb = .{ .r = 129, .g = 162, .b = 190 },
            .type_ = .rgb = .{ .r = 235, .g = 203, .b = 139 },
            .variable = .rgb = .{ .r = 216, .g = 222, .b = 233 },
            .panel_bg = .rgb = .{ .r = 56, .g = 62, .b = 74 },
            .border = .rgb = .{ .r = 94, .g = 109, .b = 128 },
            .selected_bg = .rgb = .{ .r = 66, .g = 72, .b = 84 },
            .selected_fg = .rgb = .{ .r = 216, .g = 222, .b = 233 },
            .hover_bg = .rgb = .{ .r = 60, .g = 66, .b = 78 },
        };
    }

    pub fn gruvbox() Theme {
        return .{
            .name = "Gruvbox",
            .background = .rgb = .{ .r = 40, .g = 40, .b = 40 },
            .foreground = .rgb = .{ .r = 235, .g = 219, .b = 178 },
            .primary = .rgb = .{ .r = 131, .g = 165, .b = 152 },
            .secondary = .rgb = .{ .r = 215, .g = 153, .b = 33 },
            .accent = .rgb = .{ .r = 213, .g = 154, .b = 138 },
            .success = .rgb = .{ .r = 152, .g = 195, .b = 121 },
            .warning = .rgb = .{ .r = 254, .g = 128, .b = 25 },
            .error = .rgb = .{ .r = 204, .g = 36, .b = 29 },
            .keyword = .rgb = .{ .r = 251, .g = 173, .b = 97 },
            .string = .rgb = .{ .r = 184, .g = 187, .b = 38 },
            .number = .rgb = .{ .r = 217, .g = 121, .b = 121 },
            .comment = .rgb = .{ .r = 146, .g = 131, .b = 116 },
            .function = .rgb = .{ .r = 131, .g = 165, .b = 152 },
            .type_ = .rgb = .{ .r = 254, .g = 128, .b = 25 },
            .variable = .rgb = .{ .r = 235, .g = 219, .b = 178 },
            .panel_bg = .rgb = .{ .r = 50, .g = 50, .b = 50 },
            .border = .rgb = .{ .r = 146, .g = 131, .b = 116 },
            .selected_bg = .rgb = .{ .r = 60, .g = 60, .b = 60 },
            .selected_fg = .rgb = .{ .r = 235, .g = 219, .b = 178 },
            .hover_bg = .rgb = .{ .r = 55, .g = 55, .b = 55 },
        };
    }
};

test "Theme creation" {
    const dark = Theme.dark();
    try std.testing.expectEqualStrings("Dark", dark.name);
    
    const light = Theme.light();
    try std.testing.expectEqualStrings("Light", light.name);
}
