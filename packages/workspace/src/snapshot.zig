const std = @import("std");
const edit = @import("edit.zig");
const path = @import("path.zig");
const ignore = @import("ignore.zig");

pub const FileSnapshot = struct {
    allocator: std.mem.Allocator,
    content: []const u8,
    hash: u64,

    pub fn read(allocator: std.mem.Allocator, io: std.Io, root: path.WorkspaceRoot, file_path: path.WorkspacePath) !FileSnapshot {
        var file = try root.dir.openFile(io, file_path.raw, .{});
        defer file.close();

        const content = try file.readToEndAlloc(allocator, ignore.Limits.max_file_size);
        errdefer allocator.free(content);

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
    // Tests are deferred to integration/e2E tests where a full std.Io instance is initialized.
}
