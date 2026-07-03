const std = @import("std");

pub const FileOperation = enum { create, modify, delete };

/// A byte range in the exact file version identified by `expected_hash`.
pub const TextEdit = struct {
    start: u64,
    end: u64,
    replacement: []const u8,
};

pub const FileEdit = struct {
    path: []const u8,
    operation: FileOperation,
    expected_hash: ?u64,
    edits: []const TextEdit,
};

/// A non-owning proposed transaction. The producer owns all referenced slices
/// until validation, preview, and apply have completed.
pub const WorkspaceEdit = struct {
    files: []const FileEdit,

    pub const ValidationError = error{
        EmptyTransaction,
        EmptyPath,
        AbsolutePath,
        DuplicatePath,
        MissingPrecondition,
        UnexpectedPrecondition,
        InvalidRange,
        OverlappingEdits,
        UnexpectedTextEdits,
    };

    pub fn validate(self: WorkspaceEdit) ValidationError!void {
        if (self.files.len == 0) return error.EmptyTransaction;

        for (self.files, 0..) |file, file_index| {
            if (file.path.len == 0) return error.EmptyPath;
            if (std.fs.path.isAbsolute(file.path)) return error.AbsolutePath;
            for (self.files[0..file_index]) |previous| {
                if (std.mem.eql(u8, previous.path, file.path)) return error.DuplicatePath;
            }

            switch (file.operation) {
                .create => if (file.expected_hash != null) return error.UnexpectedPrecondition,
                .modify => if (file.expected_hash == null) return error.MissingPrecondition,
                .delete => {
                    if (file.expected_hash == null) return error.MissingPrecondition;
                    if (file.edits.len != 0) return error.UnexpectedTextEdits;
                },
            }

            var previous_end: u64 = 0;
            for (file.edits, 0..) |edit, edit_index| {
                if (edit.start > edit.end) return error.InvalidRange;
                if (edit_index > 0 and edit.start < previous_end) return error.OverlappingEdits;
                previous_end = edit.end;
            }
        }
    }

    pub fn materializeContent(
        self: WorkspaceEdit,
        allocator: std.mem.Allocator,
        io: std.Io,
        root: @import("path.zig").WorkspaceRoot,
        file_edit: FileEdit,
    ) ![]const u8 {
        _ = self;
        return switch (file_edit.operation) {
            .create => try applyTextEdits(allocator, "", file_edit.edits),
            .modify => blk: {
                const wp = try @import("path.zig").WorkspacePath.parse(file_edit.path);
                var snap = try @import("snapshot.zig").FileSnapshot.read(allocator, io, root, wp);
                defer snap.deinit();
                if (file_edit.expected_hash) |expected| {
                    if (snap.hash != expected) return error.StaleContent;
                }
                break :blk try applyTextEdits(allocator, snap.content, file_edit.edits);
            },
            .delete => return error.UnexpectedTextEdits,
        };
    }
};

pub fn applyTextEdits(allocator: std.mem.Allocator, content: []const u8, edits: []const TextEdit) ![]u8 {
    if (edits.len == 0) return try allocator.dupe(u8, content);

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    var src_pos: usize = 0;
    for (edits) |edit| {
        const start: usize = @intCast(edit.start);
        const end: usize = @intCast(edit.end);
        if (start < src_pos or end > content.len or start > end) return error.InvalidRange;
        try result.appendSlice(allocator, content[src_pos..start]);
        try result.appendSlice(allocator, edit.replacement);
        src_pos = end;
    }
    try result.appendSlice(allocator, content[src_pos..]);
    return try result.toOwnedSlice(allocator);
}

pub fn contentHash(content: []const u8) u64 {
    return std.hash.Wyhash.hash(0, content);
}

test "valid multi-file workspace edit has explicit preconditions" {
    const changes = [_]TextEdit{.{ .start = 0, .end = 3, .replacement = "const" }};
    const files = [_]FileEdit{
        .{ .path = "src/main.zig", .operation = .modify, .expected_hash = contentHash("var"), .edits = &changes },
        .{ .path = "src/new.zig", .operation = .create, .expected_hash = null, .edits = &.{} },
    };
    try (WorkspaceEdit{ .files = &files }).validate();
}

test "unsafe workspace edits are rejected" {
    const missing_hash = [_]FileEdit{.{
        .path = "src/main.zig",
        .operation = .modify,
        .expected_hash = null,
        .edits = &.{},
    }};
    try std.testing.expectError(error.MissingPrecondition, (WorkspaceEdit{ .files = &missing_hash }).validate());

    const duplicate = [_]FileEdit{
        .{ .path = "src/a.zig", .operation = .create, .expected_hash = null, .edits = &.{} },
        .{ .path = "src/a.zig", .operation = .create, .expected_hash = null, .edits = &.{} },
    };
    try std.testing.expectError(error.DuplicatePath, (WorkspaceEdit{ .files = &duplicate }).validate());
}
