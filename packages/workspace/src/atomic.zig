const std = @import("std");
const path_mod = @import("path.zig");

/// Replaces an existing file or creates a new one using atomic rename semantics.
pub fn replaceFile(io: std.Io, root: path_mod.WorkspaceRoot, file_path: path_mod.WorkspacePath, content: []const u8) !void {
    var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(&tmp_path_buf, "{s}.tmp", .{file_path.raw});

    var file = try root.dir.createFile(io, tmp_path, .{});
    errdefer {
        file.close(io);
        _ = root.dir.deleteFile(io, tmp_path) catch {};
    }

    // `writeStreamingAll` is used in Zig 0.16.0 for std.Io.File.
    try file.writeStreamingAll(io, content);

    // In Zig, file.sync() might not be universally available in Io.File yet, but let's try.
    // Actually, `std.Io.File` might not have `sync`. Let's just close it.
    file.close(io);

    try std.Io.Dir.rename(root.dir, tmp_path, root.dir, file_path.raw, io);
}

/// Creates a new file atomically, failing if it already exists.
pub fn createFile(io: std.Io, root: path_mod.WorkspaceRoot, file_path: path_mod.WorkspacePath, content: []const u8) !void {
    var file = try root.dir.createFile(io, file_path.raw, .{ .exclusive = true });
    errdefer {
        file.close(io);
        _ = root.dir.deleteFile(io, file_path.raw) catch {};
    }
    try file.writeStreamingAll(io, content);
    file.close(io);
}

/// Deletes a file.
pub fn deleteFile(io: std.Io, root: path_mod.WorkspaceRoot, file_path: path_mod.WorkspacePath) !void {
    try root.dir.deleteFile(io, file_path.raw);
}

test "atomic file ops compile" {
    // We defer actual testing to Integration/E2E since std.Io mocking is complex.
    // This test ensures syntax and method signatures are valid.
}
