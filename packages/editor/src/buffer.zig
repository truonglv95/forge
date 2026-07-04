const std = @import("std");

pub const Cursor = struct {
    row: usize = 0,
    col: usize = 0,
};

const UndoOp = union(enum) {
    insert_text: struct {
        row: usize,
        col: usize,
        text: []const u8,
    },
    delete_range: struct {
        row: usize,
        col: usize,
        deleted: []const u8,
    },
    split_line: struct {
        row: usize,
        col: usize,
        tail: []const u8,
    },
};

pub const Buffer = struct {
    lines: std.ArrayList(std.ArrayList(u8)),
    cursor: Cursor,
    allocator: std.mem.Allocator,
    undo_stack: std.ArrayList(UndoOp),
    redo_stack: std.ArrayList(UndoOp),

    pub fn init(allocator: std.mem.Allocator) !Buffer {
        var lines: std.ArrayList(std.ArrayList(u8)) = .empty;
        try lines.append(allocator, .empty);
        return .{
            .lines = lines,
            .cursor = .{},
            .allocator = allocator,
            .undo_stack = .empty,
            .redo_stack = .empty,
        };
    }

    pub fn deinit(self: *Buffer) void {
        self.clearHistory();
        for (self.lines.items) |*line| line.deinit(self.allocator);
        self.lines.deinit(self.allocator);
    }

    fn clearHistory(self: *Buffer) void {
        for (self.undo_stack.items) |*op| self.freeUndoOp(op);
        self.undo_stack.deinit(self.allocator);
        for (self.redo_stack.items) |*op| self.freeUndoOp(op);
        self.redo_stack.deinit(self.allocator);
        self.undo_stack = .empty;
        self.redo_stack = .empty;
    }

    fn freeUndoOp(self: *Buffer, op: *UndoOp) void {
        switch (op.*) {
            .insert_text => |entry| self.allocator.free(entry.text),
            .delete_range => |entry| self.allocator.free(entry.deleted),
            .split_line => |entry| self.allocator.free(entry.tail),
        }
    }

    pub fn loadFromSlice(self: *Buffer, source: []const u8) !void {
        self.clearHistory();
        for (self.lines.items) |*line| line.deinit(self.allocator);
        self.lines.clearRetainingCapacity();

        if (source.len == 0) {
            try self.lines.append(self.allocator, .empty);
        } else {
            var start: usize = 0;
            for (source, 0..) |byte, index| {
                if (byte == '\n') {
                    var line: std.ArrayList(u8) = .empty;
                    try line.appendSlice(self.allocator, source[start..index]);
                    try self.lines.append(self.allocator, line);
                    start = index + 1;
                }
            }
            var tail: std.ArrayList(u8) = .empty;
            try tail.appendSlice(self.allocator, source[start..]);
            try self.lines.append(self.allocator, tail);
        }

        self.cursor = .{};
    }

    pub fn content(self: *const Buffer) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        for (self.lines.items, 0..) |line, index| {
            try out.appendSlice(self.allocator, line.items);
            if (index + 1 < self.lines.items.len) try out.append(self.allocator, '\n');
        }
        return try out.toOwnedSlice(self.allocator);
    }

    pub fn lineCount(self: *const Buffer) usize {
        return self.lines.items.len;
    }

    pub fn lineAt(self: *const Buffer, row: usize) []const u8 {
        if (row >= self.lines.items.len) return "";
        return self.lines.items[row].items;
    }

    pub fn canUndo(self: *const Buffer) bool {
        return self.undo_stack.items.len > 0;
    }

    pub fn canRedo(self: *const Buffer) bool {
        return self.redo_stack.items.len > 0;
    }

    fn clearRedo(self: *Buffer) void {
        for (self.redo_stack.items) |*op| self.freeUndoOp(op);
        self.redo_stack.clearRetainingCapacity();
    }

    fn pushUndoInsert(self: *Buffer, row: usize, col: usize, text: []const u8) !void {
        const owned = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned);
        try self.undo_stack.append(self.allocator, .{ .insert_text = .{ .row = row, .col = col, .text = owned } });
        self.clearRedo();
    }

    fn pushUndoDelete(self: *Buffer, row: usize, col: usize, deleted: []const u8) !void {
        const owned = try self.allocator.dupe(u8, deleted);
        errdefer self.allocator.free(owned);
        try self.undo_stack.append(self.allocator, .{ .delete_range = .{ .row = row, .col = col, .deleted = owned } });
        self.clearRedo();
    }

    pub fn undo(self: *Buffer) !void {
        const op = self.undo_stack.pop() orelse return;
        switch (op) {
            .insert_text => |entry| {
                try self.deleteRangeInternal(entry.row, entry.col, entry.text.len, false);
                const redo_text = try self.allocator.dupe(u8, entry.text);
                try self.redo_stack.append(self.allocator, .{ .insert_text = .{ .row = entry.row, .col = entry.col, .text = redo_text } });
                self.cursor = .{ .row = entry.row, .col = entry.col };
                self.allocator.free(entry.text);
            },
            .delete_range => |entry| {
                try self.insertTextInternal(entry.row, entry.col, entry.deleted, false);
                const redo_deleted = try self.allocator.dupe(u8, entry.deleted);
                try self.redo_stack.append(self.allocator, .{ .delete_range = .{ .row = entry.row, .col = entry.col, .deleted = redo_deleted } });
                self.cursor = .{ .row = entry.row, .col = entry.col + entry.deleted.len };
                self.allocator.free(entry.deleted);
            },
            .split_line => |entry| {
                var next = self.lines.orderedRemove(entry.row + 1);
                defer next.deinit(self.allocator);
                var line = &self.lines.items[entry.row];
                try line.appendSlice(self.allocator, entry.tail);
                try line.appendSlice(self.allocator, next.items);
                const redo_tail = try self.allocator.dupe(u8, entry.tail);
                try self.redo_stack.append(self.allocator, .{ .split_line = .{ .row = entry.row, .col = entry.col, .tail = redo_tail } });
                self.cursor = .{ .row = entry.row, .col = entry.col };
                self.allocator.free(entry.tail);
            },
        }
    }

    pub fn redo(self: *Buffer) !void {
        const op = self.redo_stack.pop() orelse return;
        switch (op) {
            .insert_text => |entry| {
                try self.insertTextInternal(entry.row, entry.col, entry.text, false);
                const undo_text = try self.allocator.dupe(u8, entry.text);
                try self.undo_stack.append(self.allocator, .{ .insert_text = .{ .row = entry.row, .col = entry.col, .text = undo_text } });
                self.cursor = .{ .row = entry.row, .col = entry.col + entry.text.len };
                self.allocator.free(entry.text);
            },
            .delete_range => |entry| {
                try self.deleteRangeInternal(entry.row, entry.col, entry.deleted.len, false);
                const undo_deleted = try self.allocator.dupe(u8, entry.deleted);
                try self.undo_stack.append(self.allocator, .{ .delete_range = .{ .row = entry.row, .col = entry.col, .deleted = undo_deleted } });
                self.cursor = .{ .row = entry.row, .col = entry.col };
                self.allocator.free(entry.deleted);
            },
            .split_line => |entry| {
                const row = entry.row;
                const col = entry.col;
                var current = &self.lines.items[row];
                const tail = try self.allocator.dupe(u8, current.items[col..]);
                errdefer self.allocator.free(tail);
                current.items.len = col;
                var new_line: std.ArrayList(u8) = .empty;
                try new_line.appendSlice(self.allocator, tail);
                self.allocator.free(tail);
                try self.lines.insert(self.allocator, row + 1, new_line);
                const undo_tail = try self.allocator.dupe(u8, entry.tail);
                try self.undo_stack.append(self.allocator, .{ .split_line = .{ .row = row, .col = col, .tail = undo_tail } });
                self.cursor = .{ .row = row + 1, .col = 0 };
                self.allocator.free(entry.tail);
            },
        }
    }

    pub fn insertString(self: *Buffer, text: []const u8) !void {
        var index: usize = 0;
        while (index < text.len) {
            if (text[index] == '\n') {
                try self.insertNewline();
                index += 1;
                continue;
            }
            const start = index;
            while (index < text.len and text[index] != '\n') : (index += 1) {}
            try self.insertTextInternal(self.cursor.row, self.cursor.col, text[start..index], true);
        }
    }

    pub fn insertNewline(self: *Buffer) !void {
        const row = self.cursor.row;
        const col = self.cursor.col;
        var current = &self.lines.items[row];
        const tail_source: []const u8 = if (col < current.items.len) current.items[col..] else "";
        const tail_copy = try self.allocator.dupe(u8, tail_source);
        errdefer self.allocator.free(tail_copy);
        var new_line: std.ArrayList(u8) = .empty;
        if (col < current.items.len) {
            try new_line.appendSlice(self.allocator, current.items[col..]);
            current.items.len = col;
        }
        errdefer new_line.deinit(self.allocator);
        try self.lines.insert(self.allocator, row + 1, new_line);
        try self.undo_stack.append(self.allocator, .{ .split_line = .{ .row = row, .col = col, .tail = tail_copy } });
        self.clearRedo();
        self.cursor = .{ .row = row + 1, .col = 0 };
    }

    pub fn backspace(self: *Buffer) !void {
        if (self.cursor.col > 0) {
            const row = self.cursor.row;
            const col = self.cursor.col - 1;
            const deleted_byte = self.lines.items[row].items[col];
            var deleted: [1]u8 = .{deleted_byte};
            try self.pushUndoDelete(row, col, deleted[0..1]);
            _ = self.lines.items[row].orderedRemove(col);
            self.cursor.col -= 1;
        } else if (self.cursor.row > 0) {
            const row = self.cursor.row;
            var current = self.lines.orderedRemove(row);
            self.cursor.row -= 1;
            const prev = &self.lines.items[self.cursor.row];
            const join_col = prev.items.len;
            try self.pushUndoInsert(self.cursor.row, join_col, "\n");
            try prev.appendSlice(self.allocator, current.items);
            current.deinit(self.allocator);
            self.cursor.col = join_col;
        }
    }

    fn insertTextInternal(self: *Buffer, row: usize, col: usize, text: []const u8, record_undo: bool) !void {
        if (text.len == 0) return;
        if (record_undo) try self.pushUndoInsert(row, col, text);
        var line = &self.lines.items[row];
        try line.insertSlice(self.allocator, col, text);
        if (self.cursor.row == row and self.cursor.col == col) {
            self.cursor.col += text.len;
        }
    }

    fn deleteRangeInternal(self: *Buffer, row: usize, col: usize, len: usize, record_undo: bool) !void {
        if (len == 0) return;
        const line = &self.lines.items[row];
        if (col + len > line.items.len) return;
        const slice = line.items[col .. col + len];
        if (record_undo) {
            const deleted = try self.allocator.dupe(u8, slice);
            try self.pushUndoDelete(row, col, deleted);
        }
        const tail = line.items[col + len ..];
        line.items.len = col;
        try line.appendSlice(self.allocator, tail);
    }

    pub fn moveLeft(self: *Buffer) void {
        if (self.cursor.col > 0) {
            self.cursor.col -= 1;
        } else if (self.cursor.row > 0) {
            self.cursor.row -= 1;
            self.cursor.col = self.lines.items[self.cursor.row].items.len;
        }
    }

    pub fn moveRight(self: *Buffer) void {
        const line = self.lines.items[self.cursor.row];
        if (self.cursor.col < line.items.len) {
            self.cursor.col += 1;
        } else if (self.cursor.row + 1 < self.lines.items.len) {
            self.cursor.row += 1;
            self.cursor.col = 0;
        }
    }

    pub fn moveUp(self: *Buffer) void {
        if (self.cursor.row == 0) return;
        self.cursor.row -= 1;
        self.clampCursorCol();
    }

    pub fn moveDown(self: *Buffer) void {
        if (self.cursor.row + 1 >= self.lines.items.len) return;
        self.cursor.row += 1;
        self.clampCursorCol();
    }

    fn clampCursorCol(self: *Buffer) void {
        const len = self.lines.items[self.cursor.row].items.len;
        if (self.cursor.col > len) self.cursor.col = len;
    }

    pub fn goToLine(self: *Buffer, line_one_based: usize) void {
        if (line_one_based == 0) return;
        const row = line_one_based - 1;
        if (row >= self.lines.items.len) {
            self.cursor.row = self.lines.items.len - 1;
        } else {
            self.cursor.row = row;
        }
        self.clampCursorCol();
    }

    pub fn replaceRange(self: *Buffer, row: usize, col: usize, len: usize, text: []const u8) !void {
        try self.deleteRangeInternal(row, col, len, true);
        try self.insertTextInternal(row, col, text, true);
        self.cursor = .{ .row = row, .col = col + text.len };
    }

    pub fn applyLspTextEdit(
        self: *Buffer,
        start_row: usize,
        start_col: usize,
        end_row: usize,
        end_col: usize,
        new_text: []const u8,
    ) !void {
        if (self.lines.items.len == 0) return;
        const sr = @min(start_row, self.lines.items.len - 1);
        const er = @min(end_row, self.lines.items.len - 1);

        if (sr == er) {
            const line_len = self.lines.items[sr].items.len;
            const sc = @min(start_col, line_len);
            const ec = @min(end_col, line_len);
            const delete_len = if (ec > sc) ec - sc else 0;
            try self.replaceRange(sr, sc, delete_len, new_text);
            return;
        }

        const start_line = &self.lines.items[sr];
        const end_line = &self.lines.items[er];
        const sc = @min(start_col, start_line.items.len);
        const ec = @min(end_col, end_line.items.len);

        const prefix = try self.allocator.dupe(u8, start_line.items[0..sc]);
        errdefer self.allocator.free(prefix);
        const suffix = try self.allocator.dupe(u8, end_line.items[ec..]);
        errdefer self.allocator.free(suffix);

        var r = er;
        while (r > sr) : (r -= 1) {
            var removed = self.lines.orderedRemove(r);
            removed.deinit(self.allocator);
        }

        start_line.deinit(self.allocator);
        start_line.* = .empty;
        try start_line.appendSlice(self.allocator, prefix);
        self.allocator.free(prefix);

        self.cursor = .{ .row = sr, .col = start_line.items.len };
        try self.insertString(new_text);
        if (suffix.len > 0) {
            try self.insertTextInternal(self.cursor.row, self.cursor.col, suffix, true);
        }
        self.allocator.free(suffix);
    }

    pub fn toDisplayString(self: *const Buffer, show_cursor: bool) ![]u8 {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(self.allocator);

        for (self.lines.items, 0..) |line, row_idx| {
            if (show_cursor and row_idx == self.cursor.row) {
                try result.appendSlice(self.allocator, line.items[0..self.cursor.col]);
                try result.append(self.allocator, '|');
                try result.appendSlice(self.allocator, line.items[self.cursor.col..]);
            } else {
                try result.appendSlice(self.allocator, line.items);
            }
            if (row_idx + 1 < self.lines.items.len) try result.append(self.allocator, '\n');
        }
        try result.append(self.allocator, 0);
        return try result.toOwnedSlice(self.allocator);
    }
};

test "buffer applyLspTextEdit handles multi-line range" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    try buffer.loadFromSlice("alpha\nbeta\ngamma\n");
    try buffer.applyLspTextEdit(0, 2, 2, 0, "X\nY");
    const content = try buffer.content();
    defer allocator.free(content);
    try std.testing.expectEqualStrings("alX\nYgamma\n", content);
}

test "buffer preserves Vietnamese UTF-8" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    try buffer.loadFromSlice("Xin chào Forge\n");
    try std.testing.expectEqual(@as(usize, 2), buffer.lineCount());
    try std.testing.expect(std.mem.indexOf(u8, buffer.lineAt(0), "chào") != null);

    const content = try buffer.content();
    defer allocator.free(content);
    try std.testing.expectEqualStrings("Xin chào Forge\n", content);
}

test "buffer undo redo roundtrip" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    try buffer.insertString("abc");
    try std.testing.expectEqualStrings("abc", buffer.lineAt(0));

    try buffer.undo();
    try std.testing.expectEqualStrings("", buffer.lineAt(0));

    try buffer.redo();
    try std.testing.expectEqualStrings("abc", buffer.lineAt(0));
}

test "buffer newline and merge undo" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    try buffer.insertString("ab");
    try buffer.insertNewline();
    try buffer.insertString("cd");
    try std.testing.expectEqual(@as(usize, 2), buffer.lineCount());

    try buffer.undo();
    try std.testing.expectEqualStrings("ab", buffer.lineAt(0));
    try std.testing.expectEqualStrings("", buffer.lineAt(1));

    try buffer.undo();
    try std.testing.expectEqual(@as(usize, 1), buffer.lineCount());
    try std.testing.expectEqualStrings("ab", buffer.lineAt(0));

    buffer.cursor = .{ .row = 0, .col = 2 };
    try buffer.insertNewline();
    try buffer.insertString("cd");
    buffer.cursor = .{ .row = 1, .col = 0 };
    try buffer.backspace();
    try std.testing.expectEqual(@as(usize, 1), buffer.lineCount());
    try std.testing.expectEqualStrings("abcd", buffer.lineAt(0));
}

test "buffer handles CRLF and many lines" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    try buffer.loadFromSlice("line1\r\nline2\r\nline3");
    try std.testing.expect(buffer.lineCount() >= 2);

    var i: usize = 0;
    while (i < 500) : (i += 1) {
        try buffer.insertNewline();
        try buffer.insertString("row");
    }
    try std.testing.expect(buffer.lineCount() >= 501);
    try std.testing.expect(buffer.canUndo());
}
