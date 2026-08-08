//! Theme system for Forge TUI
//! Supports multiple color schemes and text attributes

const std = @import("std");
const Allocator = std.mem.Allocator;

/// ANSI color codes
pub const Color = union(enum) {
    default,
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
            .default => "\x1b[39m",
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
                var buf: [20]u8 = undefined;
                const len = std.fmt.bufPrint(&buf, "\x1b[38;2;{};{};{}m", .{ c.r, c.g, c.b }) catch unreachable;
                break :blk len;
            },
            .indexed => |idx| blk: {
                var buf: [15]u8 = undefined;
                const len = std.fmt.bufPrint(&buf, "\x1b[38;5;{}m", .{idx}) catch unreachable;
                break :blk len;
            },
        };
    }
};

/// Text attributes
pub const Attribute = packed struct {
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    blink: bool = false,
    reverse: bool = false,
    hidden: bool = false,
    strikethrough: bool = false,

    pub fn toAnsi(self: Attribute) []const u8 {
        var buf: [50]u8 = undefined;
        var pos: usize = 0;

        if (self.bold) {
            const s = "\x1b[1m";
            @memcpy(buf[pos..pos + s.len], s);
            pos += s.len;
        }
        if (self.italic) {
            const s = "\x1b[3m";
            @memcpy(buf[pos..pos + s.len], s);
            pos += s.len;
        }
        if (self.underline) {
            const s = "\x1b[4m";
            @memcpy(buf[pos..pos + s.len], s);
            pos += s.len;
        }
        if (self.blink) {
            const s = "\x1b[5m";
            @memcpy(buf[pos..pos + s.len], s);
            pos += s.len;
        }
        if (self.reverse) {
            const s = "\x1b[7m";
            @memcpy(buf[pos..pos + s.len], s);
            pos += s.len;
        }
        if (self.hidden) {
            const s = "\x1b[8m";
            @memcpy(buf[pos..pos + s.len], s);
            pos += s.len;
        }
        if (self.strikethrough) {
            const s = "\x1b[9m";
            @memcpy(buf[pos..pos + s.len], s);
            pos += s.len;
        }

        return buf[0..pos];
    }
};

/// Style combining foreground, background, and attributes
pub const Style = struct {
    fg: Color = .default,
    bg: Color = .default,
    attr: Attribute = .{},

    pub fn render(self: Style, writer: anywriter) !void {
        try writer.writeAll(self.fg.toAnsi());
        try writer.writeAll(self.bg.toAnsi());
        try writer.writeAll(self.attr.toAnsi());
    }

    pub fn reset(writer: anywriter) !void {
        try writer.writeAll("\x1b[0m");
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

    pub fn getPalette(self: ColorScheme) struct {
        bg: Color,
        fg: Color,
        accent: Color,
        success: Color,
        warning: Color,
        error: Color,
        info: Color,
    } {
        return switch (self) {
            .dark => .{
                .bg = .rgb = .{ .r = 30, .g = 30, .b = 30 },
                .fg = .rgb = .{ .r = 220, .g = 220, .b = 220 },
                .accent = .rgb = .{ .r = 100, .g = 180, .b = 255 },
                .success = .green,
                .warning = .yellow,
                .error = .red,
                .info = .cyan,
            },
            .light => .{
                .bg = .rgb = .{ .r = 255, .g = 255, .b = 255 },
                .fg = .rgb = .{ .r = 30, .g = 30, .b = 30 },
                .accent = .rgb = .{ .r = 0, .g = 100, .b = 200 },
                .success = .green,
                .warning = .yellow,
                .error = .red,
                .info = .blue,
            },
            .monokai => .{
                .bg = .rgb = .{ .r = 39, .g = 40, .b = 34 },
                .fg = .rgb = .{ .r = 248, .g = 248, .b = 242 },
                .accent = .rgb = .{ .r = 102, .g = 217, .b = 239 },
                .success = .rgb = .{ .r = 166, .g = 226, .b = 46 },
                .warning = .rgb = .{ .r = 249, .g = 38, .b = 114 },
                .error = .red,
                .info = .magenta,
            },
            .dracula => .{
                .bg = .rgb = .{ .r = 40, .g = 42, .b = 54 },
                .fg = .rgb = .{ .r = 248, .g = 248, .b = 242 },
                .accent = .rgb = .{ .r = 139, .g = 233, .b = 253 },
                .success = .rgb = .{ .r = 80, .g = 250, .b = 123 },
                .warning = .rgb = .{ .r = 241, .g = 250, .b = 140 },
                .error = .rgb = .{ .r = 255, .g = 85, .b = 85 },
                .info = .rgb = .{ .r = 189, .g = 147, .b = 249 },
            },
            .nord => .{
                .bg = .rgb = .{ .r = 47, .g = 52, .b = 64 },
                .fg = .rgb = .{ .r = 216, .g = 222, .b = 233 },
                .accent = .rgb = .{ .r = 129, .g = 162, .b = 190 },
                .success = .rgb = .{ .r = 163, .g = 190, .b = 140 },
                .warning = .rgb = .{ .r = 235, .g = 203, .b = 139 },
                .error = .rgb = .{ .r = 191, .g = 97, .b = 106 },
                .info = .rgb = .{ .r = 143, .g = 188, .b = 187 },
            },
            .gruvbox => .{
                .bg = .rgb = .{ .r = 40, .g = 40, .b = 40 },
                .fg = .rgb = .{ .r = 235, .g = 235, .b = 235 },
                .accent = .rgb = .{ .r = 131, .g = 165, .b = 152 },
                .success = .rgb = .{ .r = 152, .g = 195, .b = 121 },
                .warning = .rgb = .{ .r = 254, .g = 128, .b = 25 },
                .error = .rgb = .{ .r = 251, .g = 73, .b = 52 },
                .info = .rgb = .{ .r = 131, .g = 165, .b = 152 },
            },
        };
    }
};

test "theme colors" {
    const style = Style{
        .fg = .red,
        .bg = .blue,
        .attr = .{ .bold = true, .underline = true },
    };
    var buf: [100]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try style.render(fbs.writer());
}
