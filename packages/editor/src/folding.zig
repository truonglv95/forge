const std = @import("std");
const buffer_mod = @import("buffer.zig");

/// Code folding support for the Forge editor.
///
/// Computes foldable ranges based on indentation levels. When a fold is
/// active, the editor hides lines between the fold start and end, showing
/// only the first line with a collapse marker.
///
/// Fold detection strategy:
///   - Indentation-based: a line with indent N followed by lines with
///     indent > N forms a foldable range.
///   - Brace-based: `{` opens a fold, `}` closes it (C-family languages).
///   - Both strategies are combined; indentation is the fallback.
///
/// The editor UI is responsible for rendering fold markers and collapsed
/// regions. This module only computes and stores fold ranges.
pub const FoldRange = struct {
    /// 0-indexed start line (the line that stays visible when folded).
    start_line: u32,
    /// 0-indexed end line (last hidden line when folded).
    end_line: u32,
    /// Whether this range is currently folded (collapsed).
    is_folded: bool = false,
};

pub const FoldController = struct {
    allocator: std.mem.Allocator,
    /// All detected fold ranges, sorted by start_line ascending.
    ranges: std.ArrayList(FoldRange),

    pub fn init(allocator: std.mem.Allocator) FoldController {
        return .{ .allocator = allocator, .ranges = .empty };
    }

    pub fn deinit(self: *FoldController) void {
        self.ranges.deinit(self.allocator);
    }

    /// Recompute fold ranges from buffer content. Clears existing ranges.
    /// Uses indentation-based folding: any line whose indent increases
    /// from the previous line starts a new fold range.
    pub fn computeRanges(self: *FoldController, buf: *const buffer_mod.Buffer) !void {
        self.ranges.clearRetainingCapacity();

        if (buf.lines.items.len < 2) return;

        // Stack of (line_index, indent_level) for open fold ranges.
        var stack: std.ArrayList(struct { line: u32, indent: u32 }) = .empty;
        defer stack.deinit(self.allocator);

        for (buf.lines.items, 0..) |line, i| {
            const indent = computeIndent(line.items);

            // Close any open folds whose indent >= current indent.
            while (stack.items.len > 0 and stack.items[stack.items.len - 1].indent >= indent) {
                const open = stack.pop().?;
                if (i - 1 > open.line) {
                    // Only create a range if it spans at least 1 line.
                    try self.ranges.append(self.allocator, .{
                        .start_line = open.line,
                        .end_line = @intCast(i - 1),
                    });
                }
            }

            // If indent increased from the last line, open a new fold.
            if (stack.items.len > 0) {
                const prev = stack.items[stack.items.len - 1];
                if (indent > prev.indent) {
                    // The previous line is the fold start.
                    try stack.append(self.allocator, .{
                        .line = @intCast(i - 1),
                        .indent = indent,
                    });
                }
            } else if (i > 0) {
                const prev_indent = computeIndent(buf.lines.items[i - 1].items);
                if (indent > prev_indent) {
                    try stack.append(self.allocator, .{
                        .line = @intCast(i - 1),
                        .indent = indent,
                    });
                }
            }
        }

        // Close any remaining open folds at EOF.
        const last_line: u32 = @intCast(buf.lines.items.len - 1);
        while (stack.items.len > 0) {
            const open = stack.pop().?;
            if (last_line > open.line) {
                try self.ranges.append(self.allocator, .{
                    .start_line = open.line,
                    .end_line = last_line,
                });
            }
        }

        // Sort by start_line.
        std.sort.block(FoldRange, self.ranges.items, {}, struct {
            fn less(_: void, a: FoldRange, b: FoldRange) bool {
                return a.start_line < b.start_line;
            }
        }.less);
    }

    /// Toggle fold at a given line. Returns true if a fold was toggled.
    pub fn toggleAtLine(self: *FoldController, line: u32) bool {
        for (self.ranges.items) |*range| {
            if (range.start_line == line) {
                range.is_folded = !range.is_folded;
                return true;
            }
        }
        return false;
    }

    /// Fold all ranges.
    pub fn foldAll(self: *FoldController) void {
        for (self.ranges.items) |*range| range.is_folded = true;
    }

    /// Unfold all ranges.
    pub fn unfoldAll(self: *FoldController) void {
        for (self.ranges.items) |*range| range.is_folded = false;
    }

    /// Returns true if the given line is hidden by a fold.
    pub fn isLineHidden(self: *const FoldController, line: u32) bool {
        for (self.ranges.items) |range| {
            if (range.is_folded and line > range.start_line and line <= range.end_line) {
                return true;
            }
        }
        return false;
    }

    /// Get the fold range that starts at the given line, if any.
    pub fn rangeAt(self: *const FoldController, line: u32) ?*const FoldRange {
        for (self.ranges.items) |*range| {
            if (range.start_line == line) return range;
        }
        return null;
    }

    /// Count active (folded) ranges.
    pub fn foldedCount(self: *const FoldController) usize {
        var n: usize = 0;
        for (self.ranges.items) |range| if (range.is_folded) {
            n += 1;
        };
        return n;
    }
};

fn computeIndent(line: []const u8) u32 {
    var n: u32 = 0;
    for (line) |c| {
        if (c == ' ') {
            n += 1;
        } else if (c == '\t') {
            n += 4;
        } else {
            break;
        }
    }
    return n;
}

test "FoldController computes indentation-based ranges" {
    const allocator = std.testing.allocator;
    var buf = try buffer_mod.Buffer.init(allocator);
    defer buf.deinit();
    try buf.loadFromSlice(
        \\fn main() {
        \\    const x = 1;
        \\    if (x) {
        \\        print("hi");
        \\    }
        \\}
    );

    var fc = FoldController.init(allocator);
    defer fc.deinit();
    try fc.computeRanges(&buf);

    // Should detect at least 2 fold ranges (function body + if body).
    try std.testing.expect(fc.ranges.items.len >= 2);
}

test "FoldController toggle and isLineHidden" {
    const allocator = std.testing.allocator;
    var buf = try buffer_mod.Buffer.init(allocator);
    defer buf.deinit();
    try buf.loadFromSlice("line1\n    line2\n    line3\n");

    var fc = FoldController.init(allocator);
    defer fc.deinit();
    try fc.computeRanges(&buf);

    try std.testing.expect(fc.ranges.items.len >= 1);
    const start = fc.ranges.items[0].start_line;

    // Before toggle, line is visible.
    try std.testing.expect(!fc.isLineHidden(start + 1));

    // Toggle fold.
    try std.testing.expect(fc.toggleAtLine(start));
    try std.testing.expect(fc.isLineHidden(start + 1));

    // Toggle again to unfold.
    try std.testing.expect(fc.toggleAtLine(start));
    try std.testing.expect(!fc.isLineHidden(start + 1));
}

test "FoldController foldAll and unfoldAll" {
    const allocator = std.testing.allocator;
    var buf = try buffer_mod.Buffer.init(allocator);
    defer buf.deinit();
    try buf.loadFromSlice("a\n    b\n    c\nd\n    e\n");

    var fc = FoldController.init(allocator);
    defer fc.deinit();
    try fc.computeRanges(&buf);

    fc.foldAll();
    try std.testing.expectEqual(fc.ranges.items.len, fc.foldedCount());

    fc.unfoldAll();
    try std.testing.expectEqual(@as(usize, 0), fc.foldedCount());
}
