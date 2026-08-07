//! Renderer for Forge TUI
//! Double-buffered rendering with diff optimization

const std = @import("std");
const layouts = @import("layouts/layouts.zig");
const theme = @import("theme/theme.zig");

pub const Cell = struct {
    char: u8,
    fg: theme.Color = .default,
    bg: theme.Color = .default,
    attr: theme.Attribute = .{},

    pub fn eql(self: Cell, other: Cell) bool {
        return self.char == other.char and
            std.meta.eql(self.fg, other.fg) and
            std.meta.eql(self.bg, other.bg) and
            std.meta.eql(self.attr, other.attr);
    }
};

pub const Buffer = struct {
    width: u16,
    height: u16,
    cells: []Cell,
    allocator: Allocator,

    pub fn init(allocator: Allocator, width: u16, height: u16) !Buffer {
        const cells = try allocator.alloc(Cell, @as(usize, width) * @as(usize, height));
        @memset(cells, .{ .char = ' ', .fg = .default, .bg = .default, .attr = .{} });
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
        @memset(self.cells, .{ .char = ' ', .fg = .default, .bg = .default, .attr = .{} });
    }

    pub fn resize(self: *Buffer, allocator: Allocator, width: u16, height: u16) !void {
        const new_cells = try allocator.alloc(Cell, @as(usize, width) * @as(usize, height));
        @memset(new_cells, .{ .char = ' ', .fg = .default, .bg = .default, .attr = .{} });

        const min_width = @min(self.width, width);
        const min_height = @min(self.height, height);

        for (0..min_height) |y| {
            for (0..min_width) |x| {
                new_cells[y * @as(usize, width) + x] = self.cells[y * @as(usize, self.width) + x];
            }
        }

        allocator.free(self.cells);
        self.cells = new_cells;
        self.width = width;
        self.height = height;
    }

    pub fn get(self: *Buffer, x: u16, y: u16) ?*Cell {
        if (x >= self.width or y >= self.height) return null;
        return &self.cells[@as(usize, y) * @as(usize, self.width) + @as(usize, x)];
    }

    pub fn set(self: *Buffer, x: u16, y: u16, char: u8, style: theme.Style) void {
        if (x >= self.width or y >= self.height) return;
        const idx = @as(usize, y) * @as(usize, self.width) + @as(usize, x);
        self.cells[idx] = .{
            .char = char,
            .fg = style.fg,
            .bg = style.bg,
            .attr = style.attr,
        };
    }

    pub fn write(self: *Buffer, x: u16, y: u16, text: []const u8, style: theme.Style) void {
        var cx = x;
        for (text) |c| {
            if (cx >= self.width) break;
            self.set(cx, y, c, style);
            cx += 1;
        }
    }
};

pub const Renderer = struct {
    front_buffer: Buffer,
    back_buffer: Buffer,
    stdout: std.fs.File.Writer,
    cursor_visible: bool = true,
    last_cursor_x: ?u16 = null,
    last_cursor_y: ?u16 = null,

    pub fn init(allocator: Allocator, width: u16, height: u16) !Renderer {
        return .{
            .front_buffer = try Buffer.init(allocator, width, height),
            .back_buffer = try Buffer.init(allocator, width, height),
            .stdout = std.io.getStdOut().writer(),
        };
    }

    pub fn deinit(self: *Renderer) void {
        self.front_buffer.deinit();
        self.back_buffer.deinit();
    }

    pub fn resize(self: *Renderer, allocator: Allocator, width: u16, height: u16) !void {
        try self.front_buffer.resize(allocator, width, height);
        try self.back_buffer.resize(allocator, width, height);
    }

    pub fn clear(self: *Renderer) void {
        self.back_buffer.clear();
    }

    pub fn drawChar(self: *Renderer, x: u16, y: u16, char: u8, style: theme.Style) void {
        self.back_buffer.set(x, y, char, style);
    }

    pub fn drawText(self: *Renderer, x: u16, y: u16, text: []const u8, style: theme.Style) void {
        self.back_buffer.write(x, y, text, style);
    }

    pub fn render(self: *Renderer) !void {
        var buf: [512]u8 = undefined;
        var pos: usize = 0;

        for (0..self.back_buffer.height) |y| {
            for (0..self.back_buffer.width) |x| {
                const back = self.back_buffer.get(@intCast(x), @intCast(y)).?;
                const front = self.front_buffer.get(@intCast(x), @intCast(y)).?;

                if (!back.eql(front.*)) {
                    // Move cursor
                    if (self.last_cursor_x != x or self.last_cursor_y != y) {
                        pos += std.fmt.bufPrint(buf[pos..], "\x1b[{d};{d}H", .{ y + 1, x + 1 }).?.len;
                    }

                    // Write style
                    const style = theme.Style{ .fg = back.fg, .bg = back.bg, .attr = back.attr };
                    try style.render(std.io.fixedBufferStream(buf[pos..]).writer());
                    pos += style.fg.toAnsi().len + style.bg.toAnsi().len + style.attr.toAnsi().len;

                    // Write char
                    buf[pos] = back.char;
                    pos += 1;

                    front.* = back.*;
                    self.last_cursor_x = @intCast(x);
                    self.last_cursor_y = @intCast(y);
                }
            }
        }

        // Reset style
        pos += std.fmt.bufPrint(buf[pos..], "\x1b[0m", .{}).?.len;

        try self.stdout.writeAll(buf[0..pos]);
    }

    pub fn setCursorVisible(self: *Renderer, visible: bool) !void {
        if (self.cursor_visible != visible) {
            if (visible) {
                try self.stdout.writeAll("\x1b[?25h");
            } else {
                try self.stdout.writeAll("\x1b[?25l");
            }
            self.cursor_visible = visible;
        }
    }

    pub fn setCursorPos(self: *Renderer, x: u16, y: u16) !void {
        var buf: [32]u8 = undefined;
        const len = std.fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{ y + 1, x + 1 }).?.len;
        try self.stdout.writeAll(buf[0..len]);
    }
};

test "buffer operations" {
    var buf = try Buffer.init(std.testing.allocator, 10, 5);
    defer buf.deinit();

    buf.set(0, 0, 'H', .{ .fg = .red });
    const cell = buf.get(0, 0).?;
    try std.testing.expect(cell.char == 'H');
    try std.testing.expect(cell.fg == .red);
}
