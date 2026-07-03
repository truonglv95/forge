const std = @import("std");
const edit = @import("edit.zig");
const path = @import("path.zig");
const ignore = @import("ignore.zig");

pub const FileSnapshot = struct {
    allocator: std.mem.Allocator,
    content: []const u8,
    hash: u64,

    pub const ReadError = error{
        FileTooLarge,
        UnexpectedEof,
        OutOfMemory,
    } || std.Io.File.OpenError || std.Io.File.StatError || std.Io.File.ReadPositionalError;

    pub fn read(allocator: std.mem.Allocator, io: std.Io, root: path.WorkspaceRoot, file_path: path.WorkspacePath) ReadError!FileSnapshot {
        var file = try root.dir.openFile(io, file_path.raw, .{});
        defer file.close(io);

        const stat = try file.stat(io);
        if (stat.size > ignore.Limits.max_file_size) return error.FileTooLarge;

        const size: usize = @intCast(stat.size);
        const content = try allocator.alloc(u8, size);
        errdefer allocator.free(content);

        const read_len = try file.readPositionalAll(io, content, 0);
        if (read_len != size) return error.UnexpectedEof;

        return FileSnapshot{
            .allocator = allocator,
            .content = content,
            .hash = edit.contentHash(content),
        };
    }

    pub fn deinit(self: *FileSnapshot) void {
        self.allocator.free(self.content);
    }
};

test "FileSnapshot reads file and computes hash" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();

    const rel_path = "sample.txt";
    {
        var file = try tmp.dir.createFile(io, rel_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, "forge");
    }

    var snap = try FileSnapshot.read(allocator, io, path.WorkspaceRoot.init(tmp.dir), try path.WorkspacePath.parse(rel_path));
    defer snap.deinit();

    try std.testing.expectEqualStrings("forge", snap.content);
    try std.testing.expectEqual(edit.contentHash("forge"), snap.hash);
}
