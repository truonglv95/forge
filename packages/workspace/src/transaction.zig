const std = @import("std");
const edit = @import("edit.zig");
const path_mod = @import("path.zig");
const atomic = @import("atomic.zig");
const recovery = @import("recovery.zig");
const history = @import("history.zig");
const snapshot = @import("snapshot.zig");

pub const TransactionState = enum {
    proposed,
    validated,
    approved,
    applying,
    applied,
    validation_failed,
    undone,
    recovery_required,
};

pub const FileBackup = struct {
    path: []const u8,
    existed: bool,
    content: []const u8,
};

pub const TransactionRecord = struct {
    id: u64,
    state: TransactionState,
    workspace_edit: edit.WorkspaceEdit,
    timestamp_ms: i64,
    backups: []FileBackup = &.{},
};

pub const TransactionError = error{
    InvalidState,
    StaleContent,
    InvalidRange,
    PathAlreadyExists,
    FileNotFound,
    ApplyFailed,
} || edit.WorkspaceEdit.ValidationError || path_mod.WorkspacePath.ValidationError || snapshot.FileSnapshot.ReadError || std.Io.File.OpenError;

pub const TransactionService = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root: path_mod.WorkspaceRoot,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, root: path_mod.WorkspaceRoot) TransactionService {
        return .{ .allocator = allocator, .io = io, .root = root };
    }

    pub fn validatePreconditions(self: *TransactionService, workspace_edit: edit.WorkspaceEdit) !void {
        try workspace_edit.validate();
        for (workspace_edit.files) |file_edit| {
            const wp = try path_mod.WorkspacePath.parse(file_edit.path);
            switch (file_edit.operation) {
                .create => {
                    if (rootFileExists(self.io, self.root, wp)) return error.PathAlreadyExists;
                },
                .modify, .delete => {
                    var snap = try snapshot.FileSnapshot.read(self.allocator, self.io, self.root, wp);
                    defer snap.deinit();
                    const expected = file_edit.expected_hash orelse return error.StaleContent;
                    if (snap.hash != expected) return error.StaleContent;
                },
            }
        }
    }

    pub fn apply(self: *TransactionService, record: *TransactionRecord) !void {
        if (record.state != .approved) return error.InvalidState;

        try self.validatePreconditions(record.workspace_edit);

        var backups: std.ArrayList(FileBackup) = .empty;
        errdefer {
            freeBackups(self.allocator, backups.items);
            backups.deinit(self.allocator);
        }

        record.state = .applying;
        try recovery.writeRecord(self.io, self.root, record);

        for (record.workspace_edit.files) |file_edit| {
            const wp = try path_mod.WorkspacePath.parse(file_edit.path);
            try captureBackup(self, &backups, wp);
        }

        record.backups = try backups.toOwnedSlice(self.allocator);
        try history.persistBackups(self.io, self.root, record);

        var applied_index: usize = 0;
        errdefer rollbackApplied(self, record.backups[0..applied_index]) catch {};

        for (record.workspace_edit.files, 0..) |file_edit, index| {
            const wp = try path_mod.WorkspacePath.parse(file_edit.path);
            switch (file_edit.operation) {
                .create, .modify => {
                    const content = try record.workspace_edit.materializeContent(self.allocator, self.io, self.root, file_edit);
                    defer self.allocator.free(content);
                    if (file_edit.operation == .create) {
                        try atomic.createFile(self.io, self.root, wp, content);
                    } else {
                        try atomic.replaceFile(self.io, self.root, wp, content);
                    }
                },
                .delete => try atomic.deleteFile(self.io, self.root, wp),
            }
            applied_index = index + 1;
        }

        record.state = .applied;
        try recovery.writeRecord(self.io, self.root, record);
    }

    pub fn undo(self: *TransactionService, record: *TransactionRecord) !void {
        if (record.state != .applied) return error.InvalidState;

        var reverse_index = record.backups.len;

        while (reverse_index > 0) {
            reverse_index -= 1;
            const backup = record.backups[reverse_index];
            const wp = try path_mod.WorkspacePath.parse(backup.path);

            if (backup.existed) {
                try atomic.replaceFile(self.io, self.root, wp, backup.content);
            } else {
                atomic.deleteFile(self.io, self.root, wp) catch |err| switch (err) {
                    error.FileNotFound => {},
                    else => return err,
                };
            }
        }

        record.state = .undone;
        try recovery.writeRecord(self.io, self.root, record);
    }

    pub fn freeRecord(self: *TransactionService, record: *TransactionRecord) void {
        freeBackups(self.allocator, record.backups);
        if (record.backups.len != 0) self.allocator.free(record.backups);
        record.backups = &.{};
    }
};

fn rootFileExists(io: std.Io, root: path_mod.WorkspaceRoot, wp: path_mod.WorkspacePath) bool {
    root.dir.access(io, wp.raw, .{}) catch return false;
    return true;
}

fn captureBackup(
    self: *TransactionService,
    backups: *std.ArrayList(FileBackup),
    wp: path_mod.WorkspacePath,
) !void {
    const existed = rootFileExists(self.io, self.root, wp);
    const content: []const u8 = if (existed) blk: {
        var snap = try snapshot.FileSnapshot.read(self.allocator, self.io, self.root, wp);
        defer snap.deinit();
        break :blk try self.allocator.dupe(u8, snap.content);
    } else "";

    try backups.append(self.allocator, .{
        .path = try self.allocator.dupe(u8, wp.raw),
        .existed = existed,
        .content = content,
    });
}

fn freeBackups(allocator: std.mem.Allocator, backups: []FileBackup) void {
    for (backups) |backup| {
        allocator.free(backup.path);
        if (backup.existed) allocator.free(backup.content);
    }
}

fn rollbackApplied(self: *TransactionService, backups: []FileBackup) !void {
    var index = backups.len;
    while (index > 0) {
        index -= 1;
        const backup = backups[index];
        const wp = try path_mod.WorkspacePath.parse(backup.path);
        if (backup.existed) {
            try atomic.replaceFile(self.io, self.root, wp, backup.content);
        } else {
            try atomic.deleteFile(self.io, self.root, wp);
        }
    }
}

test "apply modify and undo restores original content" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();

    const rel_path = "notes.txt";
    {
        var file = try tmp.dir.createFile(io, rel_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, "hello world");
    }

    const root = path_mod.WorkspaceRoot.init(tmp.dir);
    const changes = [_]edit.TextEdit{.{ .start = 0, .end = 5, .replacement = "goodbye" }};
    const files = [_]edit.FileEdit{.{
        .path = rel_path,
        .operation = .modify,
        .expected_hash = edit.contentHash("hello world"),
        .edits = &changes,
    }};
    const workspace_edit = edit.WorkspaceEdit{ .files = &files };

    var service = TransactionService.init(allocator, io, root);
    var record = TransactionRecord{
        .id = 1,
        .state = .approved,
        .workspace_edit = workspace_edit,
        .timestamp_ms = 0,
    };
    defer service.freeRecord(&record);

    try service.apply(&record);
    try std.testing.expectEqual(.applied, record.state);

    var after_apply = try snapshot.FileSnapshot.read(allocator, io, root, try path_mod.WorkspacePath.parse(rel_path));
    defer after_apply.deinit();
    try std.testing.expectEqualStrings("goodbye world", after_apply.content);

    try service.undo(&record);
    try std.testing.expectEqual(.undone, record.state);

    var after_undo = try snapshot.FileSnapshot.read(allocator, io, root, try path_mod.WorkspacePath.parse(rel_path));
    defer after_undo.deinit();
    try std.testing.expectEqualStrings("hello world", after_undo.content);
}

test "apply rejects stale content hash" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();

    const rel_path = "stale.txt";
    {
        var file = try tmp.dir.createFile(io, rel_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, "version one");
    }

    const root = path_mod.WorkspaceRoot.init(tmp.dir);
    const changes = [_]edit.TextEdit{.{ .start = 0, .end = 7, .replacement = "version" }};
    const files = [_]edit.FileEdit{.{
        .path = rel_path,
        .operation = .modify,
        .expected_hash = edit.contentHash("old content"),
        .edits = &changes,
    }};

    var service = TransactionService.init(allocator, io, root);
    var record = TransactionRecord{
        .id = 2,
        .state = .approved,
        .workspace_edit = .{ .files = &files },
        .timestamp_ms = 0,
    };
    defer service.freeRecord(&record);

    try std.testing.expectError(error.StaleContent, service.apply(&record));
    try std.testing.expectEqual(.approved, record.state);

    var unchanged = try snapshot.FileSnapshot.read(allocator, io, root, try path_mod.WorkspacePath.parse(rel_path));
    defer unchanged.deinit();
    try std.testing.expectEqualStrings("version one", unchanged.content);
}

test "multi-file apply rolls back when a later file fails" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();

    const first_path = "keep.txt";
    {
        var file = try tmp.dir.createFile(io, first_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, "alpha");
    }

    const root = path_mod.WorkspaceRoot.init(tmp.dir);
    const first_changes = [_]edit.TextEdit{.{ .start = 0, .end = 5, .replacement = "beta" }};
    const files = [_]edit.FileEdit{
        .{
            .path = first_path,
            .operation = .modify,
            .expected_hash = edit.contentHash("alpha"),
            .edits = &first_changes,
        },
        .{
            .path = "blocked.txt",
            .operation = .create,
            .expected_hash = null,
            .edits = &.{},
        },
    };

    {
        var file = try tmp.dir.createFile(io, "blocked.txt", .{});
        defer file.close(io);
        try file.writeStreamingAll(io, "already here");
    }

    var service = TransactionService.init(allocator, io, root);
    var record = TransactionRecord{
        .id = 3,
        .state = .approved,
        .workspace_edit = .{ .files = &files },
        .timestamp_ms = 0,
    };
    defer service.freeRecord(&record);

    try std.testing.expectError(error.PathAlreadyExists, service.apply(&record));

    var restored = try snapshot.FileSnapshot.read(allocator, io, root, try path_mod.WorkspacePath.parse(first_path));
    defer restored.deinit();
    try std.testing.expectEqualStrings("alpha", restored.content);
}

test "apply delete and undo restores deleted file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();

    const rel_path = "remove-me.txt";
    {
        var file = try tmp.dir.createFile(io, rel_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, "gone soon");
    }

    const root = path_mod.WorkspaceRoot.init(tmp.dir);
    const files = [_]edit.FileEdit{.{
        .path = rel_path,
        .operation = .delete,
        .expected_hash = edit.contentHash("gone soon"),
        .edits = &.{},
    }};

    var service = TransactionService.init(allocator, io, root);
    var record = TransactionRecord{
        .id = 5,
        .state = .approved,
        .workspace_edit = .{ .files = &files },
        .timestamp_ms = 0,
    };
    defer service.freeRecord(&record);

    try service.apply(&record);
    root.dir.access(io, rel_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    try service.undo(&record);
    var restored = try snapshot.FileSnapshot.read(allocator, io, root, try path_mod.WorkspacePath.parse(rel_path));
    defer restored.deinit();
    try std.testing.expectEqualStrings("gone soon", restored.content);
}

test "apply create and undo removes created file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();

    const root = path_mod.WorkspaceRoot.init(tmp.dir);
    const files = [_]edit.FileEdit{.{
        .path = "new.txt",
        .operation = .create,
        .expected_hash = null,
        .edits = &.{.{ .start = 0, .end = 0, .replacement = "created" }},
    }};

    var service = TransactionService.init(allocator, io, root);
    var record = TransactionRecord{
        .id = 4,
        .state = .approved,
        .workspace_edit = .{ .files = &files },
        .timestamp_ms = 0,
    };
    defer service.freeRecord(&record);

    try service.apply(&record);

    root.dir.access(io, "new.txt", .{}) catch return error.TestUnexpectedFailure;

    try service.undo(&record);

    root.dir.access(io, "new.txt", .{}) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}
