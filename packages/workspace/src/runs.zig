const std = @import("std");
const path_mod = @import("path.zig");
const atomic = @import("atomic.zig");

const global_store = @import("global_store.zig");

pub const IndexEntry = struct {
    run_id: []const u8,
    state: []const u8,
    timestamp_ms: i64,
};

pub const IndexList = struct {
    allocator: std.mem.Allocator,
    items: []IndexEntry,

    pub fn deinit(self: *IndexList) void {
        for (self.items) |entry| {
            self.allocator.free(entry.run_id);
            self.allocator.free(entry.state);
        }
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

pub fn ensureLayout(allocator: std.mem.Allocator, io: std.Io, root: path_mod.WorkspaceRoot) !void {
    const session_dir = try global_store.getSessionDir(allocator, io, root);
    defer allocator.free(session_dir);
    const dir = try std.fmt.allocPrint(allocator, "{s}/runs", .{session_dir});
    defer allocator.free(dir);
    std.Io.Dir.createDirPath(.cwd(), io, dir) catch {};
}

pub fn persistRun(allocator: std.mem.Allocator, io: std.Io, root: path_mod.WorkspaceRoot, run_id: []const u8, json_body: []const u8) !void {
    try ensureLayout(allocator, io, root);
    const session_dir = try global_store.getSessionDir(allocator, io, root);
    defer allocator.free(session_dir);
    const abs_path = try std.fmt.allocPrint(allocator, "{s}/runs/{s}.json", .{ session_dir, run_id });
    defer allocator.free(abs_path);
    try global_store.replaceAbsoluteFile(io, abs_path, json_body);
}

pub fn appendIndex(allocator: std.mem.Allocator, io: std.Io, root: path_mod.WorkspaceRoot, line: []const u8) !void {
    try ensureLayout(allocator, io, root);

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);

    const session_dir = try global_store.getSessionDir(allocator, io, root);
    defer allocator.free(session_dir);
    const runs_index = try std.fmt.allocPrint(allocator, "{s}/runs/index.jsonl", .{session_dir});
    defer allocator.free(runs_index);
    const existing = global_store.readAbsoluteFile(allocator, io, runs_index) catch null;
    if (existing) |bytes| {
        defer allocator.free(bytes);
        try buffer.appendSlice(allocator, bytes);
        if (bytes.len > 0 and bytes[bytes.len - 1] != '\n') try buffer.append(allocator, '\n');
    }

    try buffer.appendSlice(allocator, line);
    try global_store.replaceAbsoluteFile(io, runs_index, buffer.items);
}

pub fn listEntries(allocator: std.mem.Allocator, io: std.Io, root: path_mod.WorkspaceRoot) !IndexList {
    var items: std.ArrayList(IndexEntry) = .empty;
    errdefer {
        for (items.items) |entry| {
            allocator.free(entry.run_id);
            allocator.free(entry.state);
        }
        items.deinit(allocator);
    }

    const session_dir = global_store.getSessionDir(allocator, io, root) catch return IndexList{ .allocator = allocator, .items = try items.toOwnedSlice(allocator) };
    defer allocator.free(session_dir);
    const runs_index = std.fmt.allocPrint(allocator, "{s}/runs/index.jsonl", .{session_dir}) catch return IndexList{ .allocator = allocator, .items = try items.toOwnedSlice(allocator) };
    defer allocator.free(runs_index);
    const content = global_store.readAbsoluteFile(allocator, io, runs_index) catch return IndexList{ .allocator = allocator, .items = try items.toOwnedSlice(allocator) };
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const JsonEntry = struct {
            run_id: []const u8,
            state: []const u8,
            timestamp_ms: i64,
        };
        var parsed = try std.json.parseFromSlice(JsonEntry, allocator, line, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        try items.append(allocator, .{
            .run_id = try allocator.dupe(u8, parsed.value.run_id),
            .state = try allocator.dupe(u8, parsed.value.state),
            .timestamp_ms = parsed.value.timestamp_ms,
        });
    }

    return IndexList{ .allocator = allocator, .items = try items.toOwnedSlice(allocator) };
}

pub fn loadRunJson(allocator: std.mem.Allocator, io: std.Io, root: path_mod.WorkspaceRoot, run_id: []const u8) ![]u8 {
    const session_dir = try global_store.getSessionDir(allocator, io, root);
    defer allocator.free(session_dir);
    const abs_path = try std.fmt.allocPrint(allocator, "{s}/runs/{s}.json", .{ session_dir, run_id });
    defer allocator.free(abs_path);
    return try global_store.readAbsoluteFile(allocator, io, abs_path);
}

pub fn updateRunState(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: path_mod.WorkspaceRoot,
    run_id: []const u8,
    new_state: []const u8,
    transaction_id: ?u64,
) !void {
    const json_bytes = try loadRunJson(allocator, io, root, run_id);
    defer allocator.free(json_bytes);

    const JsonRecord = struct {
        schema_version: ?u32 = null,
        run_id: []const u8,
        surface: []const u8,
        intent: []const u8,
        state: []const u8,
        proposal_path: ?[]const u8 = null,
        transaction_id: ?u64 = null,
        provider_id: ?[]const u8 = null,
        model_id: ?[]const u8 = null,
        timestamp_ms: i64,
    };

    var parsed = try std.json.parseFromSlice(JsonRecord, allocator, json_bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const tx_id = transaction_id orelse parsed.value.transaction_id orelse 0;
    const proposal = parsed.value.proposal_path orelse "";
    const provider = parsed.value.provider_id orelse "";
    const model = parsed.value.model_id orelse "";
    const schema_version = parsed.value.schema_version orelse 1;

    const updated = try std.fmt.allocPrint(
        allocator,
        "{{\"schema_version\":{d},\"run_id\":\"{s}\",\"surface\":\"{s}\",\"intent\":\"{s}\",\"state\":\"{s}\",\"proposal_path\":\"{s}\",\"transaction_id\":{d},\"provider_id\":\"{s}\",\"model_id\":\"{s}\",\"timestamp_ms\":{d}}}\n",
        .{
            schema_version,
            parsed.value.run_id,
            parsed.value.surface,
            parsed.value.intent,
            new_state,
            proposal,
            tx_id,
            provider,
            model,
            parsed.value.timestamp_ms,
        },
    );
    defer allocator.free(updated);
    try persistRun(allocator, io, root, run_id, updated);
    try updateIndexState(allocator, io, root, run_id, new_state);
}

pub fn updateIndexState(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: path_mod.WorkspaceRoot,
    run_id: []const u8,
    new_state: []const u8,
) !void {
    const session_dir = global_store.getSessionDir(allocator, io, root) catch return;
    defer allocator.free(session_dir);
    const runs_index = std.fmt.allocPrint(allocator, "{s}/runs/index.jsonl", .{session_dir}) catch return;
    defer allocator.free(runs_index);
    const content = global_store.readAbsoluteFile(allocator, io, runs_index) catch return;
    defer allocator.free(content);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const JsonEntry = struct {
            run_id: []const u8,
            state: []const u8,
            timestamp_ms: i64,
        };
        var parsed = try std.json.parseFromSlice(JsonEntry, allocator, line, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        if (std.mem.eql(u8, parsed.value.run_id, run_id)) {
            const updated_line = try std.fmt.allocPrint(
                allocator,
                "{{\"run_id\":\"{s}\",\"state\":\"{s}\",\"timestamp_ms\":{d}}}\n",
                .{ run_id, new_state, parsed.value.timestamp_ms },
            );
            defer allocator.free(updated_line);
            try out.appendSlice(allocator, updated_line);
        } else {
            try out.appendSlice(allocator, line);
            try out.append(allocator, '\n');
        }
    }

    try global_store.replaceAbsoluteFile(io, runs_index, out.items);
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

test "updateRunState rewrites run json and index" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const root = path_mod.WorkspaceRoot.init(tmp.dir, ".");

    const initial =
        \\{"schema_version":1,"run_id":"run_42","surface":"ide","intent":"fix bug","state":"proposed","proposal_path":".forge/proposals/run_42.json","transaction_id":0,"provider_id":"fake","model_id":"fake","timestamp_ms":42}
    ;
    try persistRun(allocator, io, root, "run_42", initial);
    try appendIndex(allocator, io, root, "{\"run_id\":\"run_42\",\"state\":\"proposed\",\"timestamp_ms\":42}\n");

    try updateRunState(allocator, io, root, "run_42", "done", 7);

    const updated = try loadRunJson(allocator, io, root, "run_42");
    defer allocator.free(updated);
    try std.testing.expect(std.mem.indexOf(u8, updated, "\"state\":\"done\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "\"transaction_id\":7") != null);

    var list = try listEntries(allocator, io, root);
    defer list.deinit();
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqualStrings("done", list.items[0].state);
}

test "runs list parses index jsonl" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const root = path_mod.WorkspaceRoot.init(tmp.dir, ".");

    try appendIndex(allocator, io, root, "{\"run_id\":\"run_1\",\"state\":\"proposed\",\"timestamp_ms\":100}\n");

    var list = try listEntries(allocator, io, root);
    defer list.deinit();

    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqualStrings("run_1", list.items[0].run_id);
    try std.testing.expectEqualStrings("proposed", list.items[0].state);
}
