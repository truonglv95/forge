const std = @import("std");

pub const TextBuffer = struct {
    lines: std.ArrayList(std.ArrayList(u8)),
    cursor_row: usize,
    cursor_col: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !TextBuffer {
        var lines: std.ArrayList(std.ArrayList(u8)) = .empty;
        try lines.append(allocator, .empty); // Start with one empty line

        return .{
            .lines = lines,
            .cursor_row = 0,
            .cursor_col = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TextBuffer) void {
        for (self.lines.items) |*line| {
            line.deinit(self.allocator);
        }
        self.lines.deinit(self.allocator);
    }

    pub fn insertChar(self: *TextBuffer, c: u8) !void {
        var line = &self.lines.items[self.cursor_row];
        try line.insert(self.allocator, self.cursor_col, c);
        self.cursor_col += 1;
    }

    pub fn insertString(self: *TextBuffer, str: []const u8) !void {
        for (str) |c| {
            if (c == '\n') {
                try self.insertNewline();
            } else if (c >= 32 or c == '\t') {
                try self.insertChar(c);
            }
        }
    }

    pub fn insertNewline(self: *TextBuffer) !void {
        var current_line = &self.lines.items[self.cursor_row];
        var new_line: std.ArrayList(u8) = .empty;
        
        // Move characters after cursor to the new line
        if (self.cursor_col < current_line.items.len) {
            try new_line.appendSlice(self.allocator, current_line.items[self.cursor_col..]);
            current_line.items.len = self.cursor_col;
        }

        try self.lines.insert(self.allocator, self.cursor_row + 1, new_line);
        self.cursor_row += 1;
        self.cursor_col = 0;
    }

    pub fn backspace(self: *TextBuffer) !void {
        if (self.cursor_col > 0) {
            // Delete character before cursor
            var line = &self.lines.items[self.cursor_row];
            _ = line.orderedRemove(self.cursor_col - 1);
            self.cursor_col -= 1;
        } else if (self.cursor_row > 0) {
            // Merge with previous line
            var current_line = self.lines.orderedRemove(self.cursor_row);
            defer current_line.deinit(self.allocator);
            
            self.cursor_row -= 1;
            var prev_line = &self.lines.items[self.cursor_row];
            self.cursor_col = prev_line.items.len; // Place cursor at the join point
            
            try prev_line.appendSlice(self.allocator, current_line.items);
        }
    }

    pub fn moveLeft(self: *TextBuffer) void {
        if (self.cursor_col > 0) {
            self.cursor_col -= 1;
        } else if (self.cursor_row > 0) {
            self.cursor_row -= 1;
            self.cursor_col = self.lines.items[self.cursor_row].items.len;
        }
    }

    pub fn moveRight(self: *TextBuffer) void {
        const line = self.lines.items[self.cursor_row];
        if (self.cursor_col < line.items.len) {
            self.cursor_col += 1;
        } else if (self.cursor_row < self.lines.items.len - 1) {
            self.cursor_row += 1;
            self.cursor_col = 0;
        }
    }

    pub fn moveUp(self: *TextBuffer) void {
        if (self.cursor_row > 0) {
            self.cursor_row -= 1;
            const line = self.lines.items[self.cursor_row];
            if (self.cursor_col > line.items.len) {
                self.cursor_col = line.items.len;
            }
        }
    }

    pub fn moveDown(self: *TextBuffer) void {
        if (self.cursor_row < self.lines.items.len - 1) {
            self.cursor_row += 1;
            const line = self.lines.items[self.cursor_row];
            if (self.cursor_col > line.items.len) {
                self.cursor_col = line.items.len;
            }
        }
    }

    // Render the buffer to a single string with an optional cursor marker
    pub fn toString(self: *TextBuffer, show_cursor: bool) ![]u8 {
        var result: std.ArrayList(u8) = .empty;
        
        for (self.lines.items, 0..) |line, row_idx| {
            if (show_cursor and row_idx == self.cursor_row) {
                try result.appendSlice(self.allocator, line.items[0..self.cursor_col]);
                try result.append(self.allocator, '|');
                try result.appendSlice(self.allocator, line.items[self.cursor_col..]);
            } else {
                try result.appendSlice(self.allocator, line.items);
            }
            
            if (row_idx < self.lines.items.len - 1) {
                try result.append(self.allocator, '\n');
            }
        }
        
        // Null terminate
        try result.append(self.allocator, 0);
        return result.toOwnedSlice(self.allocator);
    }
};
