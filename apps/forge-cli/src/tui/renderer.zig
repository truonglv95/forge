//! TUI Renderer for Forge TUI
//! 
//! High-performance terminal rendering with double buffering and diff optimization.

const std = @import("std");
const theme = @import("theme/theme.zig");
const layouts = @import("layouts/layouts.zig");

/// Character cell with style
pub const Cell = struct {
    char: u21,
    fg: ?theme.Color = null,
    bg: ?theme.Color = null,
    bold: bool = false,
    underline: bool = false,
    italic: bool = false,
    reverse: bool = false,
    
    pub fn eql(self: Cell, other: Cell) bool {
        return self.char == other.char and
               self.fg == other.fg and
               self.bg == other.bg and
               self.bold == other.bold and
               self.underline == other.underline and
               self.italic == other.italic and
               self.reverse == other.reverse;
    }
};

/// Double buffer for flicker-free rendering
pub const Buffer = struct {
    width: u16,
    height: u16,
    cells: []Cell,
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, width: u16, height: u16) !Buffer {
        const size = @as(usize, width) * height;
        const cells = try allocator.alloc(Cell, size);
        @memset(cells, .{ .char = ' ', .fg = null, .bg = null });
        
        return .{
            .width = width,
            .height = height,
            .cells = cells,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Buffer) void {
        self.allocator.free(self.cells);
    }
    
    pub fn clear(self: *Buffer) void {
        @memset(self.cells, .{ .char = ' ', .fg = null, .bg = null });
    }
    
    pub fn resize(self: *Buffer, width: u16, height: u16) !void {
        if (self.width == width and self.height == height) return;
        
        self.allocator.free(self.cells);
        const size = @as(usize, width) * height;
        self.cells = try self.allocator.alloc(Cell, size);
        @memset(self.cells, .{ .char = ' ', .fg = null, .bg = null });
        self.width = width;
        self.height = height;
    }
    
    pub fn get(self: Buffer, x: u16, y: u16) ?*Cell {
        if (x >= self.width or y >= self.height) return null;
        return &self.cells[@as(usize, y) * self.width + x];
    }
    
    pub fn set(self: *Buffer, x: u16, y: u16, char: u21) void {
        if (x >= self.width or y >= self.height) return;
        self.cells[@as(usize, y) * self.width + x].char = char;
    }
    
    pub fn setString(self: *Buffer, x: u16, y: u16, str: []const u8, style: ?theme.Style) void {
        var cx = x;
        for (str) |char| {
            if (cx >= self.width) break;
            
            const cell = self.get(cx, y) orelse break;
            cell.char = char;
            
            if (style) |s| {
                cell.fg = s.fg;
                cell.bg = s.bg;
                cell.bold = s.attr.bold;
                cell.underline = s.attr.underline;
                cell.italic = s.attr.italic;
                cell.reverse = s.attr.reverse;
            }
            
            cx += 1;
        }
    }
    
    pub fn fill(self: *Buffer, x: u16, y: u16, width: u16, height: u16, char: u21, style: ?theme.Style) void {
        var cy = y;
        while (cy < y + height and cy < self.height) : (cy += 1) {
            var cx = x;
            while (cx < x + width and cx < self.width) : (cx += 1) {
                const cell = self.get(cx, cy) orelse continue;
                cell.char = char;
                
                if (style) |s| {
                    cell.fg = s.fg;
                    cell.bg = s.bg;
                }
            }
        }
    }
};

/// Main renderer with double buffering
pub const Renderer = struct {
    front_buffer: Buffer,
    back_buffer: Buffer,
    writer: anytype,
    theme: theme.Theme,
    cursor_x: u16 = 0,
    cursor_y: u16 = 0,
    cursor_visible: bool = true,
    
    const Self = @This();
    
    pub fn init(writer: anytype, theme: theme.Theme) !Self {
        // Default terminal size
        const width: u16 = 80;
        const height: u16 = 24;
        
        const allocator = std.heap.page_allocator;
        
        return .{
            .front_buffer = try Buffer.init(allocator, width, height),
            .back_buffer = try Buffer.init(allocator, width, height),
            .writer = writer,
            .theme = theme,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.front_buffer.deinit();
        self.back_buffer.deinit();
    }
    
    pub fn resize(self: *Self, width: u16, height: u16) !void {
        try self.front_buffer.resize(width, height);
        try self.back_buffer.resize(width, height);
    }
    
    pub fn clear(self: *Self) void {
        self.back_buffer.clear();
    }
    
    pub fn write(self: *Self, x: u16, y: u16, text: []const u8, style: ?theme.Style) void {
        self.back_buffer.setString(x, y, text, style);
    }
    
    pub fn fill(self: *Self, x: u16, y: u16, width: u16, height: u16, char: u21, style: ?theme.Style) void {
        self.back_buffer.fill(x, y, width, height, char, style);
    }
    
    pub fn render(self: *Self, app: anytype) !void {
        // Let the app render to back buffer
        _ = app;
    }
    
    pub fn flush(self: *Self) !void {
        var output = std.ArrayList(u8).init(std.heap.page_allocator);
        defer output.deinit();
        
        var last_fg: ?theme.Color = null;
        var last_bg: ?theme.Color = null;
        var cursor_moved = false;
        
        for (0..self.back_buffer.height) |y| {
            for (0..self.back_buffer.width) |x| {
                const back_cell = self.back_buffer.get(@intCast(x), @intCast(y)).?;
                const front_cell = self.front_buffer.get(@intCast(x), @intCast(y)).?;
                
                if (!back_cell.eql(front_cell.*)) {
                    // Move cursor if needed
                    if (cursor_moved or self.cursor_x != x or self.cursor_y != y) {
                        try output.appendSlice(&std.fmt.allocPrint(std.heap.page_allocator, "\x1b[{d};{d}H", .{ y + 1, x + 1 }) catch "");
                        cursor_moved = false;
                    }
                    
                    // Update styles
                    if (back_cell.fg != last_fg) {
                        if (back_cell.fg) |c| {
                            try output.appendSlice(c.toAnsi());
                        } else {
                            try output.appendSlice(theme.Color.reset.toAnsi());
                        }
                        last_fg = back_cell.fg;
                    }
                    
                    if (back_cell.bg != last_bg) {
                        if (back_cell.bg) |c| {
                            // BG uses 48;2;r;g;b format
                            try output.appendSlice(&std.fmt.allocPrint(std.heap.page_allocator, "\x1b[48;2;{};{};{}m", .{ 
                                switch (c) { .rgb => |rgb| rgb.r, else => 0 },
                                switch (c) { .rgb => |rgb| rgb.g, else => 0 },
                                switch (c) { .rgb => |rgb| rgb.b, else => 0 },
                            }) catch "");
                        }
                        last_bg = back_cell.bg;
                    }
                    
                    // Write character
                    const char_buf = std.unicode.utf8Encode(back_cell.char, &[_]u8{0} ** 4) catch continue;
                    try output.appendSlice(char_buf[0..char_buf[0]]);
                    
                    // Update front buffer
                    front_cell.* = back_cell.*;
                    
                    self.cursor_x = @intCast(x + 1);
                }
            }
        }
        
        // Reset styles at end
        try output.appendSlice(theme.Color.reset.toAnsi());
        
        // Write to output
        try self.writer.writeAll(output.items);
    }
    
    pub fn showCursor(self: *Self, x: u16, y: u16) !void {
        if (!self.cursor_visible) {
            try self.writer.writeAll("\x1b[?25h");
            self.cursor_visible = true;
        }
        try self.writer.writeAll(&std.fmt.allocPrint(std.heap.page_allocator, "\x1b[{d};{d}H", .{ y + 1, x + 1 }) catch "");
    }
    
    pub fn hideCursor(self: *Self) !void {
        if (self.cursor_visible) {
            try self.writer.writeAll("\x1b[?25l");
            self.cursor_visible = false;
        }
    }
};

test "Buffer creation" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.init(allocator, 80, 24);
    defer buffer.deinit();
    
    try std.testing.expectEqual(@as(u16, 80), buffer.width);
    try std.testing.expectEqual(@as(u16, 24), buffer.height);
}

test "Buffer setString" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.init(allocator, 80, 24);
    defer buffer.deinit();
    
    buffer.setString(0, 0, "Hello", null);
    
    const cell = buffer.get(0, 0).?;
    try std.testing.expectEqual(@as(u21, 'H'), cell.char);
}
