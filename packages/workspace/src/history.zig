const std = @import("std");
const edit = @import("edit.zig");
const path_mod = @import("path.zig");
const transaction = @import("transaction.zig");
const atomic = @import("atomic.zig");
const snapshot = @import("snapshot.zig");
const proposal_mod = @import("proposal.zig");

pub const forge_dir = ".forge";
pub const history_file = ".forge/history.jsonl";
pub const active_marker = ".forge/active.tx";
pub const proposals_dir = ".forge/proposals";
pub const backups_dir = ".forge/backups";

pub const Entry = struct {
    id: u64,
    state: transaction.TransactionState,
    timestamp_ms: i64,
    proposal_path: []const u8,
};

pub const EntryList = struct {
    allocator: std.mem.Allocator,
    items: []Entry,

    pub fn deinit(self: *EntryList) void {
        for (self.items) |entry| self.allocator.free(entry.proposal_path);
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

pub const LoadedRecord = struct {
    allocator: std.mem.Allocator,
    record: transaction.TransactionRecord,
    proposal: proposal_mod.OwnedProposal,

    pub fn deinit(self: *LoadedRecord, service: *transaction.TransactionService) void {
        service.freeRecord(&self.record);
        self.proposal.deinit();
        self.* = undefined;
    }
};

pub fn ensureLayout(io: std.Io, root: path_mod.WorkspaceRoot) !void {
    try root.dir.createDirPath(io, forge_dir);
    try root.dir.createDirPath(io, proposals_dir);
    try root.dir.createDirPath(io, backups_dir);
}

pub fn nextTransactionId(allocator: std.mem.Allocator, io: std.Io, root: path_mod.WorkspaceRoot) !u64 {
    var list = try listEntries(allocator, io, root);
    defer list.deinit();
    var max_id: u64 = 0;
    for (list.items) |entry| max_id = @max(max_id, entry.id);
    return max_id + 1;
}

pub fn listEntries(allocator: std.mem.Allocator, io: std.Io, root: path_mod.WorkspaceRoot) !EntryList {
    var items: std.ArrayList(Entry) = .empty;
    errdefer {
        for (items.items) |entry| allocator.free(entry.proposal_path);
        items.deinit(allocator);
    }

    const content = readRelativeFile(allocator, io, root, history_file) catch |err| switch (err) {
        error.FileNotFound => return EntryList{ .allocator = allocator, .items = try items.toOwnedSlice(allocator) },
        else => return err,
    };
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const JsonEntry = struct {
            id: u64,
            state: []const u8,
            timestamp_ms: i64,
            proposal_path: []const u8,
        };
        var parsed = try std.json.parseFromSlice(JsonEntry, allocator, line, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        const state = std.meta.stringToEnum(transaction.TransactionState, parsed.value.state) orelse continue;
        try items.append(allocator, .{
            .id = parsed.value.id,
            .state = state,
            .timestamp_ms = parsed.value.timestamp_ms,
            .proposal_path = try allocator.dupe(u8, parsed.value.proposal_path),
        });
    }

    return EntryList{ .allocator = allocator, .items = try items.toOwnedSlice(allocator) };
}

pub fn writeActiveMarker(io: std.Io, root: path_mod.WorkspaceRoot, id: u64) !void {
    try ensureLayout(io, root);
    var buf: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{d}\n", .{id});
    try atomic.replaceFile(io, root, try path_mod.WorkspacePath.parse(active_marker), text);
}

pub fn clearActiveMarker(io: std.Io, root: path_mod.WorkspaceRoot) void {
    root.dir.deleteFile(io, active_marker) catch {};
}

pub fn readActiveMarker(io: std.Io, root: path_mod.WorkspaceRoot) !?u64 {
    const content = readRelativeFile(std.heap.page_allocator, io, root, active_marker) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer std.heap.page_allocator.free(content);
    const trimmed = std.mem.trim(u8, content, " \n\r\t");
    return try std.fmt.parseInt(u64, trimmed, 10);
}

pub fn appendEntry(allocator: std.mem.Allocator, io: std.Io, root: path_mod.WorkspaceRoot, entry: Entry) !void {
    try ensureLayout(io, root);

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);

    const existing = readRelativeFile(allocator, io, root, history_file) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (existing) |bytes| {
        defer allocator.free(bytes);
        try buffer.appendSlice(allocator, bytes);
        if (bytes.len > 0 and bytes[bytes.len - 1] != '\n') try buffer.append(allocator, '\n');
    }

    const line = try std.fmt.allocPrint(
        allocator,
        "{{\"id\":{d},\"state\":\"{s}\",\"timestamp_ms\":{d},\"proposal_path\":\"{s}\"}}\n",
        .{ entry.id, @tagName(entry.state), entry.timestamp_ms, entry.proposal_path },
    );
    defer allocator.free(line);
    try buffer.appendSlice(allocator, line);

    try atomic.replaceFile(io, root, try path_mod.WorkspacePath.parse(history_file), buffer.items);
}

pub fn persistApplied(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: path_mod.WorkspaceRoot,
    record: *const transaction.TransactionRecord,
    proposal_path: []const u8,
) !void {
    try ensureLayout(io, root);

    var proposal_src = try snapshot.FileSnapshot.read(allocator, io, root, try path_mod.WorkspacePath.parse(proposal_path));
    defer proposal_src.deinit();

    var proposal_rel_buf: [std.fs.max_path_bytes]u8 = undefined;
    const proposal_rel = try std.fmt.bufPrint(&proposal_rel_buf, "{s}/{d}.json", .{ proposals_dir, record.id });
    try atomic.replaceFile(io, root, try path_mod.WorkspacePath.parse(proposal_rel), proposal_src.content);

    var backup_root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const backup_root_rel = try std.fmt.bufPrint(&backup_root_buf, "{s}/{d}", .{ backups_dir, record.id });
    try root.dir.createDirPath(io, backup_root_rel);

    for (record.backups) |backup| {
        if (!backup.existed) continue;
        var backup_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const backup_rel = try std.fmt.bufPrint(&backup_path_buf, "{s}/{s}", .{ backup_root_rel, backup.path });
        try atomic.replaceFile(io, root, try path_mod.WorkspacePath.parse(backup_rel), backup.content);
    }

    try appendEntry(allocator, io, root, .{
        .id = record.id,
        .state = record.state,
        .timestamp_ms = record.timestamp_ms,
        .proposal_path = proposal_path,
    });
}

pub fn loadRecord(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: path_mod.WorkspaceRoot,
    id: u64,
) !LoadedRecord {
    var list = try listEntries(allocator, io, root);
    defer list.deinit();

    const entry = for (list.items) |item| {
        if (item.id == id) break item;
    } else return error.TransactionNotFound;

    var proposal_rel_buf: [std.fs.max_path_bytes]u8 = undefined;
    const proposal_rel = try std.fmt.bufPrint(&proposal_rel_buf, "{s}/{d}.json", .{ proposals_dir, id });
    var proposal = try proposal_mod.OwnedProposal.readPath(allocator, io, root, proposal_rel);

    var backups: std.ArrayList(transaction.FileBackup) = .empty;
    errdefer {
        for (backups.items) |backup| {
            allocator.free(backup.path);
            if (backup.existed) allocator.free(backup.content);
        }
        backups.deinit(allocator);
        proposal.deinit();
    }

    var backup_root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const backup_root_rel = try std.fmt.bufPrint(&backup_root_buf, "{s}/{d}", .{ backups_dir, id });

    for (proposal.files) |file_edit| {
        var backup_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const backup_rel = try std.fmt.bufPrint(&backup_path_buf, "{s}/{s}", .{ backup_root_rel, file_edit.path });
        const backup_wp = try path_mod.WorkspacePath.parse(backup_rel);
        const existed = blk: {
            root.dir.access(io, backup_wp.raw, .{}) catch |err| switch (err) {
                error.FileNotFound => break :blk false,
                else => return err,
            };
            break :blk true;
        };
        const content: []const u8 = if (existed) blk: {
            var snap = try snapshot.FileSnapshot.read(allocator, io, root, backup_wp);
            defer snap.deinit();
            break :blk try allocator.dupe(u8, snap.content);
        } else "";
        try backups.append(allocator, .{
            .path = try allocator.dupe(u8, file_edit.path),
            .existed = existed,
            .content = content,
        });
    }

    return LoadedRecord{
        .allocator = allocator,
        .proposal = proposal,
        .record = .{
            .id = entry.id,
            .state = entry.state,
            .workspace_edit = proposal.workspaceEdit(),
            .timestamp_ms = entry.timestamp_ms,
            .backups = try backups.toOwnedSlice(allocator),
        },
    };
}

pub fn updateEntryState(io: std.Io, root: path_mod.WorkspaceRoot, id: u64, state: transaction.TransactionState) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var list = try listEntries(allocator, io, root);
    defer list.deinit();

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);
    for (list.items) |entry| {
        const current_state = if (entry.id == id) state else entry.state;
        const line = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":{d},\"state\":\"{s}\",\"timestamp_ms\":{d},\"proposal_path\":\"{s}\"}}\n",
            .{ entry.id, @tagName(current_state), entry.timestamp_ms, entry.proposal_path },
        );
        defer allocator.free(line);
        try buffer.appendSlice(allocator, line);
    }

    try atomic.replaceFile(io, root, try path_mod.WorkspacePath.parse(history_file), buffer.items);
}

fn readRelativeFile(allocator: std.mem.Allocator, io: std.Io, root: path_mod.WorkspaceRoot, rel_path: []const u8) ![]u8 {
    var file = try root.dir.openFile(io, rel_path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const size: usize = @intCast(stat.size);
    const content = try allocator.alloc(u8, size);
    errdefer allocator.free(content);
    const read_len = try file.readPositionalAll(io, content, 0);
    if (read_len != size) return error.UnexpectedEof;
    return content;
}

test "history persists apply and supports undo reload" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const root = path_mod.WorkspaceRoot.init(tmp.dir);

    const proposal_source =
        \\{"files":[{"path":"note.txt","operation":"create","edits":[{"start":0,"end":0,"replacement":"hi"}]}]}
    ;
    try atomic.replaceFile(io, root, try path_mod.WorkspacePath.parse("proposal.json"), proposal_source);

    var proposal = try proposal_mod.OwnedProposal.parseJson(allocator, proposal_source);
    defer proposal.deinit();

    var service = transaction.TransactionService.init(allocator, io, root);
    var record = transaction.TransactionRecord{
        .id = 1,
        .state = .approved,
        .workspace_edit = proposal.workspaceEdit(),
        .timestamp_ms = 0,
    };
    defer service.freeRecord(&record);

    try service.apply(&record);
    try persistApplied(allocator, io, root, &record, "proposal.json");

    var loaded = try loadRecord(allocator, io, root, 1);
    defer loaded.deinit(&service);
    try std.testing.expectEqual(transaction.TransactionState.applied, loaded.record.state);

    try service.undo(&loaded.record);
    try updateEntryState(io, root, 1, .undone);

    var entries = try listEntries(allocator, io, root);
    defer entries.deinit();
    try std.testing.expectEqual(@as(usize, 1), entries.items.len);
    try std.testing.expectEqual(transaction.TransactionState.undone, entries.items[0].state);
}
