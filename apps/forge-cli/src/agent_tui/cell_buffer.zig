// TUI Cell Buffer with Unicode support and True Color
const std = @import("std");
const builtin = @import("builtin");

pub const Color = union(enum) {
    default,
    ansi_4bit: u4,
    ansi_8bit: u8,
    true_color: struct { r: u8, g: u8, b: u8 },

    pub fn format(self: Color, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        switch (self) {
            .default => try writer.writeAll("default"),
            .ansi_4bit => |c| try writer.print("ansi4({d})", .{c}),
            .ansi_8bit => |c| try writer.print("ansi8({d})", .{c}),
            .true_color => |c| try writer.print("rgb({d},{d},{d})", .{ c.r, c.g, c.b }),
        }
    }
};

pub const Cell = struct {
    char: u21,
    fg: Color = .default,
    bg: Color = .default,
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    blink: bool = false,
    reverse: bool = false,

    pub fn eql(self: Cell, other: Cell) bool {
        return self.char == other.char and
            std.mem.eql(u8, @as([]const u8, @ptrCast(&self.fg)), @as([]const u8, @ptrCast(&other.fg))) and
            std.mem.eql(u8, @as([]const u8, @ptrCast(&self.bg)), @as([]const u8, @ptrCast(&other.bg))) and
            self.bold == other.bold and
            self.dim == other.dim and
            self.italic == other.italic and
            self.underline == other.underline and
            self.blink == other.blink and
            self.reverse == other.reverse;
    }

    pub fn reset(self: *Cell) void {
        self.* = .{};
    }
};

pub const FrameBuffer = struct {
    width: usize,
    height: usize,
    cells: []Cell,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, width: usize, height: usize) !Self {
        const cells = try allocator.alloc(Cell, width * height);
        @memset(cells, .{});
        return .{
            .width = width,
            .height = height,
            .cells = cells,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.cells);
    }

    pub fn resize(self: *Self, allocator: std.mem.Allocator, width: usize, height: usize) !void {
        const new_cells = try allocator.alloc(Cell, width * height);
        @memset(new_cells, .{});

        // Copy existing cells
        const min_width = @min(self.width, width);
        const min_height = @min(self.height, height);
        for (0..min_height) |y| {
            const src_row = y * self.width;
            const dst_row = y * width;
            @memcpy(new_cells[dst_row .. dst_row + min_width], self.cells[src_row .. src_row + min_width]);
        }

        self.allocator.free(self.cells);
        self.cells = new_cells;
        self.width = width;
        self.height = height;
    }

    pub fn get(self: *const Self, x: usize, y: usize) ?*Cell {
        if (x >= self.width or y >= self.height) return null;
        return &self.cells[y * self.width + x];
    }

    pub fn set(self: *Self, x: usize, y: usize, char: u21, fg: Color, bg: Color) void {
        if (x >= self.width or y >= self.height) return;
        const cell = &self.cells[y * self.width + x];
        cell.char = char;
        cell.fg = fg;
        cell.bg = bg;
    }

    pub fn clear(self: *Self) void {
        @memset(self.cells, .{});
    }

    pub fn fill(self: *Self, char: u21) void {
        for (self.cells) |*cell| {
            cell.char = char;
        }
    }

    pub fn writeText(self: *Self, x: usize, y: usize, text: []const u8, fg: Color, bg: Color) void {
        var curr_x = x;
        var i: usize = 0;
        while (i < text.len) {
            if (curr_x >= self.width) break;
            
            const result = std.unicode.utf8Decode(text[i..]);
            const codepoint = result.value;
            const byte_len = result.bytes_consumed;
            
            const cell = self.get(curr_x, y).?;
            cell.char = codepoint;
            cell.fg = fg;
            cell.bg = bg;
            
            // Simple width estimation (most chars are 1 column)
            curr_x += 1;
            i += byte_len;
        }
    }
};

pub const DirtyRect = struct {
    min_x: usize,
    min_y: usize,
    max_x: usize,
    max_y: usize,
    has_changes: bool = false,

    const Self = @This();

    pub fn reset(self: *Self) void {
        self.min_x = std.math.maxInt(usize);
        self.min_y = std.math.maxInt(usize);
        self.max_x = 0;
        self.max_y = 0;
        self.has_changes = false;
    }

    pub fn markDirty(self: *Self, x: usize, y: usize) void {
        if (!self.has_changes) {
            self.min_x = x;
            self.min_y = y;
            self.max_x = x;
            self.max_y = y;
            self.has_changes = true;
        } else {
            self.min_x = @min(self.min_x, x);
            self.min_y = @min(self.min_y, y);
            self.max_x = @max(self.max_x, x);
            self.max_y = @max(self.max_y, y);
        }
    }

    pub fn markRegion(self: *Self, x: usize, y: usize, w: usize, h: usize) void {
        if (w == 0 or h == 0) return;
        self.markDirty(x, y);
        self.markDirty(x + w - 1, y + h - 1);
    }

    pub fn isEmpty(self: *const Self) bool {
        return !self.has_changes;
    }

    pub fn forEach(self: *const Self, comptime callback: fn (usize, usize) void) void {
        if (!self.has_changes) return;
        for (self.min_y..self.max_y + 1) |y| {
            for (self.min_x..self.max_x + 1) |x| {
                callback(x, y);
            }
        }
    }
};

test "Cell buffer basic operations" {
    const allocator = std.testing.allocator;
    var fb = try FrameBuffer.init(allocator, 80, 24);
    defer fb.deinit();

    fb.set(0, 0, 'H', .default, .default);
    fb.set(1, 0, 'i', .default, .default);

    const cell0 = fb.get(0, 0).?;
    try std.testing.expectEqual('H', cell0.char);

    const cell1 = fb.get(1, 0).?;
    try std.testing.expectEqual('i', cell1.char);
}

test "Dirty rect tracking" {
    var dirty = DirtyRect{};
    dirty.reset();

    try std.testing.expect(!dirty.has_changes);

    dirty.markDirty(5, 10);
    try std.testing.expect(dirty.has_changes);
    try std.testing.expectEqual(5, dirty.min_x);
    try std.testing.expectEqual(10, dirty.min_y);
    try std.testing.expectEqual(5, dirty.max_x);
    try std.testing.expectEqual(10, dirty.max_y);

    dirty.markDirty(15, 20);
    try std.testing.expectEqual(5, dirty.min_x);
    try std.testing.expectEqual(10, dirty.min_y);
    try std.testing.expectEqual(15, dirty.max_x);
    try std.testing.expectEqual(20, dirty.max_y);
}
