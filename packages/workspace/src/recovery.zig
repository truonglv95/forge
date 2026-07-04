const std = @import("std");
const transaction = @import("transaction.zig");
const path_mod = @import("path.zig");
const history = @import("history.zig");
const atomic = @import("atomic.zig");

pub fn writeRecord(io: std.Io, root: path_mod.WorkspaceRoot, record: *const transaction.TransactionRecord) !void {
    switch (record.state) {
        .applying => try history.writeActiveMarker(io, root, record.id),
        .applied, .undone, .validation_failed => history.clearActiveMarker(io, root),
        else => {},
    }
}

pub fn recoverPending(allocator: std.mem.Allocator, io: std.Io, root: path_mod.WorkspaceRoot) !void {
    const active_id = try history.readActiveMarker(io, root);
    const id = active_id orelse return;

    var backup_root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const backup_root_rel = try std.fmt.bufPrint(&backup_root_buf, "{s}/{d}", .{ history.backups_dir, id });

    root.dir.access(io, backup_root_rel, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            history.clearActiveMarker(io, root);
            return;
        },
        else => return err,
    };

    var walker = try root.dir.walk(allocator);
    defer walker.deinit();

    const prefix = try std.fmt.allocPrint(allocator, "{s}/", .{backup_root_rel});
    defer allocator.free(prefix);

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.path, prefix)) continue;
        var snap = try @import("snapshot.zig").FileSnapshot.read(allocator, io, root, try path_mod.WorkspacePath.parse(entry.path));
        defer snap.deinit();
        const restore_path = entry.path[prefix.len..];
        const wp = try path_mod.WorkspacePath.parse(restore_path);
        try atomic.replaceFile(io, root, wp, snap.content);
    }

    history.clearActiveMarker(io, root);
}

test "recovery clears active marker when none exists" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const root = path_mod.WorkspaceRoot.init(tmp.dir);
    try recoverPending(std.testing.allocator, io, root);
}

test "recoverPending restores files from backup directory" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const root = path_mod.WorkspaceRoot.init(tmp.dir);

    try history.ensureLayout(io, root);
    {
        var file = try tmp.dir.createFile(io, "src.txt", .{});
        defer file.close(io);
        try file.writeStreamingAll(io, "corrupted");
    }
    var backups = [_]transaction.FileBackup{
        .{
            .path = "src.txt",
            .existed = true,
            .content = "original",
        },
    };
    try history.persistBackups(io, root, &.{
        .id = 7,
        .state = .applying,
        .workspace_edit = .{ .files = &.{} },
        .timestamp_ms = 0,
        .backups = backups[0..],
    });
    try history.writeActiveMarker(io, root, 7);

    try recoverPending(allocator, io, root);

    var snap = try @import("snapshot.zig").FileSnapshot.read(allocator, io, root, try path_mod.WorkspacePath.parse("src.txt"));
    defer snap.deinit();
    try std.testing.expectEqualStrings("original", snap.content);
    try std.testing.expect((try history.readActiveMarker(io, root)) == null);
}
