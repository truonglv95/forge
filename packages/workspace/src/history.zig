const std = @import("std");
const global_store = @import("global_store.zig");
const edit = @import("edit.zig");
const path_mod = @import("path.zig");
const transaction = @import("transaction.zig");
const atomic = @import("atomic.zig");
const snapshot = @import("snapshot.zig");
const proposal_mod = @import("proposal.zig");

pub const backup_manifest = "manifest.json";

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

pub fn ensureLayout(allocator: std.mem.Allocator, io: std.Io, root: path_mod.WorkspaceRoot) !void {
    const session_dir = try global_store.getSessionDir(allocator, io, root);
    defer allocator.free(session_dir);
    const proposals_dir = try std.fmt.allocPrint(allocator, "{s}/proposals", .{session_dir});
    defer allocator.free(proposals_dir);
    const backups_dir = try std.fmt.allocPrint(allocator, "{s}/backups", .{session_dir});
    defer allocator.free(backups_dir);
    std.Io.Dir.createDirPath(.cwd(), io, proposals_dir) catch {};
    std.Io.Dir.createDirPath(.cwd(), io, backups_dir) catch {};
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

    const session_dir = global_store.getSessionDir(allocator, io, root) catch return EntryList{ .allocator = allocator, .items = try items.toOwnedSlice(allocator) };
    defer allocator.free(session_dir);
    const hist_path = std.fmt.allocPrint(allocator, "{s}/history.jsonl", .{session_dir}) catch return EntryList{ .allocator = allocator, .items = try items.toOwnedSlice(allocator) };
    defer allocator.free(hist_path);
    const content = global_store.readAbsoluteFile(allocator, io, hist_path) catch return EntryList{ .allocator = allocator, .items = try items.toOwnedSlice(allocator) };
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

pub fn writeActiveMarker(allocator: std.mem.Allocator, io: std.Io, root: path_mod.WorkspaceRoot, id: u64) !void {
    try ensureLayout(allocator, io, root);
    var buf: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{d}\n", .{id});
    const session_dir = try global_store.getSessionDir(allocator, io, root);
    defer allocator.free(session_dir);
    const marker_path = try std.fmt.allocPrint(allocator, "{s}/active.tx", .{session_dir});
    defer allocator.free(marker_path);
    try global_store.replaceAbsoluteFile(io, marker_path, text);
}

pub fn clearActiveMarker(allocator: std.mem.Allocator, io: std.Io, root: path_mod.WorkspaceRoot) void {
    const session_dir = global_store.getSessionDir(allocator, io, root) catch return;
    defer allocator.free(session_dir);
    const marker_path = std.fmt.allocPrint(allocator, "{s}/active.tx", .{session_dir}) catch return;
    defer allocator.free(marker_path);
    global_store.deleteAbsoluteFile(io, marker_path);
}

pub fn readActiveMarker(allocator: std.mem.Allocator, io: std.Io, root: path_mod.WorkspaceRoot) !?u64 {
    const session_dir = try global_store.getSessionDir(allocator, io, root);
    defer allocator.free(session_dir);
    const marker_path = try std.fmt.allocPrint(allocator, "{s}/active.tx", .{session_dir});
    defer allocator.free(marker_path);
    const content = global_store.readAbsoluteFile(allocator, io, marker_path) catch return null;
    defer allocator.free(content);
    const trimmed = std.mem.trim(u8, content, " \n\r\t");
    return try std.fmt.parseInt(u64, trimmed, 10);
}

pub fn appendEntry(allocator: std.mem.Allocator, io: std.Io, root: path_mod.WorkspaceRoot, entry: Entry) !void {
    try ensureLayout(allocator, io, root);

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);

    const session_dir = try global_store.getSessionDir(allocator, io, root);
    defer allocator.free(session_dir);
    const hist_path = try std.fmt.allocPrint(allocator, "{s}/history.jsonl", .{session_dir});
    defer allocator.free(hist_path);

    const existing = global_store.readAbsoluteFile(allocator, io, hist_path) catch null;
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

    try global_store.replaceAbsoluteFile(io, hist_path, buffer.items);
}

pub fn persistBackups(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: path_mod.WorkspaceRoot,
    record: *const transaction.TransactionRecord,
) !void {
    try ensureLayout(allocator, io, root);
    const session_dir = try global_store.getSessionDir(allocator, io, root);
    defer allocator.free(session_dir);
    const backup_root = try std.fmt.allocPrint(allocator, "{s}/backups/{d}", .{ session_dir, record.id });
    defer allocator.free(backup_root);
    std.Io.Dir.createDirPath(.cwd(), io, backup_root) catch {};

    for (record.backups) |backup| {
        if (!backup.existed) continue;
        const backup_abs = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ backup_root, backup.path });
        defer allocator.free(backup_abs);
        try global_store.replaceAbsoluteFile(io, backup_abs, backup.content);
    }

    const ManifestEntry = struct { path: []const u8, existed: bool };
    var entries = try std.heap.page_allocator.alloc(ManifestEntry, record.backups.len);
    defer std.heap.page_allocator.free(entries);
    for (record.backups, 0..) |backup, index| {
        entries[index] = .{ .path = backup.path, .existed = backup.existed };
    }
    const manifest_body = try std.json.Stringify.valueAlloc(std.heap.page_allocator, entries, .{});
    defer std.heap.page_allocator.free(manifest_body);
    const manifest_abs = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ backup_root, backup_manifest });
    defer allocator.free(manifest_abs);
    try global_store.replaceAbsoluteFile(io, manifest_abs, manifest_body);
}

pub fn persistApplied(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: path_mod.WorkspaceRoot,
    record: *const transaction.TransactionRecord,
    proposal_path: []const u8,
) !void {
    try ensureLayout(allocator, io, root);

    var proposal_src = try snapshot.FileSnapshot.read(allocator, io, root, try path_mod.WorkspacePath.parse(proposal_path));
    defer proposal_src.deinit();

    const session_dir = try global_store.getSessionDir(allocator, io, root);
    defer allocator.free(session_dir);
    const proposal_abs = try std.fmt.allocPrint(allocator, "{s}/proposals/{d}.json", .{ session_dir, record.id });
    defer allocator.free(proposal_abs);
    try global_store.replaceAbsoluteFile(io, proposal_abs, proposal_src.content);

    try persistBackups(allocator, io, root, record);

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

    const session_dir = try global_store.getSessionDir(allocator, io, root);
    defer allocator.free(session_dir);
    const proposal_abs = try std.fmt.allocPrint(allocator, "{s}/proposals/{d}.json", .{ session_dir, id });
    defer allocator.free(proposal_abs);
    const proposal_content = try global_store.readAbsoluteFile(allocator, io, proposal_abs);
    defer allocator.free(proposal_content);
    var proposal = try proposal_mod.OwnedProposal.parseJson(allocator, proposal_content);

    var backups: std.ArrayList(transaction.FileBackup) = .empty;
    errdefer {
        for (backups.items) |backup| {
            allocator.free(backup.path);
            if (backup.existed) allocator.free(backup.content);
        }
        backups.deinit(allocator);
        proposal.deinit();
    }

    const backup_root = try std.fmt.allocPrint(allocator, "{s}/backups/{d}", .{ session_dir, id });
    defer allocator.free(backup_root);

    for (proposal.files) |file_edit| {
        const backup_abs = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ backup_root, file_edit.path });
        defer allocator.free(backup_abs);
        const content = global_store.readAbsoluteFile(allocator, io, backup_abs) catch |err| switch (err) {
            error.FileNotFound => "",
            else => return err,
        };
        const existed = content.len > 0 or (std.Io.Dir.openFileAbsolute(io, backup_abs, .{}) catch null) != null;
        const stored_content = if (existed) content else "";
        try backups.append(allocator, .{
            .path = try allocator.dupe(u8, file_edit.path),
            .existed = existed,
            .content = stored_content,
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

    const session_dir = try global_store.getSessionDir(allocator, io, root);
    const hist_path = try std.fmt.allocPrint(allocator, "{s}/history.jsonl", .{session_dir});

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

    try global_store.replaceAbsoluteFile(io, hist_path, buffer.items);
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
    const root = path_mod.WorkspaceRoot.init(tmp.dir, ".");

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
