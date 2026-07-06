const std = @import("std");
const path_mod = @import("path.zig");
const atomic = @import("atomic.zig");
const snapshot = @import("snapshot.zig");
const history = @import("history.zig");
const edit = @import("edit.zig");

pub const checkpoints_dir = ".forge/checkpoints";
pub const index_file = ".forge/checkpoints/index.jsonl";

pub const Entry = struct {
    id: u64,
    run_id: ?[]const u8,
    transaction_id: ?u64,
    timestamp_ms: i64,
    label: []const u8,
    file_count: u32,
};

pub const EntryList = struct {
    allocator: std.mem.Allocator,
    items: []Entry,

    pub fn deinit(self: *EntryList) void {
        for (self.items) |entry| {
            if (entry.run_id) |id| self.allocator.free(id);
            self.allocator.free(entry.label);
        }
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

pub const CheckpointError = error{
    CheckpointNotFound,
    WorkspaceFailed,
    OutOfMemory,
} || snapshot.FileSnapshot.ReadError || path_mod.WorkspacePath.ValidationError || std.Io.File.OpenError;

pub fn ensureLayout(io: std.Io, root: path_mod.WorkspaceRoot) !void {
    try history.ensureLayout(io, root);
    try root.dir.createDirPath(io, checkpoints_dir);
}

pub fn nextId(allocator: std.mem.Allocator, io: std.Io, root: path_mod.WorkspaceRoot) !u64 {
    var list = try listEntries(allocator, io, root);
    defer list.deinit();
    var max_id: u64 = 0;
    for (list.items) |entry| max_id = @max(max_id, entry.id);
    return max_id + 1;
}

pub fn listEntries(allocator: std.mem.Allocator, io: std.Io, root: path_mod.WorkspaceRoot) CheckpointError!EntryList {
    var items: std.ArrayList(Entry) = .empty;
    errdefer {
        for (items.items) |entry| {
            if (entry.run_id) |id| allocator.free(id);
            allocator.free(entry.label);
        }
        items.deinit(allocator);
    }

    const content = readRelative(allocator, io, root, index_file) catch |err| switch (err) {
        error.FileNotFound => return EntryList{ .allocator = allocator, .items = try items.toOwnedSlice(allocator) },
        else => return err,
    };
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const JsonEntry = struct {
            id: u64,
            run_id: ?[]const u8 = null,
            transaction_id: ?u64 = null,
            timestamp_ms: i64,
            label: []const u8,
            file_count: u32,
        };
        var parsed = std.json.parseFromSlice(JsonEntry, allocator, line, .{ .ignore_unknown_fields = true }) catch continue;
        defer parsed.deinit();
        const run_id = if (parsed.value.run_id) |id| try allocator.dupe(u8, id) else null;
        errdefer if (run_id) |id| allocator.free(id);
        try items.append(allocator, .{
            .id = parsed.value.id,
            .run_id = run_id,
            .transaction_id = parsed.value.transaction_id,
            .timestamp_ms = parsed.value.timestamp_ms,
            .label = try allocator.dupe(u8, parsed.value.label),
            .file_count = parsed.value.file_count,
        });
    }

    return EntryList{ .allocator = allocator, .items = try items.toOwnedSlice(allocator) };
}

pub const CreateOptions = struct {
    run_id: ?[]const u8 = null,
    label: []const u8 = "pre-apply",
};

/// Snapshots workspace state before apply. Returns checkpoint id.
pub fn createFromEdits(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: path_mod.WorkspaceRoot,
    file_edits: []const edit.FileEdit,
    options: CreateOptions,
) CheckpointError!u64 {
    ensureLayout(io, root) catch return error.WorkspaceFailed;
    const id = try nextId(allocator, io, root);
    const timestamp_ms = std.Io.Timestamp.now(io, .real).toMilliseconds();

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const checkpoint_root = try std.fmt.bufPrint(&root_buf, "{s}/{d}", .{ checkpoints_dir, id });
    root.dir.createDirPath(io, checkpoint_root) catch return error.WorkspaceFailed;

    const ManifestEntry = struct {
        path: []const u8,
        operation: []const u8,
    };

    var manifest: std.ArrayList(ManifestEntry) = .empty;
    errdefer {
        for (manifest.items) |entry| {
            allocator.free(entry.path);
            allocator.free(entry.operation);
        }
        manifest.deinit(allocator);
    }

    for (file_edits) |file_edit| {
        const wp = path_mod.WorkspacePath.parse(file_edit.path) catch return error.WorkspaceFailed;
        const op_name = @tagName(file_edit.operation);

        switch (file_edit.operation) {
            .create => {
                try manifest.append(allocator, .{
                    .path = try allocator.dupe(u8, file_edit.path),
                    .operation = try allocator.dupe(u8, op_name),
                });
            },
            .modify, .delete => {
                var snap = snapshot.FileSnapshot.read(allocator, io, root, wp) catch |err| switch (err) {
                    error.FileNotFound => continue,
                    else => return err,
                };
                defer snap.deinit();

                var backup_buf: [std.fs.max_path_bytes]u8 = undefined;
                const backup_rel = try std.fmt.bufPrint(&backup_buf, "{s}/{s}", .{ checkpoint_root, file_edit.path });
                if (std.mem.lastIndexOfScalar(u8, backup_rel, '/')) |slash| {
                    const parent = backup_rel[0..slash];
                    root.dir.createDirPath(io, parent) catch |err| switch (err) {
                        error.PathAlreadyExists => {},
                        else => return error.WorkspaceFailed,
                    };
                }
                atomic.replaceFile(io, root, path_mod.WorkspacePath.parse(backup_rel) catch return error.WorkspaceFailed, snap.content) catch return error.WorkspaceFailed;
                try manifest.append(allocator, .{
                    .path = try allocator.dupe(u8, file_edit.path),
                    .operation = try allocator.dupe(u8, op_name),
                });
            },
        }
    }

    const manifest_json = std.json.Stringify.valueAlloc(allocator, manifest.items, .{}) catch return error.WorkspaceFailed;
    defer allocator.free(manifest_json);
    var manifest_buf: [std.fs.max_path_bytes]u8 = undefined;
    const manifest_rel = try std.fmt.bufPrint(&manifest_buf, "{s}/manifest.json", .{checkpoint_root});
    atomic.replaceFile(io, root, path_mod.WorkspacePath.parse(manifest_rel) catch return error.WorkspaceFailed, manifest_json) catch return error.WorkspaceFailed;

    const IndexLine = struct {
        id: u64,
        run_id: ?[]const u8 = null,
        transaction_id: ?u64 = null,
        timestamp_ms: i64,
        label: []const u8,
        file_count: u32,
    };
    const line = try std.json.Stringify.valueAlloc(allocator, IndexLine{
        .id = id,
        .run_id = options.run_id,
        .transaction_id = null,
        .timestamp_ms = timestamp_ms,
        .label = options.label,
        .file_count = @intCast(manifest.items.len),
    }, .{});
    defer allocator.free(line);
    const line_with_nl = std.fmt.allocPrint(allocator, "{s}\n", .{line}) catch return error.WorkspaceFailed;
    defer allocator.free(line_with_nl);
    try appendIndex(io, root, line_with_nl);

    for (manifest.items) |entry| {
        allocator.free(entry.path);
        allocator.free(entry.operation);
    }
    manifest.deinit(allocator);

    return id;
}

/// Backward-compatible helper for modify-only snapshots.
pub fn create(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: path_mod.WorkspaceRoot,
    paths: []const []const u8,
    options: CreateOptions,
) CheckpointError!u64 {
    var edits: std.ArrayList(edit.FileEdit) = .empty;
    defer edits.deinit(allocator);
    for (paths) |path| {
        edits.append(allocator, .{
            .path = path,
            .operation = .modify,
            .expected_hash = null,
            .edits = &.{},
        }) catch return error.OutOfMemory;
    }
    return createFromEdits(allocator, io, root, edits.items, options);
}

pub fn linkTransaction(io: std.Io, root: path_mod.WorkspaceRoot, checkpoint_id: u64, transaction_id: u64) CheckpointError!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var list = try listEntries(allocator, io, root);
    defer list.deinit();

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);
    for (list.items) |entry| {
        const tx = if (entry.id == checkpoint_id) transaction_id else entry.transaction_id;
        const IndexLine = struct {
            id: u64,
            run_id: ?[]const u8 = null,
            transaction_id: ?u64 = null,
            timestamp_ms: i64,
            label: []const u8,
            file_count: u32,
        };
        const line = try std.json.Stringify.valueAlloc(allocator, IndexLine{
            .id = entry.id,
            .run_id = entry.run_id,
            .transaction_id = tx,
            .timestamp_ms = entry.timestamp_ms,
            .label = entry.label,
            .file_count = entry.file_count,
        }, .{});
        defer allocator.free(line);
        try buffer.appendSlice(allocator, line);
        try buffer.append(allocator, '\n');
    }
    atomic.replaceFile(io, root, path_mod.WorkspacePath.parse(index_file) catch return error.WorkspaceFailed, buffer.items) catch return error.WorkspaceFailed;
}

/// Restores files captured in a checkpoint.
pub fn restore(allocator: std.mem.Allocator, io: std.Io, root: path_mod.WorkspaceRoot, checkpoint_id: u64) CheckpointError!void {
    ensureExists(allocator, io, root, checkpoint_id) catch return error.CheckpointNotFound;

    var manifest_buf: [std.fs.max_path_bytes]u8 = undefined;
    const manifest_rel = try std.fmt.bufPrint(&manifest_buf, "{s}/{d}/manifest.json", .{ checkpoints_dir, checkpoint_id });
    var manifest_snap = try snapshot.FileSnapshot.read(allocator, io, root, try path_mod.WorkspacePath.parse(manifest_rel));
    defer manifest_snap.deinit();

    const ManifestEntry = struct {
        path: []const u8,
        operation: []const u8,
    };

    const parsed = std.json.parseFromSlice([]ManifestEntry, allocator, manifest_snap.content, .{}) catch return error.CheckpointNotFound;
    defer parsed.deinit();

    var checkpoint_root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const checkpoint_root = try std.fmt.bufPrint(&checkpoint_root_buf, "{s}/{d}", .{ checkpoints_dir, checkpoint_id });

    for (parsed.value) |entry| {
        const wp = path_mod.WorkspacePath.parse(entry.path) catch return error.WorkspaceFailed;
        if (std.mem.eql(u8, entry.operation, "create")) {
            atomic.deleteFile(io, root, wp) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return error.WorkspaceFailed,
            };
            continue;
        }

        var backup_buf: [std.fs.max_path_bytes]u8 = undefined;
        const backup_rel = try std.fmt.bufPrint(&backup_buf, "{s}/{s}", .{ checkpoint_root, entry.path });
        var snap = try snapshot.FileSnapshot.read(allocator, io, root, try path_mod.WorkspacePath.parse(backup_rel));
        defer snap.deinit();
        atomic.replaceFile(io, root, wp, snap.content) catch return error.WorkspaceFailed;
    }
}

fn ensureExists(allocator: std.mem.Allocator, io: std.Io, root: path_mod.WorkspaceRoot, checkpoint_id: u64) CheckpointError!void {
    var list = try listEntries(allocator, io, root);
    defer list.deinit();
    for (list.items) |entry| {
        if (entry.id == checkpoint_id) return;
    }
    return error.CheckpointNotFound;
}

pub fn findEntry(allocator: std.mem.Allocator, io: std.Io, root: path_mod.WorkspaceRoot, checkpoint_id: u64) CheckpointError!Entry {
    var list = try listEntries(allocator, io, root);
    defer list.deinit();
    for (list.items) |entry| {
        if (entry.id == checkpoint_id) return entry;
    }
    return error.CheckpointNotFound;
}

fn appendIndex(io: std.Io, root: path_mod.WorkspaceRoot, line: []const u8) CheckpointError!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);

    const existing = readRelative(allocator, io, root, index_file) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return error.WorkspaceFailed,
    };
    if (existing) |bytes| {
        buffer.appendSlice(allocator, bytes) catch return error.WorkspaceFailed;
        if (bytes.len > 0 and bytes[bytes.len - 1] != '\n') buffer.append(allocator, '\n') catch return error.WorkspaceFailed;
    }
    buffer.appendSlice(allocator, line) catch return error.WorkspaceFailed;
    atomic.replaceFile(io, root, path_mod.WorkspacePath.parse(index_file) catch return error.WorkspaceFailed, buffer.items) catch return error.WorkspaceFailed;
}

fn readRelative(allocator: std.mem.Allocator, io: std.Io, root: path_mod.WorkspaceRoot, rel: []const u8) ![]u8 {
    const wp = try path_mod.WorkspacePath.parse(rel);
    var snap = try snapshot.FileSnapshot.read(allocator, io, root, wp);
    defer snap.deinit();
    return allocator.dupe(u8, snap.content);
}

test "checkpoint create and restore roundtrip" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const root = path_mod.WorkspaceRoot.init(tmp.dir);

    try atomic.replaceFile(io, root, try path_mod.WorkspacePath.parse("sample.txt"), "version one\n");

    const id = try create(allocator, io, root, &[_][]const u8{"sample.txt"}, .{ .label = "test" });
    try atomic.replaceFile(io, root, try path_mod.WorkspacePath.parse("sample.txt"), "version two\n");
    try restore(allocator, io, root, id);

    var snap = try snapshot.FileSnapshot.read(allocator, io, root, try path_mod.WorkspacePath.parse("sample.txt"));
    defer snap.deinit();
    try std.testing.expectEqualStrings("version one\n", snap.content);
}
