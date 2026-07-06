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

    var manifest_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const manifest_rel = try std.fmt.bufPrint(&manifest_path_buf, "{s}/{s}", .{ backup_root_rel, history.backup_manifest });
    const manifest_body = readRelativeFile(allocator, io, root, manifest_rel) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (manifest_body) |body| {
        defer allocator.free(body);
        const ManifestEntry = struct { path: []const u8, existed: bool };
        var parsed = try std.json.parseFromSlice([]const ManifestEntry, allocator, body, .{});
        defer parsed.deinit();
        for (parsed.value) |entry| {
            const wp = try path_mod.WorkspacePath.parse(entry.path);
            if (!entry.existed) {
                atomic.deleteFile(io, root, wp) catch |err| switch (err) {
                    error.FileNotFound => {},
                    else => return err,
                };
                continue;
            }
            var backup_path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const backup_rel = try std.fmt.bufPrint(&backup_path_buf, "{s}/{s}", .{ backup_root_rel, entry.path });
            var snap = try @import("snapshot.zig").FileSnapshot.read(allocator, io, root, try path_mod.WorkspacePath.parse(backup_rel));
            defer snap.deinit();
            try atomic.replaceFile(io, root, wp, snap.content);
        }
    } else {
        // Backward compatibility for transactions written before manifests.
        var walker = try root.dir.walk(allocator);
        defer walker.deinit();
        const prefix = try std.fmt.allocPrint(allocator, "{s}/", .{backup_root_rel});
        defer allocator.free(prefix);
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.startsWith(u8, entry.path, prefix)) continue;
            var snap = try @import("snapshot.zig").FileSnapshot.read(allocator, io, root, try path_mod.WorkspacePath.parse(entry.path));
            defer snap.deinit();
            try atomic.replaceFile(io, root, try path_mod.WorkspacePath.parse(entry.path[prefix.len..]), snap.content);
        }
    }

    history.clearActiveMarker(io, root);
}

fn readRelativeFile(allocator: std.mem.Allocator, io: std.Io, root: path_mod.WorkspaceRoot, rel_path: []const u8) ![]u8 {
    var file = try root.dir.openFile(io, rel_path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const content = try allocator.alloc(u8, @intCast(stat.size));
    errdefer allocator.free(content);
    const read_len = try file.readPositionalAll(io, content, 0);
    if (read_len != content.len) return error.UnexpectedEof;
    return content;
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
    {
        var file = try tmp.dir.createFile(io, "created.txt", .{});
        defer file.close(io);
        try file.writeStreamingAll(io, "partial create");
    }
    var backups = [_]transaction.FileBackup{
        .{
            .path = "src.txt",
            .existed = true,
            .content = "original",
        },
        .{
            .path = "created.txt",
            .existed = false,
            .content = "",
        },
        .{
            .path = "deleted.txt",
            .existed = true,
            .content = "restore deleted",
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
    try std.testing.expectError(error.FileNotFound, root.dir.openFile(io, "created.txt", .{}));
    var restored_delete = try @import("snapshot.zig").FileSnapshot.read(allocator, io, root, try path_mod.WorkspacePath.parse("deleted.txt"));
    defer restored_delete.deinit();
    try std.testing.expectEqualStrings("restore deleted", restored_delete.content);
    try std.testing.expect((try history.readActiveMarker(io, root)) == null);
}
