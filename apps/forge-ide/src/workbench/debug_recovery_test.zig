const std = @import("std");
const testing = std.testing;
const workspace = @import("forge-workspace");
const breakpoints_mod = @import("breakpoints.zig");
const watch_expressions_mod = @import("watch_expressions.zig");
const debug_recovery = @import("debug_recovery.zig");
const global_store = workspace.global_store;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

test "debug_recovery snapshot and recover" {
    // Override FORGE_HOME for testing
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const io = std.testing.io;

    // Create a mock workspace root
    var ws_dir = testing.tmpDir(.{});
    defer ws_dir.cleanup();

    const ws_path = "/tmp/fake_workspace";

    const root = workspace.WorkspaceRoot.init(ws_dir.dir, ws_path);

    var breakpoints = breakpoints_mod.Store.init(testing.allocator);
    defer breakpoints.deinit();

    var watches = watch_expressions_mod.Store.init(testing.allocator);
    defer watches.deinit();

    // Add some data
    _ = try breakpoints.toggle("src/main.zig", 10);
    _ = try breakpoints.toggle("src/utils.zig", 25);

    _ = try watches.add("count");
    _ = try watches.add("items[0]");

    // Snapshot
    try debug_recovery.snapshotDebugState(testing.allocator, io, root, &breakpoints, &watches);

    // Clear data
    breakpoints.deinit();
    breakpoints = breakpoints_mod.Store.init(testing.allocator);
    watches.clear();

    // Recover
    const recovered = try debug_recovery.recoverDebugState(testing.allocator, io, root, &breakpoints, &watches);
    try testing.expect(recovered);

    // Verify
    try testing.expectEqual(@as(usize, 2), breakpoints.items.items.len);
    try testing.expectEqualStrings("src/main.zig", breakpoints.items.items[0].path);
    try testing.expectEqual(@as(usize, 10), breakpoints.items.items[0].line);
    try testing.expectEqualStrings("src/utils.zig", breakpoints.items.items[1].path);
    try testing.expectEqual(@as(usize, 25), breakpoints.items.items[1].line);

    try testing.expectEqual(@as(usize, 2), watches.items.items.len);
    try testing.expectEqualStrings("count", watches.items.items[0].expression);
    try testing.expectEqualStrings("items[0]", watches.items.items[1].expression);
}
