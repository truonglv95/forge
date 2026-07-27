const std = @import("std");
const fast_apply = @import("fast_apply.zig");

pub const FileOperation = enum { create, modify, delete };

/// A byte range in the exact file version identified by `expected_hash`.
pub const TextEdit = struct {
    start: u64 = 0,
    end: u64 = 0,
    search: ?[]const u8 = null,
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

    pub fn clone(self: WorkspaceEdit, allocator: std.mem.Allocator) !WorkspaceEdit {
        var files = try allocator.alloc(FileEdit, self.files.len);
        errdefer {
            for (files) |*f| {
                if (f.edits.len > 0) allocator.free(f.edits);
                allocator.free(f.path);
            }
            allocator.free(files);
        }

        for (self.files, 0..) |f, i| {
            var edits = try allocator.alloc(TextEdit, f.edits.len);
            errdefer {
                for (edits) |*e| {
                    allocator.free(e.replacement);
                    if (e.search) |s| allocator.free(s);
                }
                allocator.free(edits);
            }

            for (f.edits, 0..) |e, j| {
                edits[j] = .{
                    .start = e.start,
                    .end = e.end,
                    .search = if (e.search) |s| try allocator.dupe(u8, s) else null,
                    .replacement = try allocator.dupe(u8, e.replacement),
                };
            }

            files[i] = .{
                .path = try allocator.dupe(u8, f.path),
                .operation = f.operation,
                .expected_hash = f.expected_hash,
                .edits = edits,
            };
        }

        return .{ .files = files };
    }

    pub fn deinit(self: *WorkspaceEdit, allocator: std.mem.Allocator) void {
        for (self.files) |f| {
            for (f.edits) |e| {
                allocator.free(e.replacement);
                if (e.search) |s| allocator.free(s);
            }
            allocator.free(f.edits);
            allocator.free(f.path);
        }
        allocator.free(self.files);
    }

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

    /// P1.8: Build a subset of this WorkspaceEdit containing only the specified
    /// file indices and, for each included file, only the specified edit indices.
    /// This enables hunk-level accept/reject: the caller can apply only the
    /// hunks the user accepted and skip the rejected ones.
    ///
    /// `file_selection` is a slice of (file_index, edit_indices_slice) pairs.
    /// Files not in the selection are excluded entirely. Edits not in the
    /// per-file selection are excluded. The returned WorkspaceEdit is owned
    /// by the caller (use deinit to free).
    ///
    /// For `delete` operations, all edits are ignored (delete has no edits).
    /// For `create` operations, all edits in the selection are applied to
    /// the empty initial content.
    pub const FileSelection = struct {
        file_index: usize,
        edit_indices: []const usize,
    };

    pub fn buildSubset(
        self: WorkspaceEdit,
        allocator: std.mem.Allocator,
        file_selection: []const FileSelection,
    ) !WorkspaceEdit {
        if (file_selection.len == 0) return error.EmptyTransaction;

        // Validate all indices first (before any allocation) so error paths
        // don't need to clean up partial state.
        for (file_selection) |sel| {
            if (sel.file_index >= self.files.len) return error.InvalidRange;
            const src_file = self.files[sel.file_index];
            if (src_file.operation != .delete) {
                for (sel.edit_indices) |edit_idx| {
                    if (edit_idx >= src_file.edits.len) return error.InvalidRange;
                }
            }
        }

        var files = try allocator.alloc(FileEdit, file_selection.len);
        errdefer {
            for (files) |*f| {
                if (f.path.len > 0) {
                    if (f.edits.len > 0) allocator.free(f.edits);
                    allocator.free(f.path);
                }
            }
            allocator.free(files);
        }

        // Initialize all files entries to empty so errdefer can safely iterate.
        for (files) |*f| {
            f.* = .{
                .path = &.{},
                .operation = .create,
                .expected_hash = null,
                .edits = &.{},
            };
        }

        for (file_selection, 0..) |sel, out_i| {
            const src_file = self.files[sel.file_index];

            // For delete operations, ignore edit_indices (delete has no edits).
            const edit_count = if (src_file.operation == .delete) 0 else sel.edit_indices.len;
            var edits = try allocator.alloc(TextEdit, edit_count);
            errdefer {
                for (edits) |*e| {
                    if (e.replacement.len > 0) allocator.free(e.replacement);
                    if (e.search) |s| allocator.free(s);
                }
                allocator.free(edits);
            }

            // Initialize edits to empty so errdefer can safely iterate.
            for (edits) |*e| {
                e.* = .{ .start = 0, .end = 0, .search = null, .replacement = &.{} };
            }

            if (src_file.operation != .delete) {
                for (sel.edit_indices, 0..) |edit_idx, j| {
                    const src_edit = src_file.edits[edit_idx];
                    edits[j] = .{
                        .start = src_edit.start,
                        .end = src_edit.end,
                        .search = if (src_edit.search) |s| try allocator.dupe(u8, s) else null,
                        .replacement = try allocator.dupe(u8, src_edit.replacement),
                    };
                }
            }

            files[out_i] = .{
                .path = try allocator.dupe(u8, src_file.path),
                .operation = src_file.operation,
                .expected_hash = src_file.expected_hash,
                .edits = edits,
            };
        }

        return .{ .files = files };
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

    var uses_search = false;
    for (edits) |edit| {
        if (edit.search != null) uses_search = true;
    }

    if (uses_search) {
        var current_content = try allocator.dupe(u8, content);
        errdefer allocator.free(current_content);

        for (edits) |edit| {
            if (edit.search) |search_text| {
                const new_content = try fast_apply.applyEdit(allocator, current_content, .{
                    .search = search_text,
                    .replace = edit.replacement,
                });
                allocator.free(current_content);
                current_content = new_content;
            } else {
                return error.MixedEditTypes;
            }
        }
        return current_content;
    }

    var result: std.ArrayListUnmanaged(u8) = .empty;
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

test "buildSubset selects only specified files and edits" {
    const allocator = std.testing.allocator;
    const edit1 = TextEdit{ .start = 0, .end = 3, .replacement = "abc" };
    const edit2 = TextEdit{ .start = 5, .end = 8, .replacement = "xyz" };
    const edit3 = TextEdit{ .start = 10, .end = 13, .replacement = "def" };
    const edits = [_]TextEdit{ edit1, edit2, edit3 };
    const files = [_]FileEdit{
        .{ .path = "src/main.zig", .operation = .modify, .expected_hash = 42, .edits = &edits },
    };
    const original = WorkspaceEdit{ .files = &files };

    // Select only edit index 0 and 2 (skip edit 1).
    const sel = [_]usize{ 0, 2 };
    const file_sel = [_]WorkspaceEdit.FileSelection{
        .{ .file_index = 0, .edit_indices = &sel },
    };
    var subset = try original.buildSubset(allocator, &file_sel);
    defer subset.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), subset.files.len);
    try std.testing.expectEqualStrings("src/main.zig", subset.files[0].path);
    try std.testing.expectEqual(@as(usize, 2), subset.files[0].edits.len);
    try std.testing.expectEqualStrings("abc", subset.files[0].edits[0].replacement);
    try std.testing.expectEqualStrings("def", subset.files[0].edits[1].replacement);
}

test "buildSubset rejects empty selection" {
    const allocator = std.testing.allocator;
    const files = [_]FileEdit{
        .{ .path = "src/main.zig", .operation = .modify, .expected_hash = 42, .edits = &.{} },
    };
    const original = WorkspaceEdit{ .files = &files };
    try std.testing.expectError(error.EmptyTransaction, original.buildSubset(allocator, &.{}));
}

test "buildSubset rejects out-of-range file index" {
    const allocator = std.testing.allocator;
    const files = [_]FileEdit{
        .{ .path = "src/main.zig", .operation = .modify, .expected_hash = 42, .edits = &.{} },
    };
    const original = WorkspaceEdit{ .files = &files };
    const sel = [_]usize{};
    const file_sel = [_]WorkspaceEdit.FileSelection{
        .{ .file_index = 5, .edit_indices = &sel },
    };
    try std.testing.expectError(error.InvalidRange, original.buildSubset(allocator, &file_sel));
}

test "buildSubset handles delete operations (no edits)" {
    const allocator = std.testing.allocator;
    const files = [_]FileEdit{
        .{ .path = "src/old.zig", .operation = .delete, .expected_hash = 99, .edits = &.{} },
    };
    const original = WorkspaceEdit{ .files = &files };
    // edit_indices is ignored for delete operations.
    const dummy = [_]usize{ 0, 1, 2 };
    const file_sel = [_]WorkspaceEdit.FileSelection{
        .{ .file_index = 0, .edit_indices = &dummy },
    };
    var subset = try original.buildSubset(allocator, &file_sel);
    defer subset.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), subset.files.len);
    try std.testing.expectEqual(FileOperation.delete, subset.files[0].operation);
    try std.testing.expectEqual(@as(usize, 0), subset.files[0].edits.len);
}
