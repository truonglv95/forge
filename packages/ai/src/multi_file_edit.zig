//! Multi-File Editing (Composer) — agent can edit multiple files atomically.
//! All changes are proposed as a batch, previewed by the user, and applied
//! together or rejected entirely (atomic operation).
const std = @import("std");

pub const FileEdit = struct {
    file_path: []const u8,
    operation: EditOp,
    content: ?[]const u8 = null, // For create/replace
    old_content: ?[]const u8 = null, // For diff display
    diff: ?[]const u8 = null, // Unified diff for preview

    pub fn deinit(self: *FileEdit, allocator: std.mem.Allocator) void {
        allocator.free(self.file_path);
        if (self.content) |c| allocator.free(c);
        if (self.old_content) |c| allocator.free(c);
        if (self.diff) |d| allocator.free(d);
    }
};

pub const EditOp = enum {
    create, // New file
    modify, // Edit existing file
    delete, // Delete file
    rename, // Rename/move file (content has new path)
};

pub const ComposerBatch = struct {
    allocator: std.mem.Allocator,
    edits: std.ArrayList(FileEdit),
    description: ?[]const u8 = null,
    accepted: std.AutoHashMap(usize, void),

    pub fn init(allocator: std.mem.Allocator) ComposerBatch {
        return .{
            .allocator = allocator,
            .edits = .empty,
            .accepted = std.AutoHashMap(usize, void).init(allocator),
        };
    }

    pub fn deinit(self: *ComposerBatch) void {
        for (self.edits.items) |*edit| edit.deinit(self.allocator);
        self.edits.deinit(self.allocator);
        self.accepted.deinit();
        if (self.description) |d| self.allocator.free(d);
    }

    /// Add a file edit to the batch. Takes ownership of all fields.
    pub fn addEdit(self: *ComposerBatch, edit: FileEdit) !void {
        try self.edits.append(self.allocator, edit);
    }

    /// Toggle acceptance of a specific edit (user can selectively accept).
    pub fn toggleAccept(self: *ComposerBatch, index: usize) !void {
        if (index >= self.edits.items.len) return;
        if (self.accepted.contains(index)) {
            _ = self.accepted.remove(index);
        } else {
            try self.accepted.put(index, {});
        }
    }

    /// Accept all edits.
    pub fn acceptAll(self: *ComposerBatch) !void {
        self.accepted.clearRetainingCapacity();
        for (0..self.edits.items.len) |i| {
            try self.accepted.put(i, {});
        }
    }

    /// Check if a specific edit is accepted.
    pub fn isAccepted(self: *const ComposerBatch, index: usize) bool {
        return self.accepted.contains(index);
    }

    /// Get the list of accepted edit indices.
    pub fn acceptedIndices(self: *const ComposerBatch, allocator: std.mem.Allocator) ![]usize {
        var list: std.ArrayList(usize) = .empty;
        errdefer list.deinit(allocator);
        var it = self.accepted.keyIterator();
        while (it.next()) |key| {
            try list.append(allocator, key.*);
        }
        std.sort.block(usize, list.items, {}, std.sort.asc(usize));
        return list.toOwnedSlice(allocator);
    }

    /// Count of files by operation type.
    pub fn stats(self: *const ComposerBatch) BatchStats {
        var s: BatchStats = .{};
        for (self.edits.items) |edit| {
            switch (edit.operation) {
                .create => s.created += 1,
                .modify => s.modified += 1,
                .delete => s.deleted += 1,
                .rename => s.renamed += 1,
            }
        }
        return s;
    }
};

pub const BatchStats = struct {
    created: usize = 0,
    modified: usize = 0,
    deleted: usize = 0,
    renamed: usize = 0,

    pub fn total(self: BatchStats) usize {
        return self.created + self.modified + self.deleted + self.renamed;
    }

    pub fn summary(self: BatchStats, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{d} created, {d} modified, {d} deleted, {d} renamed", .{
            self.created, self.modified, self.deleted, self.renamed,
        }) catch "changes";
    }
};

/// Generate a simple unified diff between old and new content.
pub fn generateDiff(allocator: std.mem.Allocator, old: []const u8, new: []const u8, file_path: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "--- a/");
    try buf.appendSlice(allocator, file_path);
    try buf.append(allocator, '\n');
    try buf.appendSlice(allocator, "+++ b/");
    try buf.appendSlice(allocator, file_path);
    try buf.append(allocator, '\n');

    var old_lines = std.mem.splitScalar(u8, old, '\n');
    var new_lines = std.mem.splitScalar(u8, new, '\n');

    // Simple line-by-line diff (not LCS — just show all changes)
    while (true) {
        const old_line = old_lines.next();
        const new_line = new_lines.next();
        if (old_line == null and new_line == null) break;

        if (old_line != null and new_line != null) {
            if (std.mem.eql(u8, old_line.?, new_line.?)) {
                try buf.append(allocator, ' ');
                try buf.appendSlice(allocator, old_line.?);
                try buf.append(allocator, '\n');
            } else {
                try buf.append(allocator, '-');
                try buf.appendSlice(allocator, old_line.?);
                try buf.append(allocator, '\n');
                try buf.append(allocator, '+');
                try buf.appendSlice(allocator, new_line.?);
                try buf.append(allocator, '\n');
            }
        } else if (old_line != null) {
            try buf.append(allocator, '-');
            try buf.appendSlice(allocator, old_line.?);
            try buf.append(allocator, '\n');
        } else if (new_line != null) {
            try buf.append(allocator, '+');
            try buf.appendSlice(allocator, new_line.?);
            try buf.append(allocator, '\n');
        }
    }

    return buf.toOwnedSlice(allocator);
}

test "ComposerBatch add and accept" {
    const allocator = std.testing.allocator;
    var batch = ComposerBatch.init(allocator);
    defer batch.deinit();

    try batch.addEdit(.{
        .file_path = try allocator.dupe(u8, "a.zig"),
        .operation = .modify,
        .content = try allocator.dupe(u8, "new content"),
    });
    try batch.addEdit(.{
        .file_path = try allocator.dupe(u8, "b.zig"),
        .operation = .create,
        .content = try allocator.dupe(u8, "new file"),
    });

    try std.testing.expectEqual(@as(usize, 2), batch.edits.items.len);
    try std.testing.expect(!batch.isAccepted(0));

    try batch.toggleAccept(0);
    try std.testing.expect(batch.isAccepted(0));

    try batch.acceptAll();
    try std.testing.expect(batch.isAccepted(0));
    try std.testing.expect(batch.isAccepted(1));
}

test "BatchStats summary" {
    var buf: [128]u8 = undefined;
    const s = BatchStats{ .created = 2, .modified = 3 };
    const result = s.summary(&buf);
    try std.testing.expect(std.mem.indexOf(u8, result, "created") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "modified") != null);
}

test "generateDiff shows changes" {
    const allocator = std.testing.allocator;
    const diff = try generateDiff(allocator, "line1\nline2\nline3", "line1\nchanged\nline3", "test.zig");
    defer allocator.free(diff);
    try std.testing.expect(std.mem.indexOf(u8, diff, "-line2") != null);
    try std.testing.expect(std.mem.indexOf(u8, diff, "+changed") != null);
}
