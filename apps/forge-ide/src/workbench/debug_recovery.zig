const std = @import("std");
const workspace = @import("forge-workspace");
const breakpoints_mod = @import("breakpoints.zig");
const watch_expressions_mod = @import("watch_expressions.zig");

pub const DebugSnapshot = struct {
    breakpoints: []const breakpoints_mod.Entry = &[_]breakpoints_mod.Entry{},
    watch_expressions: []const []const u8 = &[_][]const u8{},
};

pub fn snapshotDebugState(
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace_root: workspace.WorkspaceRoot,
    breakpoints: *const breakpoints_mod.Store,
    watches: *const watch_expressions_mod.Store,
) !void {
    const session_dir = try workspace.global_store.getSessionDir(allocator, io, workspace_root);
    defer allocator.free(session_dir);

    const snapshot_path = try std.fmt.allocPrint(allocator, "{s}/debug_snapshot.json", .{session_dir});
    defer allocator.free(snapshot_path);

    var entries: std.ArrayListUnmanaged(breakpoints_mod.Entry) = .empty;
    defer entries.deinit(allocator);
    for (breakpoints.items.items) |bp| {
        try entries.append(allocator, .{
            .path = bp.path,
            .line = bp.line,
        });
    }

    var watches_arr: std.ArrayListUnmanaged([]const u8) = .empty;
    defer watches_arr.deinit(allocator);
    for (watches.items.items) |watch| {
        try watches_arr.append(allocator, watch.expression);
    }

    const snapshot = DebugSnapshot{
        .breakpoints = entries.items,
        .watch_expressions = watches_arr.items,
    };

    const out_json = try std.json.Stringify.valueAlloc(allocator, snapshot, .{});
    defer allocator.free(out_json);

    try workspace.global_store.replaceAbsoluteFile(io, snapshot_path, out_json);
}

pub fn recoverDebugState(
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace_root: workspace.WorkspaceRoot,
    breakpoints: *breakpoints_mod.Store,
    watches: *watch_expressions_mod.Store,
) !bool {
    const session_dir = try workspace.global_store.getSessionDir(allocator, io, workspace_root);
    defer allocator.free(session_dir);

    const snapshot_path = try std.fmt.allocPrint(allocator, "{s}/debug_snapshot.json", .{session_dir});
    defer allocator.free(snapshot_path);

    const out_json = workspace.global_store.readAbsoluteFile(allocator, io, snapshot_path) catch return false;
    defer allocator.free(out_json);

    var parsed = std.json.parseFromSlice(DebugSnapshot, allocator, out_json, .{
        .ignore_unknown_fields = true,
    }) catch return false;
    defer parsed.deinit();

    if (parsed.value.breakpoints.len > 0) {
        breakpoints.restoreAll(parsed.value.breakpoints) catch {};
    }

    if (parsed.value.watch_expressions.len > 0) {
        watches.clear();
        for (parsed.value.watch_expressions) |expr| {
            _ = watches.add(expr) catch 0;
        }
    }

    return true;
}
