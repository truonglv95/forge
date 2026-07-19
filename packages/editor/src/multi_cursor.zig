const std = @import("std");
const buffer_mod = @import("buffer.zig");

/// Multi-cursor support for the Forge editor.
///
/// The editor maintains a primary cursor (Buffer.cursor) and an optional
/// list of secondary cursors. All cursor operations (move, insert, delete)
/// are applied to every cursor simultaneously.
///
/// Cursor-adding gestures:
///   - Cmd+D / Ctrl+D: add next occurrence of current word
///   - Alt+Click: add cursor at click position
///   - Cmd+Shift+L: add cursor to all occurrences of current word
///
/// When multiple cursors are active, edits are applied in reverse row
/// order (bottom-up) so that row indices remain stable for earlier cursors.
pub const MultiCursor = struct {
    allocator: std.mem.Allocator,
    /// Secondary cursors (primary is Buffer.cursor). Always sorted by
    /// (row desc, col desc) so bottom-up iteration is natural.
    cursors: std.ArrayList(buffer_mod.Cursor),

    pub fn init(allocator: std.mem.Allocator) MultiCursor {
        return .{ .allocator = allocator, .cursors = .empty };
    }

    pub fn deinit(self: *MultiCursor) void {
        self.cursors.deinit(self.allocator);
    }

    pub fn count(self: *const MultiCursor) usize {
        return self.cursors.items.len + 1; // +1 for primary
    }

    pub fn isActive(self: *const MultiCursor) bool {
        return self.cursors.items.len > 0;
    }

    /// Add a secondary cursor. Automatically deduplicates and keeps sorted.
    pub fn add(self: *MultiCursor, cursor: buffer_mod.Cursor) !void {
        // Don't add if it duplicates the primary or an existing secondary.
        for (self.cursors.items) |c| {
            if (c.row == cursor.row and c.col == cursor.col) return;
        }
        try self.cursors.append(self.allocator, cursor);
        self.sort();
    }

    /// Remove all secondary cursors.
    pub fn clear(self: *MultiCursor) void {
        self.cursors.clearRetainingCapacity();
    }

    /// Get all cursors (primary + secondary) in top-to-bottom order.
    /// Caller must provide a buffer large enough.
    pub fn allCursors(self: *const MultiCursor, primary: buffer_mod.Cursor, out: []buffer_mod.Cursor) []buffer_mod.Cursor {
        var n: usize = 0;
        if (out.len > n) {
            out[n] = primary;
            n += 1;
        }
        for (self.cursors.items) |c| {
            if (out.len > n) {
                out[n] = c;
                n += 1;
            }
        }
        // Sort top-to-bottom (ascending row, then col).
        std.sort.block(buffer_mod.Cursor, out[0..n], {}, struct {
            fn less(_: void, a: buffer_mod.Cursor, b: buffer_mod.Cursor) bool {
                if (a.row != b.row) return a.row < b.row;
                return a.col < b.col;
            }
        }.less);
        return out[0..n];
    }

    /// Get all cursors (primary + secondary) in bottom-to-top order.
    pub fn allCursorsBottomUp(self: *const MultiCursor, primary: buffer_mod.Cursor, out: []buffer_mod.Cursor) []buffer_mod.Cursor {
        const result = self.allCursors(primary, out);
        std.mem.reverse(buffer_mod.Cursor, result);
        return result;
    }

    /// Add cursors at all occurrences of `word` in the buffer.
    /// Returns the number of cursors added (excluding primary).
    pub fn addAllOccurrences(self: *MultiCursor, buf: *const buffer_mod.Buffer, word: []const u8) !usize {
        if (word.len == 0) return 0;
        var added: usize = 0;
        for (buf.lines.items, 0..) |line, row| {
            var col: usize = 0;
            while (col + word.len <= line.items.len) {
                if (std.mem.eql(u8, line.items[col .. col + word.len], word)) {
                    // Check word boundary.
                    const left_ok = col == 0 or !std.ascii.isAlphanumeric(line.items[col - 1]);
                    const right_ok = col + word.len == line.items.len or !std.ascii.isAlphanumeric(line.items[col + word.len]);
                    if (left_ok and right_ok) {
                        try self.add(.{ .row = row, .col = col });
                        added += 1;
                    }
                    col += word.len;
                } else {
                    col += 1;
                }
            }
        }
        return added;
    }

    /// Add cursor at the next occurrence of `word` after the primary cursor.
    pub fn addNextOccurrence(self: *MultiCursor, buf: *const buffer_mod.Buffer, primary: buffer_mod.Cursor, word: []const u8) !bool {
        if (word.len == 0) return false;
        // Search from primary cursor position forward, wrapping around.
        var start_row = primary.row;
        var start_col = primary.col + 1;
        var wrapped = false;
        while (true) {
            for (buf.lines.items[start_row..], 0..) |line, row_offset| {
                const row = start_row + row_offset;
                const line_slice = if (row == start_row and start_col < line.items.len) line.items[start_col..] else line.items;
                if (std.mem.indexOf(u8, line_slice, word)) |idx| {
                    const col = if (row == start_row) start_col + idx else idx;
                    try self.add(.{ .row = row, .col = col });
                    return true;
                }
            }
            if (wrapped) break;
            // Wrap to top.
            start_row = 0;
            start_col = 0;
            wrapped = true;
        }
        return false;
    }

    fn sort(self: *MultiCursor) void {
        std.sort.block(buffer_mod.Cursor, self.cursors.items, {}, struct {
            fn less(_: void, a: buffer_mod.Cursor, b: buffer_mod.Cursor) bool {
                if (a.row != b.row) return a.row > b.row;
                return a.col > b.col;
            }
        }.less);
    }
};

test "MultiCursor add and dedup" {
    const allocator = std.testing.allocator;
    var mc = MultiCursor.init(allocator);
    defer mc.deinit();

    try mc.add(.{ .row = 1, .col = 0 });
    try mc.add(.{ .row = 2, .col = 5 });
    try mc.add(.{ .row = 1, .col = 0 }); // duplicate, should be skipped
    try std.testing.expectEqual(@as(usize, 2), mc.cursors.items.len);
}

test "MultiCursor addAllOccurrences" {
    const allocator = std.testing.allocator;
    var buf = try buffer_mod.Buffer.init(allocator);
    defer buf.deinit();
    try buf.loadFromSlice("foo bar foo baz foo\n");

    var mc = MultiCursor.init(allocator);
    defer mc.deinit();
    const added = try mc.addAllOccurrences(&buf, "foo");
    try std.testing.expectEqual(@as(usize, 3), added);
}

test "MultiCursor allCursors sorted top-to-bottom" {
    const allocator = std.testing.allocator;
    var mc = MultiCursor.init(allocator);
    defer mc.deinit();
    try mc.add(.{ .row = 5, .col = 0 });
    try mc.add(.{ .row = 2, .col = 3 });

    var out: [4]buffer_mod.Cursor = undefined;
    const all = mc.allCursors(.{ .row = 1, .col = 0 }, &out);
    try std.testing.expectEqual(@as(usize, 3), all.len);
    try std.testing.expectEqual(@as(usize, 1), all[0].row);
    try std.testing.expectEqual(@as(usize, 2), all[1].row);
    try std.testing.expectEqual(@as(usize, 5), all[2].row);
}
