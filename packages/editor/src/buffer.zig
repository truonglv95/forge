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
    group_start,
    group_end,
};

pub const Decoration = struct {
    kind: enum { addition, deletion },
    row: usize,
    col_start: usize = 0,
    col_end: usize = 0, // 0 means entire line
};

pub const Buffer = struct {
    lines: std.ArrayList(std.ArrayList(u8)),
    cursor: Cursor,
    selection_anchor: ?Cursor = null,
    allocator: std.mem.Allocator,
    undo_stack: std.ArrayList(UndoOp),
    redo_stack: std.ArrayList(UndoOp),
    decorations: std.ArrayList(Decoration),
    revision: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) !Buffer {
        var lines: std.ArrayList(std.ArrayList(u8)) = .empty;
        try lines.append(allocator, .empty);
        return .{
            .lines = lines,
            .cursor = .{},
            .allocator = allocator,
            .undo_stack = .empty,
            .redo_stack = .empty,
            .decorations = .empty,
            .revision = 0,
        };
    }

    pub fn deinit(self: *Buffer) void {
        self.clearHistory();
        for (self.lines.items) |*line| line.deinit(self.allocator);
        self.lines.deinit(self.allocator);
        self.decorations.deinit(self.allocator);
    }

    pub fn clear(self: *Buffer) void {
        for (self.lines.items) |*line| line.deinit(self.allocator);
        self.lines.clearRetainingCapacity();
        self.lines.append(self.allocator, .empty) catch {};
        self.cursor = .{};
        self.selection_anchor = null;
        self.decorations.clearRetainingCapacity();
        self.clearHistory();
        self.revision += 1;
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
            .group_start, .group_end => {},
        }
    }

    pub fn loadFromSlice(self: *Buffer, source: []const u8) !void {
        self.clearHistory();
        self.decorations.clearRetainingCapacity();
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
        self.revision += 1;
    }

    pub fn content(self: *const Buffer) ![]u8 {
        var total_len: usize = 0;
        for (self.lines.items) |line| {
            total_len += line.items.len;
        }
        if (self.lines.items.len > 0) {
            total_len += self.lines.items.len - 1;
        }

        var out: std.ArrayList(u8) = .empty;
        try out.ensureTotalCapacity(self.allocator, total_len);
        errdefer out.deinit(self.allocator);

        for (self.lines.items, 0..) |line, index| {
            out.appendSliceAssumeCapacity(line.items);
            if (index + 1 < self.lines.items.len) out.appendAssumeCapacity('\n');
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

    pub fn clearSelection(self: *Buffer) void {
        self.selection_anchor = null;
    }

    pub fn beginSelection(self: *Buffer, row: usize, col: usize) void {
        self.selection_anchor = .{ .row = row, .col = col };
        self.cursor = .{ .row = row, .col = col };
    }

    pub fn hasSelection(self: *const Buffer) bool {
        const anchor = self.selection_anchor orelse return false;
        return anchor.row != self.cursor.row or anchor.col != self.cursor.col;
    }

    pub fn selectAll(self: *Buffer) void {
        if (self.lines.items.len == 0) return;
        self.selection_anchor = .{ .row = 0, .col = 0 };
        const last_row = self.lines.items.len - 1;
        const last_col = self.lineAt(last_row).len;
        self.cursor = .{ .row = last_row, .col = last_col };
    }

    pub fn clearInlineEdit(self: *Buffer) void {
        var keep: std.ArrayList(Decoration) = .empty;
        for (self.decorations.items) |dec| {
            if (dec.kind != .addition and dec.kind != .deletion) {
                keep.append(self.allocator, dec) catch {};
            }
        }
        self.decorations.deinit(self.allocator);
        self.decorations = keep;
    }

    pub fn applyInlineEdit(self: *Buffer, start_line: usize, end_line: usize, replacement: []const u8) !void {
        // Mark existing lines as deletions (0-indexed lines)
        var row = start_line - 1;
        while (row <= end_line - 1 and row < self.lines.items.len) : (row += 1) {
            try self.decorations.append(self.allocator, .{ .kind = .deletion, .row = row });
        }

        // Insert new lines after end_line
        var insert_row = end_line;
        var start: usize = 0;
        for (replacement, 0..) |byte, index| {
            if (byte == '\n') {
                var new_line: std.ArrayList(u8) = .empty;
                try new_line.appendSlice(self.allocator, replacement[start..index]);
                try self.lines.insert(self.allocator, insert_row, new_line);
                try self.decorations.append(self.allocator, .{ .kind = .addition, .row = insert_row });
                insert_row += 1;
                start = index + 1;
            }
        }
        if (start < replacement.len) {
            var new_line: std.ArrayList(u8) = .empty;
            try new_line.appendSlice(self.allocator, replacement[start..]);
            try self.lines.insert(self.allocator, insert_row, new_line);
            try self.decorations.append(self.allocator, .{ .kind = .addition, .row = insert_row });
        }

        std.sort.pdq(Decoration, self.decorations.items, {}, struct {
            pub fn less(_: void, a: Decoration, b: Decoration) bool {
                return a.row < b.row;
            }
        }.less);
    }

    pub fn acceptInlineEdit(self: *Buffer) !void {
        var delete_indices: std.ArrayList(usize) = .empty;
        defer delete_indices.deinit(self.allocator);
        for (self.decorations.items) |dec| {
            if (dec.kind == .deletion) try delete_indices.append(self.allocator, dec.row);
        }
        var i: usize = delete_indices.items.len;
        while (i > 0) {
            i -= 1;
            const row = delete_indices.items[i];
            if (row < self.lines.items.len) {
                var removed = self.lines.orderedRemove(row);
                removed.deinit(self.allocator);
            }
        }
        self.clearInlineEdit();
    }

    pub fn rejectInlineEdit(self: *Buffer) !void {
        var delete_indices: std.ArrayList(usize) = .empty;
        defer delete_indices.deinit(self.allocator);
        for (self.decorations.items) |dec| {
            if (dec.kind == .addition) try delete_indices.append(self.allocator, dec.row);
        }
        var i: usize = delete_indices.items.len;
        while (i > 0) {
            i -= 1;
            const row = delete_indices.items[i];
            if (row < self.lines.items.len) {
                var removed = self.lines.orderedRemove(row);
                removed.deinit(self.allocator);
            }
        }
        self.clearInlineEdit();
    }

    pub fn selectionOrdered(self: *const Buffer) struct { start: Cursor, end: Cursor } {
        const anchor = self.selection_anchor orelse return .{ .start = self.cursor, .end = self.cursor };
        const cur = self.cursor;
        if (anchor.row < cur.row or (anchor.row == cur.row and anchor.col <= cur.col)) {
            return .{ .start = anchor, .end = cur };
        }
        return .{ .start = cur, .end = anchor };
    }

    pub fn selectedText(self: *const Buffer, allocator: std.mem.Allocator) ![]u8 {
        if (!self.hasSelection()) return try allocator.dupe(u8, "");
        const ord = self.selectionOrdered();
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        if (ord.start.row == ord.end.row) {
            const line = self.lineAt(ord.start.row);
            const start_col = @min(ord.start.col, line.len);
            const end_col = @min(@max(ord.end.col, start_col), line.len);
            try out.appendSlice(allocator, line[start_col..end_col]);
        } else {
            const first = self.lineAt(ord.start.row);
            const first_start = @min(ord.start.col, first.len);
            try out.appendSlice(allocator, first[first_start..]);
            var row = ord.start.row + 1;
            while (row < ord.end.row) : (row += 1) {
                try out.append(allocator, '\n');
                try out.appendSlice(allocator, self.lineAt(row));
            }
            try out.append(allocator, '\n');
            const last = self.lineAt(ord.end.row);
            const end_col = @min(ord.end.col, last.len);
            try out.appendSlice(allocator, last[0..end_col]);
        }
        return try out.toOwnedSlice(allocator);
    }

    pub fn deleteSelection(self: *Buffer) !bool {
        if (!self.hasSelection()) return false;
        const ord = self.selectionOrdered();
        self.selection_anchor = null;
        self.cursor = ord.start;

        if (ord.start.row == ord.end.row) {
            const line_len = self.lines.items[ord.start.row].items.len;
            const start_col = @min(ord.start.col, line_len);
            const end_col = @min(ord.end.col, line_len);
            try self.deleteRangeInternal(ord.start.row, start_col, end_col - start_col, true);
            self.cursor = .{ .row = ord.start.row, .col = start_col };
            return true;
        }

        const start_line = self.lines.items[ord.start.row].items;
        const end_line = self.lines.items[ord.end.row].items;
        const start_col = @min(ord.start.col, start_line.len);
        const end_col = @min(ord.end.col, end_line.len);

        const prefix = try self.allocator.dupe(u8, start_line[0..start_col]);
        errdefer self.allocator.free(prefix);
        const suffix = try self.allocator.dupe(u8, end_line[end_col..]);
        errdefer self.allocator.free(suffix);

        var row = ord.end.row;
        while (row > ord.start.row) : (row -= 1) {
            var removed = self.lines.orderedRemove(row);
            removed.deinit(self.allocator);
        }

        var target = &self.lines.items[ord.start.row];
        target.clearRetainingCapacity();
        try target.appendSlice(self.allocator, prefix);
        try target.appendSlice(self.allocator, suffix);
        self.allocator.free(prefix);
        self.allocator.free(suffix);

        self.clearRedo();
        self.revision += 1;
        self.cursor = .{ .row = ord.start.row, .col = start_col };
        return true;
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

    fn getCharClass(c: u8) u2 {
        return switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '_' => 0,
            ' ', '\t' => 1,
            else => 2,
        };
    }

    fn pushUndoInsert(self: *Buffer, row: usize, col: usize, text: []const u8) !void {
        if (text.len == 0) return;

        if (self.undo_stack.items.len > 0) {
            var last_op = &self.undo_stack.items[self.undo_stack.items.len - 1];
            if (last_op.* == .insert_text) {
                const prev = &last_op.insert_text;
                if (prev.row == row and prev.col + prev.text.len == col) {
                    const last_char = prev.text[prev.text.len - 1];
                    const first_char = text[0];
                    if (getCharClass(last_char) == getCharClass(first_char)) {
                        const merged = try self.allocator.alloc(u8, prev.text.len + text.len);
                        errdefer self.allocator.free(merged);
                        @memcpy(merged[0..prev.text.len], prev.text);
                        @memcpy(merged[prev.text.len..], text);

                        self.allocator.free(prev.text);
                        prev.text = merged;
                        self.clearRedo();
                        self.revision += 1;
                        return;
                    }
                }
            }
        }

        const owned = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned);
        try self.undo_stack.append(self.allocator, .{ .insert_text = .{ .row = row, .col = col, .text = owned } });
        self.clearRedo();
        self.revision += 1;
    }

    fn pushUndoDelete(self: *Buffer, row: usize, col: usize, deleted: []const u8) !void {
        if (deleted.len == 0) return;

        if (self.undo_stack.items.len > 0) {
            var last_op = &self.undo_stack.items[self.undo_stack.items.len - 1];
            if (last_op.* == .delete_range) {
                const prev = &last_op.delete_range;
                if (prev.row == row and prev.col == col + deleted.len) {
                    const merged = try self.allocator.alloc(u8, deleted.len + prev.deleted.len);
                    errdefer self.allocator.free(merged);
                    @memcpy(merged[0..deleted.len], deleted);
                    @memcpy(merged[deleted.len..], prev.deleted);

                    self.allocator.free(prev.deleted);
                    prev.deleted = merged;
                    prev.col = col;
                    self.clearRedo();
                    self.revision += 1;
                    return;
                }
                if (prev.row == row and prev.col == col) {
                    const merged = try self.allocator.alloc(u8, prev.deleted.len + deleted.len);
                    errdefer self.allocator.free(merged);
                    @memcpy(merged[0..prev.deleted.len], prev.deleted);
                    @memcpy(merged[prev.deleted.len..], deleted);

                    self.allocator.free(prev.deleted);
                    prev.deleted = merged;
                    self.clearRedo();
                    self.revision += 1;
                    return;
                }
            }
        }

        const owned = try self.allocator.dupe(u8, deleted);
        errdefer self.allocator.free(owned);
        try self.undo_stack.append(self.allocator, .{ .delete_range = .{ .row = row, .col = col, .deleted = owned } });
        self.clearRedo();
        self.revision += 1;
    }

    pub fn beginUndoGroup(self: *Buffer) !void {
        try self.undo_stack.append(self.allocator, .group_start);
        self.clearRedo();
    }

    pub fn endUndoGroup(self: *Buffer) !void {
        try self.undo_stack.append(self.allocator, .group_end);
        self.clearRedo();
    }

    pub fn undo(self: *Buffer) !void {
        const op = self.undo_stack.pop() orelse return;
        switch (op) {
            .group_end => {
                try self.redo_stack.append(self.allocator, .group_end);
                while (self.undo_stack.items.len > 0) {
                    const inner_op = self.undo_stack.pop() orelse break;
                    if (inner_op == .group_start) {
                        try self.redo_stack.append(self.allocator, .group_start);
                        break;
                    }
                    try self.undoOne(inner_op);
                }
            },
            .group_start => {}, // Should not happen without end, but safe to ignore
            else => try self.undoOne(op),
        }
    }

    fn undoOne(self: *Buffer, op: UndoOp) !void {
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
            .group_start, .group_end => {},
        }
    }

    pub fn redo(self: *Buffer) !void {
        const op = self.redo_stack.pop() orelse return;
        switch (op) {
            .group_start => {
                try self.undo_stack.append(self.allocator, .group_start);
                while (self.redo_stack.items.len > 0) {
                    const inner_op = self.redo_stack.pop() orelse break;
                    if (inner_op == .group_end) {
                        try self.undo_stack.append(self.allocator, .group_end);
                        break;
                    }
                    try self.redoOne(inner_op);
                }
            },
            .group_end => {}, // Should not happen without start
            else => try self.redoOne(op),
        }
    }

    fn redoOne(self: *Buffer, op: UndoOp) !void {
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
            .group_start, .group_end => {},
        }
    }

    pub fn insertString(self: *Buffer, text: []const u8) !void {
        _ = try self.deleteSelection();

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
        _ = try self.deleteSelection();

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
        self.revision += 1;
        self.cursor = .{ .row = row + 1, .col = 0 };
    }

    pub fn backspace(self: *Buffer) !void {
        if (try self.deleteSelection()) return;

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

    pub fn deleteForward(self: *Buffer) !void {
        if (try self.deleteSelection()) return;

        const row = self.cursor.row;
        const col = self.cursor.col;
        const line = &self.lines.items[row];
        if (col < line.items.len) {
            try self.deleteRangeInternal(row, col, 1, true);
            self.cursor = .{ .row = row, .col = col };
        } else if (row + 1 < self.lines.items.len) {
            var next = self.lines.orderedRemove(row + 1);
            defer next.deinit(self.allocator);
            try self.pushUndoInsert(row, col, "\n");
            try line.appendSlice(self.allocator, next.items);
            self.cursor = .{ .row = row, .col = col };
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
            defer self.allocator.free(deleted);
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

test "buffer deletes selection and forward character" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    try buffer.insertString("hello");
    buffer.selection_anchor = .{ .row = 0, .col = 1 };
    buffer.cursor = .{ .row = 0, .col = 4 };
    try buffer.backspace();
    try std.testing.expectEqualStrings("ho", buffer.lineAt(0));
    try std.testing.expect(!buffer.hasSelection());
    try std.testing.expectEqual(@as(usize, 1), buffer.cursor.col);

    try buffer.deleteForward();
    try std.testing.expectEqualStrings("h", buffer.lineAt(0));
    try std.testing.expectEqual(@as(usize, 1), buffer.cursor.col);
}

test "buffer delete forward joins next line" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    try buffer.loadFromSlice("ab\ncd");
    buffer.cursor = .{ .row = 0, .col = 2 };
    try buffer.deleteForward();
    try std.testing.expectEqual(@as(usize, 1), buffer.lineCount());
    try std.testing.expectEqualStrings("abcd", buffer.lineAt(0));
    try std.testing.expectEqual(@as(usize, 2), buffer.cursor.col);
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

test "buffer undo grouping" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    // Type "hello" character by character
    try buffer.insertString("h");
    try buffer.insertString("e");
    try buffer.insertString("l");
    try buffer.insertString("l");
    try buffer.insertString("o");

    // Type " "
    try buffer.insertString(" ");

    // Type "world"
    try buffer.insertString("w");
    try buffer.insertString("o");
    try buffer.insertString("r");
    try buffer.insertString("l");
    try buffer.insertString("d");

    try std.testing.expectEqualStrings("hello world", buffer.lineAt(0));

    // Undo "world" (grouped)
    try buffer.undo();
    try std.testing.expectEqualStrings("hello ", buffer.lineAt(0));

    // Undo " "
    try buffer.undo();
    try std.testing.expectEqualStrings("hello", buffer.lineAt(0));

    // Undo "hello"
    try buffer.undo();
    try std.testing.expectEqualStrings("", buffer.lineAt(0));
}
