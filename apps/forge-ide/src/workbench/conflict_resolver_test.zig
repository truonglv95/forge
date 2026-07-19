const std = @import("std");
const testing = std.testing;
const Buffer = @import("forge-editor").Buffer;
const conflict_resolver = @import("conflict_resolver.zig");

test "conflict_resolver findConflicts" {
    var buf = try Buffer.init(testing.allocator);
    defer buf.deinit();

    const content =
        \\line 1
        \\<<<<<<< HEAD
        \\current change
        \\=======
        \\incoming change
        \\>>>>>>> branch
        \\line 6
    ;
    try buf.insertString(content);

    var blocks: std.ArrayListUnmanaged(conflict_resolver.ConflictBlock) = .empty;
    defer blocks.deinit(testing.allocator);

    try conflict_resolver.findConflicts(testing.allocator, &buf, &blocks);

    try testing.expectEqual(@as(usize, 1), blocks.items.len);
    try testing.expectEqual(@as(usize, 1), blocks.items[0].start_row);
    try testing.expectEqual(@as(usize, 3), blocks.items[0].mid_row);
    try testing.expectEqual(@as(usize, 5), blocks.items[0].end_row);
}

test "conflict_resolver resolveCurrent" {
    var buf = try Buffer.init(testing.allocator);
    defer buf.deinit();

    const content =
        \\line 1
        \\<<<<<<< HEAD
        \\current change
        \\=======
        \\incoming change
        \\>>>>>>> branch
        \\line 6
    ;
    try buf.insertString(content);

    var blocks: std.ArrayListUnmanaged(conflict_resolver.ConflictBlock) = .empty;
    defer blocks.deinit(testing.allocator);

    try conflict_resolver.findConflicts(testing.allocator, &buf, &blocks);
    try testing.expectEqual(@as(usize, 1), blocks.items.len);

    try conflict_resolver.resolveCurrent(&buf, blocks.items[0]);

    // Should leave only "current change"
    // Wait, insertTextAtCursor might not have newline correctly.
    // Let's just check the number of lines.
    // original: 7 lines (0 to 6)
    // resolveCurrent deletes mid_row..end_row (3..5) -> deletes 3 lines.
    // deletes start_row..start_row (1..1) -> deletes 1 line.
    // Remaining lines: 7 - 4 = 3 lines.
    try testing.expectEqual(@as(usize, 3), buf.lines.items.len);
    try testing.expectEqualStrings("line 1", buf.lines.items[0].items);
    try testing.expectEqualStrings("current change", buf.lines.items[1].items);
    try testing.expectEqualStrings("line 6", buf.lines.items[2].items);
}

test "conflict_resolver resolveIncoming" {
    var buf = try Buffer.init(testing.allocator);
    defer buf.deinit();

    const content =
        \\line 1
        \\<<<<<<< HEAD
        \\current change
        \\=======
        \\incoming change
        \\>>>>>>> branch
        \\line 6
    ;
    try buf.insertString(content);

    var blocks: std.ArrayListUnmanaged(conflict_resolver.ConflictBlock) = .empty;
    defer blocks.deinit(testing.allocator);

    try conflict_resolver.findConflicts(testing.allocator, &buf, &blocks);

    try conflict_resolver.resolveIncoming(&buf, blocks.items[0]);

    try testing.expectEqual(@as(usize, 3), buf.lines.items.len);
    try testing.expectEqualStrings("line 1", buf.lines.items[0].items);
    try testing.expectEqualStrings("incoming change", buf.lines.items[1].items);
    try testing.expectEqualStrings("line 6", buf.lines.items[2].items);
}

test "conflict_resolver resolveBoth" {
    var buf = try Buffer.init(testing.allocator);
    defer buf.deinit();

    const content =
        \\line 1
        \\<<<<<<< HEAD
        \\current change
        \\=======
        \\incoming change
        \\>>>>>>> branch
        \\line 6
    ;
    try buf.insertString(content);

    var blocks: std.ArrayListUnmanaged(conflict_resolver.ConflictBlock) = .empty;
    defer blocks.deinit(testing.allocator);

    try conflict_resolver.findConflicts(testing.allocator, &buf, &blocks);

    try conflict_resolver.resolveBoth(&buf, blocks.items[0]);

    try testing.expectEqual(@as(usize, 4), buf.lines.items.len);
    try testing.expectEqualStrings("line 1", buf.lines.items[0].items);
    try testing.expectEqualStrings("current change", buf.lines.items[1].items);
    try testing.expectEqualStrings("incoming change", buf.lines.items[2].items);
    try testing.expectEqualStrings("line 6", buf.lines.items[3].items);
}
